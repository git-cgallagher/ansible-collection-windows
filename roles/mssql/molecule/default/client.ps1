# What a client on another host sees of an instance over TCP, for verify.yml
# on dc01. Three probes, each recorded, none raised:
#
#   tls      a TLS handshake straight away, as TDS 8.0 (strict) clients open
#            a connection: the certificate the server presents and whether
#            this host trusts it for Server's name
#   prelogin a TDS 7.x PRELOGIN packet in the clear, as every older client
#            opens a connection: the first bytes the server answers with
#   sql      System.Data.SqlClient (TDS 7.x), once asking for encryption and
#            checking the certificate, once not asking: what SQL Server
#            reports about the connection (encrypt_option, auth_scheme, ...)
#
# Run it as a domain account (runas become) for auth_scheme to show Kerberos.
# Read-only.
param(
    [string]$Server,
    [int]$Port = 1433
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Add-Type -AssemblyName System.Data

function Get-InnermostMessage {
    param($Exception)
    $e = $Exception
    while ($null -ne $e.InnerException) { $e = $e.InnerException }
    $e.Message
}

# TLS first.
$tls = @{ handshake = $false; error = ''; thumbprint = ''; subject = ''; protocol = '' }
$client = New-Object -TypeName System.Net.Sockets.TcpClient
try {
    $client.ReceiveTimeout = 15000
    $client.SendTimeout = 15000
    $client.Connect($Server, $Port)
    $ssl = New-Object -TypeName System.Net.Security.SslStream -ArgumentList @($client.GetStream(), $false)
    $ssl.ReadTimeout = 15000
    $ssl.AuthenticateAsClient($Server, $null, [System.Security.Authentication.SslProtocols]::None, $false)
    $tls.handshake = $true
    $remote = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(, $ssl.RemoteCertificate)
    $tls.thumbprint = $remote.Thumbprint.ToLowerInvariant()
    $tls.subject = $remote.Subject
    $tls.protocol = [string]$ssl.SslProtocol
}
catch {
    $tls.error = Get-InnermostMessage $_.Exception
}
finally {
    $client.Dispose()
}

# A TDS 7.x PRELOGIN: VERSION and ENCRYPTION (ENCRYPT_ON) options.
$prelogin = @{ answered = $false; first_bytes = ''; length = 0; error = '' }
$packet = [byte[]](
    0x12, 0x01, 0x00, 0x1A, 0x00, 0x00, 0x01, 0x00,
    0x00, 0x00, 0x0B, 0x00, 0x06,
    0x01, 0x00, 0x11, 0x00, 0x01,
    0xFF,
    0x0F, 0x00, 0x07, 0xD0, 0x00, 0x00,
    0x01)
$client = New-Object -TypeName System.Net.Sockets.TcpClient
try {
    $client.ReceiveTimeout = 15000
    $client.Connect($Server, $Port)
    $stream = $client.GetStream()
    $stream.Write($packet, 0, $packet.Length)
    $buffer = New-Object -TypeName byte[] -ArgumentList 64
    $read = $stream.Read($buffer, 0, $buffer.Length)
    $prelogin.length = $read
    $prelogin.answered = $read -gt 0
    if ($read -gt 0) {
        $prelogin.first_bytes = (@($buffer[0..([Math]::Min($read, 8) - 1)] | ForEach-Object { '{0:x2}' -f $_ }) -join ' ')
    }
}
catch {
    $prelogin.error = Get-InnermostMessage $_.Exception
}
finally {
    $client.Dispose()
}

# SqlClient, with and without asking for encryption.
$query = @'
SELECT c.encrypt_option, c.auth_scheme, c.net_transport, CAST(c.protocol_version AS bigint) AS protocol_version,
    SUSER_SNAME() AS login
FROM sys.dm_exec_connections AS c
WHERE c.session_id = @@SPID
'@
$sql = @{}
foreach ($case in @(@{ name = 'encrypt'; options = 'Encrypt=True;TrustServerCertificate=False' }, @{ name = 'plain'; options = 'Encrypt=False' })) {
    $outcome = @{ connected = $false; error = '' }
    $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList (
        'Data Source=tcp:{0},{1};Integrated Security=SSPI;{2};Connect Timeout=15;Application Name=mssql-lab-client' -f $Server, $Port, $case.options)
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $query
        $reader = $command.ExecuteReader()
        if ($reader.Read()) {
            $outcome.connected = $true
            $outcome.encrypt_option = [string]$reader['encrypt_option']
            $outcome.auth_scheme = [string]$reader['auth_scheme']
            $outcome.net_transport = [string]$reader['net_transport']
            $outcome.protocol_version = '0x{0:x8}' -f [long]$reader['protocol_version']
            $outcome.login = [string]$reader['login']
        }
        $reader.Close()
    }
    catch {
        $outcome.error = Get-InnermostMessage $_.Exception
    }
    finally {
        $connection.Dispose()
    }
    $sql[$case.name] = $outcome
}

# The output, read as output[0] (win_powershell with depth 5).
@{ server = $Server; port = $Port; tls = $tls; prelogin = $prelogin; sql = $sql }
