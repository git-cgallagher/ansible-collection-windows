#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._MssqlCommon

# Reports the SQL Server instances on this host: what the registry and the
# services say about each (version, edition, features, collation, TCP,
# encryption, service accounts), and, connected to each running instance
# over shared memory as the account the module runs as, what SQL Server
# itself says (SERVERPROPERTY, its services, sysadmins, tempdb's files and
# sp_configure). Also whether Windows has a reboot pending. Reads only, so
# check mode runs it the same way.

$spec = @{
    options = @{
        instance_name = @{ type = 'str' }
        connect = @{ type = 'bool'; default = $true }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$instanceName = [string]$module.Params.instance_name
$connect = [bool]$module.Params.connect

# What the instance says about itself. Each query that fails is left out and
# its reason recorded, so one missing permission doesn't hide the rest.
function Get-ServerFact {
    param([string]$ConnectionString)
    $server = @{ connected = $false; connection_error = ''; query_errors = @() }
    $errors = [System.Collections.Generic.List[string]]::new()
    $properties = $null
    try {
        $properties = @(Invoke-MssqlQuery -ConnectionString $ConnectionString -Query @'
SELECT
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
    CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(128)) AS product_update_level,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
    CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
    CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS collation,
    CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS is_hadr_enabled,
    CAST(SERVERPROPERTY('IsFullTextInstalled') AS int) AS is_fulltext_installed,
    CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS default_data_path,
    CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(4000)) AS default_log_path,
    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS default_backup_path,
    SUSER_SNAME() AS login,
    IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin
'@)[0]
    }
    catch {
        $server.connection_error = $_.Exception.Message
        return $server
    }
    $server.connected = $true
    $server.product_version = [string]$properties.product_version
    $server.product_level = [string]$properties.product_level
    $server.product_update_level = [string]$properties.product_update_level
    $server.edition = [string]$properties.edition
    $server.edition_id = ConvertTo-MssqlEditionId $properties.edition
    $server.engine_edition = $properties.engine_edition
    $server.collation = [string]$properties.collation
    $server.is_clustered = $properties.is_clustered -eq 1
    $server.is_hadr_enabled = $properties.is_hadr_enabled -eq 1
    $server.is_fulltext_installed = $properties.is_fulltext_installed -eq 1
    $server.default_paths = @{
        data = [string]$properties.default_data_path
        log = [string]$properties.default_log_path
        backup = [string]$properties.default_backup_path
    }
    $server.login = [string]$properties.login
    $server.is_sysadmin = $properties.is_sysadmin -eq 1

    $queries = [ordered]@{
        services = 'SELECT servicename, service_account, status_desc, startup_type_desc, instant_file_initialization_enabled FROM sys.dm_server_services'
        sysadmins = @'
SELECT p.name
FROM sys.server_role_members AS m
JOIN sys.server_principals AS r ON r.principal_id = m.role_principal_id
JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id
WHERE r.name = N'sysadmin'
ORDER BY p.name
'@
        tempdb = @'
SELECT name, type_desc, physical_name, CAST(size AS bigint) * 8 / 1024 AS size_mb,
    CASE WHEN is_percent_growth = 1 THEN NULL ELSE CAST(growth AS bigint) * 8 / 1024 END AS growth_mb,
    CASE WHEN is_percent_growth = 1 THEN growth ELSE NULL END AS growth_percent
FROM tempdb.sys.database_files
ORDER BY file_id
'@
        configuration = 'SELECT name, CAST(value AS bigint) AS value, CAST(value_in_use AS bigint) AS value_in_use FROM sys.configurations ORDER BY name'
    }
    $rows = @{}
    foreach ($key in $queries.Keys) {
        try {
            $rows[$key] = @(Invoke-MssqlQuery -ConnectionString $ConnectionString -Query $queries[$key])
        }
        catch {
            $errors.Add(('{0}: {1}' -f $key, $_.Exception.Message))
            $rows[$key] = @()
        }
    }
    $server.services = @($rows.services | ForEach-Object {
            @{
                name = [string]$_.servicename
                account = [string]$_.service_account
                status = [string]$_.status_desc
                startup_type = [string]$_.startup_type_desc
                instant_file_initialization = [string]$_.instant_file_initialization_enabled -eq 'Y'
            }
        })
    $server.sysadmins = @($rows.sysadmins | ForEach-Object { [string]$_.name })
    $server.tempdb = @($rows.tempdb | ForEach-Object {
            @{
                name = [string]$_.name
                type = [string]$_.type_desc
                path = [string]$_.physical_name
                size_mb = $_.size_mb
                growth_mb = $_.growth_mb
                growth_percent = $_.growth_percent
            }
        })
    $configuration = @{}
    foreach ($row in $rows.configuration) { $configuration[[string]$row.name] = @{ value = $row.value; value_in_use = $row.value_in_use } }
    $server.configuration = $configuration
    $server.query_errors = $errors.ToArray()
    $server
}

function Invoke-Main {
    $reasons = @(Get-MssqlRebootPendingReason -State (Get-MssqlRebootState))
    $module.Result.reboot_pending = $reasons.Count -gt 0
    $module.Result.reboot_pending_reasons = $reasons

    $instances = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-MssqlInstanceRegistry)) {
        if ($instanceName -and $entry.Name -ne $instanceName) { continue }
        $names = @('engine', 'agent', 'fulltext' | ForEach-Object { Get-MssqlServiceName -InstanceName $entry.Name -Service $_ })
        $fact = ConvertTo-MssqlInstanceFact -Registry $entry -Services (Get-MssqlServiceState -Name $names)
        $fact.server = $null
        if ($connect -and $null -ne $fact.services.engine -and $fact.services.engine.state -eq 'running') {
            $fact.server = Get-ServerFact -ConnectionString (Get-MssqlConnectionString -InstanceName $entry.Name -HostName $env:COMPUTERNAME)
        }
        $instances.Add($fact)
    }
    $module.Result.instances = $instances.ToArray()
}

# FailJson exits through an exception, so it is only called outside the try
# block, from the catch.
try {
    Invoke-Main
}
catch {
    $msg = '{0} (at line {1}: {2})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()
    $module.FailJson($msg, $_)
}

$module.Result.changed = $false
$module.ExitJson()
