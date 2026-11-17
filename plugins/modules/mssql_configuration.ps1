#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._MssqlCommon

# Configures a running SQL Server instance from inside: sp_configure values
# and tempdb's files. It connects over shared memory (lpc:) as the account it
# runs as, through .NET Framework's System.Data.SqlClient, which strict
# encryption refuses, and needs ALTER SETTINGS for sp_configure and ALTER on
# tempdb, which sysadmin has. The util (plugins/module_utils/
# _MssqlCommon.psm1) decides the changes: Get-MssqlConfigurationPlan and
# Get-MssqlConfigurationBatch for sp_configure, Get-MssqlTempdbPlan for
# tempdb.
#
# A static option (sys.configurations' is_dynamic 0) takes effect when the
# engine restarts. With restart, the module restarts it (the util's
# Restart-MssqlEngine); without, it reports restart_required, and keeps
# reporting it on later runs while the option's value in use differs, which
# SQL Server records itself.
#
# Check mode connects and reads, runs every check, and changes nothing.

$spec = @{
    options = @{
        instance_name = @{ type = 'str'; default = 'MSSQLSERVER' }
        sp_configure = @{ type = 'dict' }
        tempdb = @{
            type = 'dict'
            options = @{
                file_count = @{ type = 'int' }
                file_size_mb = @{ type = 'int' }
                file_growth_mb = @{ type = 'int' }
                log_size_mb = @{ type = 'int' }
                log_growth_mb = @{ type = 'int' }
            }
        }
        restart = @{ type = 'bool'; default = $false }
        restart_timeout = @{ type = 'int'; default = 300 }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$params = $module.Params
$instanceName = [string]$params.instance_name
$restart = [bool]$params.restart
$checkMode = $module.CheckMode
$desired = $params.sp_configure
$tempdbDesired = $null
if ($null -ne $params.tempdb) {
    $tempdbDesired = @{
        FileCount = $params.tempdb['file_count']
        FileSizeMb = $params.tempdb['file_size_mb']
        FileGrowthMb = $params.tempdb['file_growth_mb']
        LogSizeMb = $params.tempdb['log_size_mb']
        LogGrowthMb = $params.tempdb['log_growth_mb']
    }
}

$actions = [System.Collections.Generic.List[string]]::new()
$notices = [System.Collections.Generic.List[string]]::new()
$script:instance = $null
$script:configuration = @{}
$script:tempdb = @()
$script:restartRequired = $false
$script:restarted = $false
$script:services = @{}

# Refusals that need nothing from the host.
$problems = [System.Collections.Generic.List[string]]::new()
$problems.Add((Get-MssqlInstanceNameProblem $instanceName))
if ($null -ne $tempdbDesired) { $problems.Add((Get-MssqlTempdbProblem $tempdbDesired)) }
if ($params.restart_timeout -lt 30) { $problems.Add("restart_timeout must be 30 seconds or more, got $($params.restart_timeout)") }
$problem = @($problems | Where-Object { $_ }) | Select-Object -First 1
if ($problem) { $module.FailJson($problem) }

# What the module reads. The memory is read on its own, since it needs VIEW
# SERVER STATE, which a login without it shouldn't fail the run for.
$serverQuery = @'
SELECT SUSER_SNAME() AS login,
    HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER SETTINGS') AS alter_settings,
    HAS_PERMS_BY_NAME(N'tempdb', N'DATABASE', N'ALTER') AS alter_tempdb
'@
$memoryQuery = 'SELECT physical_memory_kb / 1024 AS physical_memory_mb FROM sys.dm_os_sys_info'
$configurationQuery = @'
SELECT name, CAST(value AS bigint) AS value, CAST(value_in_use AS bigint) AS value_in_use,
    CAST(minimum AS bigint) AS minimum, CAST(maximum AS bigint) AS maximum, is_dynamic, is_advanced
FROM sys.configurations
ORDER BY name
'@
$tempdbQuery = @'
SELECT mf.file_id, mf.name, mf.type_desc AS type, mf.physical_name AS path,
    CAST(mf.size AS bigint) * 8 / 1024 AS size_mb,
    CAST(df.size AS bigint) * 8 / 1024 AS current_size_mb,
    CASE WHEN mf.is_percent_growth = 1 THEN NULL ELSE CAST(mf.growth AS bigint) * 8 / 1024 END AS growth_mb,
    CASE WHEN mf.is_percent_growth = 1 THEN mf.growth ELSE NULL END AS growth_percent
FROM sys.master_files AS mf
LEFT JOIN tempdb.sys.database_files AS df ON df.file_id = mf.file_id
WHERE mf.database_id = 2
ORDER BY mf.file_id
'@

# Record an action; carry it out unless this is a check-mode run.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Change)
    $actions.Add($Description)
    if (-not $checkMode) { & $Change }
}

function Add-Notice {
    param([string]$Notice)
    $notices.Add($Notice)
    $module.Warn($Notice)
}

# sys.configurations and tempdb's files. After a restart SQL Server can log
# "ready for client connections" a moment before it takes one, so a read
# then may try again.
function Read-Instance {
    param([string]$ConnectionString, [int]$Tries = 1)
    for ($try = 1; $try -le $Tries; $try++) {
        try {
            return @{
                Rows = @(Invoke-MssqlQuery -ConnectionString $ConnectionString -Query $configurationQuery)
                Files = @(Invoke-MssqlQuery -ConnectionString $ConnectionString -Query $tempdbQuery)
            }
        }
        catch {
            if ($try -ge $Tries) { throw }
            Start-Sleep -Seconds 5
        }
    }
}

# The options sp_configure names, as sys.configurations has them.
function Get-ConfigurationFact {
    param([object[]]$Rows)
    $facts = @{}
    if ($null -eq $desired) { return $facts }
    $asked = @($desired.Keys | ForEach-Object { [string]$_ })
    foreach ($row in $Rows) {
        if ($asked -notcontains [string]$row.name) { continue }
        $facts[[string]$row.name] = @{
            value = $row.value
            value_in_use = $row.value_in_use
            minimum = $row.minimum
            maximum = $row.maximum
            dynamic = [bool]$row.is_dynamic
            advanced = [bool]$row.is_advanced
        }
    }
    $facts
}

function Get-TempdbFact {
    param([object[]]$Files)
    @($Files | ForEach-Object {
            @{
                name = [string]$_.name
                type = [string]$_.type
                path = [string]$_.path
                size_mb = $_.size_mb
                current_size_mb = $_.current_size_mb
                growth_mb = $_.growth_mb
                growth_percent = $_.growth_percent
            }
        })
}

function Invoke-Main {
    $entry = @(Get-MssqlInstanceRegistry | Where-Object { $_.Name -eq $instanceName }) | Select-Object -First 1
    if ($null -eq $entry) { throw "Instance $instanceName isn't installed on this host" }
    if ($null -ne $entry.Cluster) { throw "Instance $instanceName is a failover cluster instance, which mssql_configuration doesn't configure yet" }
    $script:instance = @{ name = $instanceName; id = $entry.Id; version = (ConvertTo-MssqlVersionName $entry.Id) }
    $base = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($entry.Id)\MSSQLServer"
    $engineName = Get-MssqlServiceName -InstanceName $instanceName -Service 'engine'
    $agentName = Get-MssqlServiceName -InstanceName $instanceName -Service 'agent'
    $script:services = @{ engine = Get-MssqlServiceStateText $engineName; agent = Get-MssqlServiceStateText $agentName }
    if ($script:services.engine -ne 'running') {
        throw "Instance $instanceName's engine ($engineName) isn't running, and mssql_configuration connects to it"
    }
    $netLib = Get-MssqlRegistryValue "$base\SuperSocketNetLib"
    $strict = $null -ne $netLib -and [string]$netLib['ForceStrict'] -eq '1'
    $connection = Get-MssqlConnectionString -InstanceName $instanceName -HostName $env:COMPUTERNAME

    try {
        $server = @(Invoke-MssqlQuery -ConnectionString $connection -Query $serverQuery)[0]
    }
    catch {
        $message = $_.Exception.Message
        if ($strict) {
            throw ("Instance $instanceName uses strict encryption (Force Strict Encryption), which refuses .NET Framework's " +
                'System.Data.SqlClient, the client mssql_configuration connects with, over shared memory as well as TCP, so ' +
                "the module can't configure it. SqlClient said: $message")
        }
        throw "Can't connect to instance $instanceName over shared memory: $message"
    }
    $login = [string]$server.login
    $memoryMb = 0
    try {
        $memoryMb = [long](@(Invoke-MssqlQuery -ConnectionString $connection -Query $memoryQuery)[0].physical_memory_mb)
    }
    catch {
        $memoryMb = 0
    }
    $state = Read-Instance -ConnectionString $connection

    # The plans, and every refusal before the first write.
    $configurationPlan = Get-MssqlConfigurationPlan -Current $state.Rows -Desired $desired -PhysicalMemoryMb $memoryMb
    $problem = @($configurationPlan.Problems) | Select-Object -First 1
    if ($problem) { throw $problem }
    $tempdbPlan = @{ Changes = @(); Notices = @() }
    if ($null -ne $tempdbDesired) {
        if (@($state.Files).Count -eq 0) {
            throw "$login can't see tempdb's files in sys.master_files, which takes CREATE DATABASE, ALTER ANY DATABASE or VIEW ANY DEFINITION"
        }
        $tempdbPlan = Get-MssqlTempdbPlan -Files $state.Files -Desired $tempdbDesired
    }
    $batch = Get-MssqlConfigurationBatch -Plan $configurationPlan
    if ($null -ne $batch -and [int]$server.alter_settings -ne 1) {
        throw "$login lacks ALTER SETTINGS on instance $instanceName, which sp_configure needs to change an option (sysadmin and serveradmin have it)"
    }
    if (@($tempdbPlan.Changes).Count -gt 0 -and [int]$server.alter_tempdb -ne 1) {
        throw "$login lacks ALTER on tempdb, which changing its files needs (sysadmin has it)"
    }
    foreach ($planNotice in @($configurationPlan.Notices) + @($tempdbPlan.Notices)) { Add-Notice $planNotice }
    if ($null -ne $batch) {
        foreach ($other in @($configurationPlan.Pending | Where-Object { $_.Dynamic })) {
            Add-Notice ("RECONFIGURE also puts in use '{0}' = {1}, which was set earlier without one (in use: {2})" -f $other.Name, $other.Value, $other.InUse)
        }
    }

    # The writes: sp_configure's batch, an action for each option it sets,
    # then tempdb's statements.
    if ($null -ne $batch) {
        foreach ($item in $configurationPlan.Changes) { $actions.Add($item.Description) }
        if (-not $checkMode) { Invoke-MssqlNonQuery -ConnectionString $connection -Query $batch.Text -Parameters $batch.Parameters -Timeout 120 }
    }
    foreach ($statement in $tempdbPlan.Changes) {
        Invoke-Change $statement.Description {
            Invoke-MssqlNonQuery -ConnectionString $connection -Query $statement.Statement -Timeout 1800
        }
    }
    $wrote = (-not $checkMode) -and ($null -ne $batch -or @($tempdbPlan.Changes).Count -gt 0)
    if ($wrote) { $state = Read-Instance -ConnectionString $connection }

    # The static options asked for that wait for a restart: predicted in
    # check mode, read back after the writes otherwise.
    $waiting = @($configurationPlan.Restart)
    if ($wrote) { $waiting = @((Get-MssqlConfigurationPlan -Current $state.Rows -Desired $desired).Restart) }
    if ($waiting.Count -gt 0) {
        $names = @($waiting | ForEach-Object { "'$_'" }) -join ', '
        if ($restart) {
            $errorLogPath = Get-MssqlErrorLogPath (Get-MssqlRegistryValue "$base\Parameters")
            foreach ($other in @($configurationPlan.Pending | Where-Object { -not $_.Dynamic })) {
                Add-Notice ("The restart also puts in use '{0}' = {1}, which was set earlier and waited for one (in use: {2})" -f $other.Name, $other.Value, $other.InUse)
            }
            Invoke-Change "restart $engineName so these options take effect: $names" {
                $restartResult = Restart-MssqlEngine -EngineName $engineName -AgentName $agentName -ErrorLogPath $errorLogPath `
                    -Strict $strict -Timeout $params.restart_timeout
                $script:restarted = $true
                foreach ($restartNotice in $restartResult.Notices) { Add-Notice $restartNotice }
            }
            if ($script:restarted) {
                $state = Read-Instance -ConnectionString $connection -Tries 6
                $still = @((Get-MssqlConfigurationPlan -Current $state.Rows -Desired $desired).Restart)
                if ($still.Count -gt 0) { throw "$engineName restarted, but these options still wait for a restart: $($still -join ', ')" }
            }
        }
        else {
            $script:restartRequired = $true
            Add-Notice "These sp_configure options take effect when $engineName restarts: $names. Restart it, or run with restart"
        }
    }
    $script:configuration = Get-ConfigurationFact $state.Rows
    $script:tempdb = @(Get-TempdbFact $state.Files)
    $script:services = @{ engine = Get-MssqlServiceStateText $engineName; agent = Get-MssqlServiceStateText $agentName }
}

function Set-ModuleResult {
    $module.Result.instance = $script:instance
    $module.Result.sp_configure = $script:configuration
    $module.Result.tempdb = @($script:tempdb)
    $module.Result.restart_required = $script:restartRequired
    $module.Result.restarted = $script:restarted
    $module.Result.services = $script:services
    $module.Result.notices = $notices.ToArray()
    $module.Result.actions = $actions.ToArray()
    # In check mode an action that would be taken is a change, as for a real run.
    $module.Result.changed = $actions.Count -gt 0
    $module.Diff.prepared = ($actions -join "`n")
}

# FailJson exits through an exception, so it is only called outside the try
# block, from the catch.
try {
    Invoke-Main
}
catch {
    Set-ModuleResult
    $msg = '{0} (at line {1}: {2})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()
    $module.FailJson($msg, $_)
}

Set-ModuleResult
$module.ExitJson()
