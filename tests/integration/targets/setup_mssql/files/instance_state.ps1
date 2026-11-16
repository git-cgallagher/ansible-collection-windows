# Read one SQL Server instance for the mssql targets' and the role scenario's
# assertions: its registry keys (network settings included), its services,
# its errorlog's last start, the firewall rule mssql_network names after it,
# who may read Thumbprint's private key, and (with Query) what SQL Server says
# about itself; plus which of ImagePaths are mounted. Read-only, and
# independent of the modules under test and their util: the registry,
# Win32_Service, the errorlog, NetSecurity, the certificate store and
# System.Data.SqlClient, directly.
param(
    [string]$InstanceName = 'MSSQLSERVER',
    [bool]$Query = $true,
    [string[]]$ImagePaths = @(),
    [string]$Thumbprint = ''
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Add-Type -AssemblyName System.Data

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
    $netLib = "$root\$id\MSSQLServer\SuperSocketNetLib"
    $result.setup = Read-Key "$root\$id\Setup"
    $result.configuration_state = Read-Key "$root\$id\ConfigurationState"
    $result.tcp = Read-Key "$netLib\Tcp"
    $result.tcp_all = Read-Key "$netLib\Tcp\IPAll"
    $result.netlib = Read-Key $netLib
    # The kinds setup gave the values (String, DWord), for the log.
    $netLibKey = Get-Item -LiteralPath $netLib -ErrorAction SilentlyContinue
    $result.netlib_kinds = @{}
    if ($null -ne $netLibKey) { foreach ($name in $netLibKey.GetValueNames()) { $result.netlib_kinds[$name] = [string]$netLibKey.GetValueKind($name) } }

    # The errorlog's last start: the -e startup parameter names the file,
    # which SQL Server holds open (UTF-16).
    $errorLog = @{ path = ''; process_id = 0; certificate = ''; ports = @(); ready = $false; lines = @() }
    $parameters = Read-Key "$root\$id\MSSQLServer\Parameters"
    if ($null -ne $parameters) {
        foreach ($value in $parameters.Values) { if ($value -match '^-e(.+)$') { $errorLog.path = $Matches[1] } }
    }
    if ($errorLog.path -and (Test-Path -LiteralPath $errorLog.path)) {
        $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @(
            $errorLog.path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try { $text = (New-Object -TypeName System.IO.StreamReader -ArgumentList @($stream, $true)).ReadToEnd() }
        finally { $stream.Dispose() }
        $ports = [System.Collections.Generic.List[int]]::new()
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match 'Server process ID is (\d+)') { $errorLog.process_id = [int]$Matches[1] }
            if ($line -match 'Cert Hash\(sha1\) "([0-9A-Fa-f]+)"\] was successfully loaded') { $errorLog.certificate = $Matches[1].ToLowerInvariant() }
            if ($line -match 'self-generated certificate was successfully loaded') { $errorLog.certificate = 'self-generated' }
            if ($line -match "listening on \[ 'any' <ipv4> (\d+)\]") { $ports.Add([int]$Matches[1]) }
            if ($line -match 'ready for client connections') { $errorLog.ready = $true }
        }
        $errorLog.ports = $ports.ToArray()
        # The lines about encryption, TLS and TDS, for the log.
        $errorLog.lines = @($text -split "`r?`n" | Where-Object { $_ -match '(?i)encrypt|certificate|TDS|TLS|strict|listening' } |
                Select-Object -First 25 | ForEach-Object { $_.Trim() })
    }
    $result.errorlog = $errorLog
}

# The firewall rule mssql_network names after the instance.
$result.firewall = $null
$rule = Get-NetFirewallRule -Name ('mssql-iac-{0}-tcp' -f $InstanceName) -ErrorAction SilentlyContinue
if ($null -ne $rule) {
    $portFilter = $rule | Get-NetFirewallPortFilter
    $result.firewall = @{
        enabled = [string]$rule.Enabled
        direction = [string]$rule.Direction
        action = [string]$rule.Action
        profile = [string]$rule.Profile
        protocol = [string]$portFilter.Protocol
        ports = @($portFilter.LocalPort | ForEach-Object { [string]$_ })
    }
}

# Who an allow rule lets read the certificate's private key (a legacy CSP
# key, under MachineKeys).
$result.key_readers = @()
if ($Thumbprint) {
    $certificate = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $Thumbprint.ToUpperInvariant()) -ErrorAction SilentlyContinue
    if ($null -ne $certificate -and $certificate.HasPrivateKey) {
        $container = $certificate.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
        $keyFile = Join-Path $env:ProgramData ('Microsoft\Crypto\RSA\MachineKeys\' + $container)
        $result.key_readers = @((Get-Acl -LiteralPath $keyFile).Access | Where-Object { [string]$_.AccessControlType -eq 'Allow' } |
                ForEach-Object { [string]$_.IdentityReference })
    }
}

if ($Query -and $null -ne $id -and $null -ne $services.engine -and $services.engine.state -eq 'Running') {
    $server = 'lpc:' + $env:COMPUTERNAME
    if ($named) { $server += '\' + $InstanceName }
    $connection = "Data Source=$server;Integrated Security=SSPI;Connect Timeout=15"
    # One row comes back from the function as itself, not an array: @() first.
    $properties = @(Invoke-Sql $connection @'
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
# The output, read as output[0] (win_powershell with depth 5).
$result
