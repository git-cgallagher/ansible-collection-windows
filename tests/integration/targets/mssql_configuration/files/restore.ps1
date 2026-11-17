# Puts the sp_configure options and tempdb's files back as the
# mssql_configuration target found them, in plain T-SQL through
# System.Data.SqlClient, never the module under test. Options is the
# target's start (option name to value and value_in_use), Tempdb its start
# files (name, size_mb, growth_mb, growth_percent). It restarts the engine
# when an option waits for a restart or tempdb has a file the target added:
# an added file empties and goes cleanly in a fresh tempdb. Returns what it
# did (done) and what still differs from the start (differences, empty when
# everything went back).
param(
    [string]$InstanceName = 'MSSQLSERVER',
    [System.Collections.IDictionary]$Options = @{},
    [object[]]$Tempdb = @()
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Add-Type -AssemblyName System.Data

$named = $InstanceName -ne 'MSSQLSERVER'
$server = 'lpc:' + $env:COMPUTERNAME
if ($named) { $server += '\' + $InstanceName }
$connectionString = "Data Source=$server;Integrated Security=SSPI;Connect Timeout=15"
$engine = 'MSSQLSERVER'
$agent = 'SQLSERVERAGENT'
if ($named) {
    $engine = 'MSSQL$' + $InstanceName
    $agent = 'SQLAgent$' + $InstanceName
}
$done = [System.Collections.Generic.List[string]]::new()

function New-Command {
    param([object]$Connection, [string]$Text, [System.Collections.IDictionary]$Parameters)
    $command = $Connection.CreateCommand()
    $command.CommandText = $Text
    $command.CommandTimeout = 600
    foreach ($key in $Parameters.Keys) { $null = $command.Parameters.AddWithValue('@' + $key, $Parameters[$key]) }
    $command
}

function Invoke-Sql {
    param([string]$Text, [System.Collections.IDictionary]$Parameters = @{})
    $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $connectionString
    try {
        $connection.Open()
        $table = New-Object -TypeName System.Data.DataTable
        $table.Load((New-Command -Connection $connection -Text $Text -Parameters $Parameters).ExecuteReader())
        @($table.Rows | ForEach-Object {
                $row = $_
                $out = @{}
                foreach ($column in $table.Columns) {
                    $value = $row[$column.ColumnName]
                    if ($value -is [System.DBNull]) { $value = $null }
                    $out[$column.ColumnName] = $value
                }
                $out
            })
    }
    finally {
        $connection.Dispose()
    }
}

# Writes run through ExecuteNonQuery, which raises an error from any
# statement of the batch.
function Invoke-SqlWrite {
    param([string]$Text, [System.Collections.IDictionary]$Parameters = @{})
    $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $connectionString
    try {
        $connection.Open()
        $null = (New-Command -Connection $connection -Text $Text -Parameters $Parameters).ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

function Get-Option {
    $rows = @{}
    foreach ($row in @(Invoke-Sql 'SELECT name, CAST(value AS bigint) AS value, CAST(value_in_use AS bigint) AS value_in_use FROM sys.configurations')) {
        if ($Options.Contains([string]$row.name)) { $rows[[string]$row.name] = $row }
    }
    $rows
}

function Get-TempdbFile {
    @(Invoke-Sql @'
SELECT name, type_desc AS type, CAST(size AS bigint) / 128 AS size_mb, is_percent_growth, CAST(growth AS bigint) AS growth
FROM sys.master_files
WHERE database_id = DB_ID(N'tempdb')
ORDER BY file_id
'@)
}

function ConvertTo-Literal {
    param([string]$Value)
    "N'" + $Value.Replace("'", "''") + "'"
}

function Restart-Instance {
    Restart-Service -Name $engine -Force
    Start-Service -Name $agent -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        try {
            $null = Invoke-Sql 'SELECT 1 AS one'
            break
        }
        catch {
            if ((Get-Date) -gt $deadline) { throw }
            Start-Sleep -Seconds 3
        }
    }
    $done.Add("restarted $engine")
}

# The options, with show advanced options on while they're set.
$current = Get-Option
$toSet = @($Options.Keys | Where-Object {
        $row = $current[[string]$_]
        $start = [long]$Options[$_]['value']
        $null -ne $row -and ([long]$row.value -ne $start -or [long]$row.value_in_use -ne $start)
    })
if ($toSet.Count -gt 0) {
    Invoke-SqlWrite "EXEC sys.sp_configure N'show advanced options', 1; RECONFIGURE;"
    foreach ($name in @($toSet | Where-Object { $_ -ne 'show advanced options' })) {
        Invoke-SqlWrite 'EXEC sys.sp_configure @name, @value; RECONFIGURE;' @{ name = [string]$name; value = [int]$Options[$name]['value'] }
        $done.Add("set '$name' back to $($Options[$name]['value'])")
    }
    $show = 0
    if ($Options.Contains('show advanced options')) { $show = [int]$Options['show advanced options']['value'] }
    Invoke-SqlWrite 'EXEC sys.sp_configure N''show advanced options'', @value; RECONFIGURE;' @{ value = $show }
}

# A restart for an option that waits for one, or before the added files go.
$startNames = @($Tempdb | ForEach-Object { [string]$_['name'] })
$waiting = @((Get-Option).Values | Where-Object { [long]$_.value -ne [long]$_.value_in_use })
$added = @(Get-TempdbFile | Where-Object { $startNames -notcontains [string]$_.name })
if ($waiting.Count -gt 0 -or $added.Count -gt 0) { Restart-Instance }

foreach ($file in $added) {
    $name = [string]$file.name
    Invoke-SqlWrite "USE [tempdb]; DBCC SHRINKFILE ($(ConvertTo-Literal $name), EMPTYFILE) WITH NO_INFOMSGS;"
    Invoke-SqlWrite "ALTER DATABASE [tempdb] REMOVE FILE [$($name.Replace(']', ']]'))];"
    $done.Add("removed tempdb file '$name'")
}

# The sizes and growth the target changed. DBCC SHRINKFILE also sets the size
# tempdb starts with (Microsoft KB 307487); when it doesn't, ALTER DATABASE
# is tried, and what happened goes in done.
foreach ($start in $Tempdb) {
    $name = [string]$start['name']
    $now = @(Get-TempdbFile | Where-Object { [string]$_.name -eq $name }) | Select-Object -First 1
    if ($null -eq $now) { continue }
    $literal = ConvertTo-Literal $name
    $startSize = [long]$start['size_mb']
    if ([long]$now.size_mb -gt $startSize) {
        Invoke-SqlWrite "USE [tempdb]; DBCC SHRINKFILE ($literal, $startSize) WITH NO_INFOMSGS;"
        $done.Add("shrank tempdb file '$name' to $startSize MB")
        $after = @(Get-TempdbFile | Where-Object { [string]$_.name -eq $name }) | Select-Object -First 1
        if ([long]$after.size_mb -gt $startSize) {
            try {
                Invoke-SqlWrite "ALTER DATABASE [tempdb] MODIFY FILE (NAME = $literal, SIZE = ${startSize}MB);"
                $done.Add("set tempdb file '$name''s size to $startSize MB, which DBCC SHRINKFILE left at $($after.size_mb) MB")
            }
            catch {
                $done.Add("couldn't set tempdb file '$name''s size to $startSize MB: $($_.Exception.Message)")
            }
        }
    }
    $growth = "FILEGROWTH = $($start['growth_mb'])MB"
    $same = -not $now.is_percent_growth -and [long]$now.growth / 128 -eq [long]$start['growth_mb']
    if ($null -ne $start['growth_percent']) {
        $growth = "FILEGROWTH = $($start['growth_percent'])%"
        $same = [bool]$now.is_percent_growth -and [long]$now.growth -eq [long]$start['growth_percent']
    }
    if (-not $same) {
        Invoke-SqlWrite "ALTER DATABASE [tempdb] MODIFY FILE (NAME = $literal, $growth);"
        $done.Add("set tempdb file '$name''s growth back ($growth)")
    }
}

# What still differs from the start.
$differences = [System.Collections.Generic.List[string]]::new()
$after = Get-Option
foreach ($name in @($Options.Keys)) {
    $row = $after[[string]$name]
    $start = $Options[$name]
    if ($null -eq $row) {
        $differences.Add("option '$name' isn't in sys.configurations")
        continue
    }
    if ([long]$row.value -ne [long]$start['value'] -or [long]$row.value_in_use -ne [long]$start['value_in_use']) {
        $text = "option '{0}' is {1} (in use {2}), was {3} (in use {4})"
        $differences.Add(($text -f $name, $row.value, $row.value_in_use, $start['value'], $start['value_in_use']))
    }
}
$files = @(Get-TempdbFile)
foreach ($start in $Tempdb) {
    $name = [string]$start['name']
    $now = @($files | Where-Object { [string]$_.name -eq $name }) | Select-Object -First 1
    if ($null -eq $now) {
        $differences.Add("tempdb file '$name' is gone")
        continue
    }
    if ([long]$now.size_mb -ne [long]$start['size_mb']) {
        $differences.Add(("tempdb file '{0}' is set to {1} MB, was {2} MB" -f $name, $now.size_mb, $start['size_mb']))
    }
    $growthMb = $null
    $growthPercent = $null
    if ($now.is_percent_growth) {
        $growthPercent = [long]$now.growth
    }
    else {
        $growthMb = [long]$now.growth / 128
    }
    if ("$growthMb" -ne "$($start['growth_mb'])" -or "$growthPercent" -ne "$($start['growth_percent'])") {
        $differences.Add(("tempdb file '{0}' grows by {1}{2}, was {3}{4}" -f $name, $growthMb, $growthPercent, $start['growth_mb'], $start['growth_percent']))
    }
}
foreach ($file in @($files | Where-Object { $startNames -notcontains [string]$_.name })) {
    $differences.Add("tempdb file '$($file.name)' is still there")
}
$Ansible.Changed = $done.Count -gt 0
@{ done = $done.ToArray(); differences = $differences.ToArray(); tempdb = $files }
