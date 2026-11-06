# Read one SQL Server instance for the mssql targets' and the role scenario's
# assertions: its registry keys, its services, and (with Query) what SQL
# Server says about itself; plus which of ImagePaths are mounted. Read-only,
# and independent of the modules under test and their util: the registry,
# Win32_Service and System.Data.SqlClient, directly.
param(
    [string]$InstanceName = 'MSSQLSERVER',
    [bool]$Query = $true,
    [string[]]$ImagePaths = @()
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false

$root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'

# A key's values as strings (multi-strings joined), or $null without the key.
function Read-Key {
    param([string]$Path)
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }
    $values = @{}
    foreach ($name in $key.GetValueNames()) { $values[$name] = (@($key.GetValue($name)) | ForEach-Object { [string]$_ }) -join ' ' }
    $values
}

function Invoke-Sql {
    param([string]$Connection, [string]$Text)
    $sql = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $Connection
    try {
        $sql.Open()
        $command = $sql.CreateCommand()
        $command.CommandText = $Text
        $table = New-Object -TypeName System.Data.DataTable
        $table.Load($command.ExecuteReader())
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
        $sql.Dispose()
    }
}

$names = Read-Key "$root\Instance Names\SQL"
$id = $null
if ($null -ne $names) { $id = $names[$InstanceName] }
$named = $InstanceName -ne 'MSSQLSERVER'
$serviceNames = @{
    engine = if ($named) { 'MSSQL$' + $InstanceName } else { 'MSSQLSERVER' }
    agent = if ($named) { 'SQLAgent$' + $InstanceName } else { 'SQLSERVERAGENT' }
    fulltext = if ($named) { 'MSSQLFDLauncher$' + $InstanceName } else { 'MSSQLFDLauncher' }
}
$services = @{}
foreach ($kind in $serviceNames.Keys) {
    $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $serviceNames[$kind])
    $services[$kind] = $null
    if ($null -ne $service) {
        $services[$kind] = @{
            name = [string]$service.Name
            state = [string]$service.State
            start_mode = [string]$service.StartMode
            account = [string]$service.StartName
        }
    }
}
$images = @($ImagePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) -and (Get-DiskImage -ImagePath $_).Attached })

# Windows' pending-reboot markers, which SQL Server setup refuses to run with.
$control = 'HKLM:\SYSTEM\CurrentControlSet\Control'
$renames = (Get-ItemProperty -LiteralPath "$control\Session Manager" -ErrorAction SilentlyContinue).PendingFileRenameOperations
$activeName = (Get-ItemProperty -LiteralPath "$control\ComputerName\ActiveComputerName").ComputerName
$pendingName = (Get-ItemProperty -LiteralPath "$control\ComputerName\ComputerName").ComputerName
$rebootMarkers = @(
    @{ name = 'servicing'; set = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }
    @{ name = 'windows_update'; set = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' }
    @{ name = 'file_renames'; set = @($renames | Where-Object { $_ }).Count -gt 0 }
    @{ name = 'computer_rename'; set = $activeName -ne $pendingName }
)

$result = @{
    installed = $null -ne $id
    id = [string]$id
    services = $services
    attached_images = $images
    reboot_pending = @($rebootMarkers | Where-Object { $_.set }).Count -gt 0
    reboot_markers = @($rebootMarkers | Where-Object { $_.set } | ForEach-Object { $_.name })
    instance_names = @(if ($null -ne $names) { $names.Keys })
}
if ($null -ne $id) {
    $result.setup = Read-Key "$root\$id\Setup"
    $result.configuration_state = Read-Key "$root\$id\ConfigurationState"
    $result.tcp = Read-Key "$root\$id\MSSQLServer\SuperSocketNetLib\Tcp"
}

if ($Query -and $null -ne $id -and $null -ne $services.engine -and $services.engine.state -eq 'Running') {
    $server = 'lpc:' + $env:COMPUTERNAME
    if ($named) { $server += '\' + $InstanceName }
    $connection = "Data Source=$server;Integrated Security=SSPI;Connect Timeout=15"
    $properties = (Invoke-Sql $connection @'
SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
    CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS collation,
    CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(4000)) AS backup_path,
    SUSER_SNAME() AS login, IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin
'@)[0]
    $result.server = @{
        edition = [string]$properties.edition
        product_version = [string]$properties.product_version
        collation = [string]$properties.collation
        backup_path = [string]$properties.backup_path
        login = [string]$properties.login
        is_sysadmin = $properties.is_sysadmin -eq 1
        sysadmins = @(Invoke-Sql $connection @'
SELECT p.name FROM sys.server_role_members AS m
JOIN sys.server_principals AS r ON r.principal_id = m.role_principal_id
JOIN sys.server_principals AS p ON p.principal_id = m.member_principal_id
WHERE r.name = N'sysadmin'
'@ | ForEach-Object { [string]$_.name })
        services = @(Invoke-Sql $connection 'SELECT servicename, service_account, instant_file_initialization_enabled FROM sys.dm_server_services' |
                ForEach-Object { '{0}|{1}|{2}' -f $_.servicename, $_.service_account, $_.instant_file_initialization_enabled })
        tempdb_data_files = @(Invoke-Sql $connection "SELECT name FROM tempdb.sys.database_files WHERE type_desc = 'ROWS'").Count
    }
}
$Ansible.Result = $result
