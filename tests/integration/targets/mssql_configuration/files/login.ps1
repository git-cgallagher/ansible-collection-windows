# Gives a Windows account a login with no server role on the instance
# (State present), or drops it (State absent), for mssql_configuration's
# ALTER SETTINGS refusal. Runs as a sysadmin, in plain T-SQL through
# System.Data.SqlClient. Returns created (whether it made the login now) and
# alter_settings (whether the account can change settings through any login
# or group it has, as EXECUTE AS LOGIN shows; true when that can't be read,
# so the target skips the case rather than fail it).
param(
    [string]$InstanceName = 'MSSQLSERVER',
    [string]$Login,
    [ValidateSet('present', 'absent')][string]$State = 'present'
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Add-Type -AssemblyName System.Data

function Invoke-Scalar {
    param([object]$Connection, [string]$Text, [string]$Login)
    $command = $Connection.CreateCommand()
    $command.CommandText = $Text
    $null = $command.Parameters.AddWithValue('@login', $Login)
    $command.ExecuteScalar()
}

$server = 'lpc:' + $env:COMPUTERNAME
if ($InstanceName -ne 'MSSQLSERVER') { $server += '\' + $InstanceName }
$connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList "Data Source=$server;Integrated Security=SSPI;Connect Timeout=15"
$connection.Open()
try {
    # CREATE LOGIN and DROP LOGIN take no parameters: the name goes in
    # bracketed, as QUOTENAME does.
    $quoted = '[' + $Login.Replace(']', ']]') + ']'
    $count = Invoke-Scalar -Connection $connection -Text 'SELECT COUNT(*) FROM sys.server_principals WHERE name = @login' -Login $Login
    $exists = [int]$count -gt 0
    $created = $false
    if ($State -eq 'present' -and -not $exists) {
        $null = Invoke-Scalar -Connection $connection -Text "CREATE LOGIN $quoted FROM WINDOWS" -Login $Login
        $created = $true
        $Ansible.Changed = $true
    }
    elseif ($State -eq 'absent' -and $exists) {
        $null = Invoke-Scalar -Connection $connection -Text "DROP LOGIN $quoted" -Login $Login
        $Ansible.Changed = $true
    }
    $alterSettings = $true
    $readError = ''
    if ($State -eq 'present') {
        try {
            $text = "EXECUTE AS LOGIN = @login; SELECT HAS_PERMS_BY_NAME(NULL, NULL, 'ALTER SETTINGS'); REVERT;"
            $alterSettings = [int](Invoke-Scalar -Connection $connection -Text $text -Login $Login) -eq 1
        }
        catch {
            $readError = $_.Exception.Message
        }
    }
    @{ created = $created; alter_settings = $alterSettings; read_error = $readError }
}
finally {
    $connection.Dispose()
}
