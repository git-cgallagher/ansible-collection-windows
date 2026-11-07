#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._MssqlCommon

# Configures how a SQL Server instance listens and encrypts: a static TCP
# port (dynamic ports off), the certificate it binds by thumbprint (with read
# access to its private key for the engine), the encryption mode (optional;
# mandatory, Force Encryption; strict, Force Strict Encryption) and inbound
# firewall rules. It writes the registry under the instance's
# SuperSocketNetLib key, as SQL Server Configuration Manager does, so it
# never connects to SQL Server. Get-MssqlNetworkPlan
# (plugins/module_utils/_MssqlCommon.psm1) decides the registry writes.
#
# Every registry change takes effect when the engine restarts. With restart,
# the module restarts it, starts the services that stopped with it, and
# checks the errorlog for the certificate and port it asked for. Without, it
# reports restart_required, and records when it wrote the settings
# (C:\ProgramData\mssql-iac\network\<instance id>.restart), so later runs
# keep reporting it until the engine has restarted.
#
# Check mode runs every check that only reads (the certificate, the instance,
# the firewall rules) and changes nothing.

$spec = @{
    options = @{
        instance_name = @{ type = 'str'; default = 'MSSQLSERVER' }
        tcp_port = @{ type = 'int' }
        encryption = @{ type = 'str'; choices = @('optional', 'mandatory', 'strict') }
        certificate_thumbprint = @{ type = 'str' }
        firewall = @{ type = 'bool' }
        restart = @{ type = 'bool'; default = $false }
        restart_timeout = @{ type = 'int'; default = 300 }
    }
    required_if = @(
        @('encryption', 'mandatory', @('certificate_thumbprint')),
        @('encryption', 'strict', @('certificate_thumbprint'))
    )
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$params = $module.Params
$instanceName = [string]$params.instance_name
$tcpPort = $params.tcp_port
$encryption = [string]$params.encryption
$firewall = $params.firewall
$restart = [bool]$params.restart
$checkMode = $module.CheckMode

$actions = [System.Collections.Generic.List[string]]::new()
$notices = [System.Collections.Generic.List[string]]::new()
$script:instance = $null
$script:certificate = $null
$script:firewallRules = @()
$script:restartRequired = $false
$script:restarted = $false
$script:services = @{}
$script:running = $null
$script:registry = $null

# Refusals that need nothing from the host.
$problems = [System.Collections.Generic.List[string]]::new()
$problems.Add((Get-MssqlInstanceNameProblem $instanceName))
if ($null -ne $tcpPort -and ($tcpPort -lt 1 -or $tcpPort -gt 65535)) { $problems.Add("tcp_port must be 1 to 65535, got $tcpPort") }
if ($params.certificate_thumbprint) { $problems.Add((Get-MssqlThumbprintProblem $params.certificate_thumbprint)) }
if ($params.restart_timeout -lt 30) { $problems.Add("restart_timeout must be 30 seconds or more, got $($params.restart_timeout)") }
$problem = @($problems | Where-Object { $_ }) | Select-Object -First 1
if ($problem) { $module.FailJson($problem) }
$thumbprint = ''
if ($params.certificate_thumbprint) { $thumbprint = ConvertTo-MssqlThumbprint $params.certificate_thumbprint }

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

# Each value's kind (String, DWord, ...), by name, so a write keeps the kind
# setup gave it.
function Get-RegistryValueKind {
    param([string]$Path)
    $key = Get-Item -LiteralPath $Path
    $kinds = @{}
    foreach ($name in $key.GetValueNames()) { $kinds[$name] = [string]$key.GetValueKind($name) }
    $kinds
}

function Read-NetworkRegistry {
    param([string]$Base)
    $paths = @{
        NetLib = "$Base\SuperSocketNetLib"
        Tcp = "$Base\SuperSocketNetLib\Tcp"
        TcpAll = "$Base\SuperSocketNetLib\Tcp\IPAll"
    }
    $values = @{}
    $kinds = @{}
    foreach ($name in $paths.Keys) {
        $values[$name] = Get-MssqlRegistryValue $paths[$name]
        if ($null -eq $values[$name]) { throw "The registry has no $($paths[$name]), where SQL Server keeps instance $instanceName's network settings" }
        $kinds[$name] = Get-RegistryValueKind $paths[$name]
    }
    @{
        Paths = $paths
        Kinds = $kinds
        Current = @{
            TcpEnabled = $values.Tcp['Enabled']
            ListenOnAllIPs = $values.Tcp['ListenOnAllIPs']
            TcpPort = $values.TcpAll['TcpPort']
            TcpDynamicPorts = $values.TcpAll['TcpDynamicPorts']
            ForceEncryption = $values.NetLib['ForceEncryption']
            ForceStrict = $values.NetLib['ForceStrict']
            Certificate = $values.NetLib['Certificate']
        }
    }
}

# The certificate as Get-MssqlCertificateProblem checks it. .NET Framework's
# X509Certificate2.PrivateKey opens only a legacy CSP key, and throws for a
# CNG (KSP) key, which SQL Server can't use either.
function Get-CertificateInfo {
    param([string]$Thumbprint)
    $info = @{
        Thumbprint = $Thumbprint; Found = $false; Subject = ''; DnsNames = @(); NotBefore = $null; NotAfter = $null
        ServerAuth = $false; HasPrivateKey = $false; KeyProvider = ''; ProviderName = ''; MachineKey = $false; KeySpec = 0; KeyPath = ''
    }
    $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $Thumbprint.ToUpperInvariant()) -ErrorAction SilentlyContinue
    if ($null -eq $cert) { return $info }
    $info.Found = $true
    $info.Subject = [string]$cert.Subject
    $info.DnsNames = @($cert.DnsNameList | ForEach-Object { [string]$_.Unicode })
    $info.NotBefore = $cert.NotBefore
    $info.NotAfter = $cert.NotAfter
    $eku = @($cert.Extensions | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension] })
    if ($eku.Count -gt 0) { $info.ServerAuth = @($eku[0].EnhancedKeyUsages | Where-Object { $_.Value -eq '1.3.6.1.5.5.7.3.1' }).Count -gt 0 }
    $info.HasPrivateKey = [bool]$cert.HasPrivateKey
    if ($cert.HasPrivateKey) {
        $info.KeyProvider = 'ksp'
        try {
            $key = $cert.PrivateKey
            if ($key -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
                $container = $key.CspKeyContainerInfo
                $info.KeyProvider = 'csp'
                $info.ProviderName = [string]$container.ProviderName
                $info.MachineKey = [bool]$container.MachineKeyStore
                $info.KeySpec = [int]$container.KeyNumber
                $info.KeyPath = Join-Path $env:ProgramData ('Microsoft\Crypto\RSA\MachineKeys\' + $container.UniqueKeyContainerName)
            }
        }
        catch {
            $info.KeyProvider = 'ksp'
        }
    }
    $info
}

function ConvertTo-Sid {
    param([string]$Account)
    $name = $Account
    if ($name.StartsWith('.\')) { $name = $env:COMPUTERNAME + $name.Substring(1) }
    try {
        (New-Object -TypeName System.Security.Principal.NTAccount -ArgumentList $name).Translate([System.Security.Principal.SecurityIdentifier])
    }
    catch {
        throw "Can't resolve '$Account' to a SID, to grant it read access to the certificate's private key: $($_.Exception.Message)"
    }
}

# Whether the SID holds an allow rule that reads the file (a rule of its own,
# not through a group).
function Test-KeyRead {
    param([string]$Path, [System.Security.Principal.SecurityIdentifier]$Sid)
    $acl = [System.IO.File]::GetAccessControl($Path, [System.Security.AccessControl.AccessControlSections]::Access)
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        $allows = $rule.IdentityReference -eq $Sid -and [string]$rule.AccessControlType -eq 'Allow'
        if ($allows -and (Test-MssqlReadRight -Rights ([long]$rule.FileSystemRights))) { return $true }
    }
    $false
}

function Grant-KeyRead {
    param([string]$Path, [System.Security.Principal.SecurityIdentifier]$Sid)
    $acl = [System.IO.File]::GetAccessControl($Path, [System.Security.AccessControl.AccessControlSections]::Access)
    $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $Sid, [System.Security.AccessControl.FileSystemRights]::Read, [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($rule)
    [System.IO.File]::SetAccessControl($Path, $acl)
}

# Read access to the private key for the engine's per-service SID, which the
# service carries whatever account it logs on as, and for that account, as
# Microsoft's steps grant it. LocalSystem reads machine keys already.
function Set-KeyAccess {
    param([hashtable]$Certificate, [string]$EngineAccount)
    $readers = [System.Collections.Generic.List[string]]::new()
    $readers.Add((Get-MssqlServiceSidName $instanceName))
    if ($EngineAccount -and $EngineAccount -notmatch '^(LocalSystem|NT AUTHORITY\\SYSTEM|\.\\LocalSystem)$' -and $readers -notcontains $EngineAccount) {
        $readers.Add($EngineAccount)
    }
    $granted = [System.Collections.Generic.List[string]]::new()
    foreach ($reader in $readers) {
        $sid = ConvertTo-Sid $reader
        if (-not (Test-KeyRead -Path $Certificate.KeyPath -Sid $sid)) {
            Invoke-Change "grant $reader read access to certificate $($Certificate.Thumbprint)'s private key" {
                Grant-KeyRead -Path $Certificate.KeyPath -Sid $sid
            }
        }
        $granted.Add($reader)
    }
    $granted.ToArray()
}

function Get-FirewallRuleState {
    param([string]$Name)
    $rule = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $rule) { return $null }
    $portFilter = $rule | Get-NetFirewallPortFilter
    @{
        DisplayName = [string]$rule.DisplayName
        Enabled = [string]$rule.Enabled
        Direction = [string]$rule.Direction
        Action = [string]$rule.Action
        Profile = [string]$rule.Profile
        Protocol = [string]$portFilter.Protocol
        LocalPort = @($portFilter.LocalPort | ForEach-Object { [string]$_ })
    }
}

function Set-FirewallRule {
    param([string[]]$Ports)
    $rules = [System.Collections.Generic.List[object]]::new()
    foreach ($ruleSpec in @(Get-MssqlFirewallRuleSpec -InstanceName $instanceName -Ports $Ports)) {
        $existing = Get-FirewallRuleState $ruleSpec.Name
        $settings = @{
            Direction = 'Inbound'; Action = 'Allow'; Profile = 'Any'; Enabled = 'True'
            Protocol = $ruleSpec.Protocol; LocalPort = $ruleSpec.LocalPort
        }
        if ($null -eq $existing) {
            Invoke-Change "add firewall rule '$($ruleSpec.DisplayName)'" {
                $null = New-NetFirewallRule -Name $ruleSpec.Name -DisplayName $ruleSpec.DisplayName -Group $ruleSpec.Group @settings
            }
        }
        else {
            $difference = Get-MssqlFirewallRuleDifference -Spec $ruleSpec -Rule $existing
            if ($difference) {
                # Set-NetFirewallRule's -DisplayName selects rules; -NewDisplayName renames one.
                Invoke-Change "update firewall rule '$($ruleSpec.DisplayName)' (it had $difference)" {
                    Set-NetFirewallRule -Name $ruleSpec.Name -NewDisplayName $ruleSpec.DisplayName @settings
                }
            }
        }
        $rules.Add(@{ name = $ruleSpec.Name; display_name = $ruleSpec.DisplayName; protocol = $ruleSpec.Protocol; ports = @($ruleSpec.LocalPort) })
    }
    $rules.ToArray()
}

# The errorlog, read while SQL Server holds it open.
function Read-ErrorLog {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($stream, [System.Text.Encoding]::Unicode, $true)
        $text = $reader.ReadToEnd()
    }
    finally {
        $stream.Dispose()
    }
    @($text -split "`r?`n")
}

function Get-ErrorLogTail {
    param([string]$Path)
    (@(Read-ErrorLog $Path | Where-Object { $_.Trim() }) | Select-Object -Last 12) -join ' | '
}

function Get-EngineStartTime {
    param([string]$ServiceName)
    $filter = "Name='{0}'" -f ($ServiceName -replace "'", "''")
    $service = Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction SilentlyContinue
    if ($null -eq $service -or [string]$service.State -ne 'Running' -or -not $service.ProcessId) { return $null }
    $process = Get-Process -Id $service.ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    $process.StartTime.ToUniversalTime()
}

function Read-RestartMarker {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = ([System.IO.File]::ReadAllText($Path)).Trim()
    try {
        [datetime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    catch {
        # An unreadable marker still says something was written: treat it as
        # newer than any start.
        [datetime]::MaxValue
    }
}

function Write-RestartMarker {
    param([string]$Path)
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    [System.IO.File]::WriteAllText($Path, (Get-Date).ToUniversalTime().ToString('o'))
}

function Get-ServiceStateText {
    param([string]$Name)
    $state = (Get-MssqlServiceState -Name $Name)[$Name]
    if ($null -eq $state) { return '' }
    ([string]$state.State).ToLowerInvariant()
}

# Restarts the engine, waits for "ready for client connections" in its new
# errorlog, then starts the services that stopped with it (SQL Server Agent
# depends on the engine) and an Agent set to start automatically. An Agent
# that won't start is reported, not raised: the network change is done.
function Restart-Engine {
    param([string]$EngineName, [string]$AgentName, [string]$ErrorLogPath)
    $engineService = Get-Service -Name $EngineName
    $dependents = @($engineService.DependentServices | Where-Object { [string]$_.Status -eq 'Running' } | ForEach-Object { $_.Name })
    $agent = (Get-MssqlServiceState -Name $AgentName)[$AgentName]
    $toStart = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $dependents) { $toStart.Add($name) }
    if ($null -ne $agent -and [string]$agent.StartMode -eq 'Auto' -and -not $toStart.Contains($AgentName)) { $toStart.Add($AgentName) }

    Restart-Service -Name $EngineName -Force
    # The new process's own errorlog: SQL Server starts a new one, and names
    # its process ID near the top.
    $filter = "Name='{0}'" -f ($EngineName -replace "'", "''")
    $deadline = (Get-Date).AddSeconds($params.restart_timeout)
    $log = $null
    $processId = 0
    do {
        Start-Sleep -Seconds 2
        $service = Get-CimInstance -ClassName Win32_Service -Filter $filter
        $processId = [int]$service.ProcessId
        $log = Get-MssqlErrorLogFact -Lines (Read-ErrorLog $ErrorLogPath)
        $current = $processId -ne 0 -and $log.ProcessId -eq $processId
    } until (($current -and $log.Ready) -or [string]$service.State -eq 'Stopped' -or (Get-Date) -gt $deadline)
    if ((Get-ServiceStateText $EngineName) -ne 'running') {
        throw "SQL Server ($EngineName) didn't start again after the change. Its errorlog ends: $(Get-ErrorLogTail $ErrorLogPath)"
    }
    if (-not ($current -and $log.Ready)) {
        throw ("SQL Server ($EngineName) didn't get to ""ready for client connections"" within $($params.restart_timeout) seconds of " +
            "its restart. Its errorlog ends: $(Get-ErrorLogTail $ErrorLogPath)")
    }
    $script:restarted = $true

    foreach ($name in $toStart) {
        try {
            Start-Service -Name $name
        }
        catch {
            Add-Notice ("$name didn't start again after $EngineName restarted: $($_.Exception.Message)")
            continue
        }
        # A service that can't reach SQL Server can start and then stop.
        Start-Sleep -Seconds 10
        $state = Get-ServiceStateText $name
        if ($state -ne 'running') { Add-Notice "$name stopped again after it started (state: $state); its log says why" }
    }
}

function Get-NetworkFact {
    param([hashtable]$Current)
    $dynamic = [string]$Current.TcpDynamicPorts
    @{
        tcp = @{
            enabled = [string]$Current.TcpEnabled -eq '1'
            listen_all = [string]$Current.ListenOnAllIPs -ne '0'
            port = [string]$Current.TcpPort
            dynamic_ports = $dynamic
        }
        encryption = @{
            mode = ConvertTo-MssqlEncryptionMode -ForceEncryption $Current.ForceEncryption -ForceStrict $Current.ForceStrict
            force_encryption = [string]$Current.ForceEncryption -eq '1'
            force_strict = [string]$Current.ForceStrict -eq '1'
            certificate = ConvertTo-MssqlThumbprint ([string]$Current.Certificate)
        }
    }
}

function Invoke-Main {
    $entry = @(Get-MssqlInstanceRegistry | Where-Object { $_.Name -eq $instanceName }) | Select-Object -First 1
    if ($null -eq $entry) { throw "Instance $instanceName isn't installed on this host" }
    if ($null -ne $entry.Cluster) { throw "Instance $instanceName is a failover cluster instance, which mssql_network doesn't configure yet" }
    $version = ConvertTo-MssqlVersionName $entry.Id
    $script:instance = @{ name = $instanceName; id = $entry.Id; version = $version }
    $base = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$($entry.Id)\MSSQLServer"
    $registry = Read-NetworkRegistry $base
    $script:registry = $registry.Current
    $errorLogPath = Get-MssqlErrorLogPath (Get-MssqlRegistryValue "$base\Parameters")
    $engineName = Get-MssqlServiceName -InstanceName $instanceName -Service 'engine'
    $agentName = Get-MssqlServiceName -InstanceName $instanceName -Service 'agent'
    $engine = (Get-MssqlServiceState -Name $engineName)[$engineName]
    if ($null -eq $engine) { throw "Instance $instanceName has no service $engineName" }

    # The certificate: SQL Server won't start with one it can't load, so a
    # problem fails the run before anything is written.
    if ($thumbprint) {
        $certificate = Get-CertificateInfo $thumbprint
        $certificateProblem = Get-MssqlCertificateProblem -Certificate $certificate
        if ($certificateProblem) { throw $certificateProblem }
        $ipProperties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
        $hostName = $ipProperties.HostName
        if ($ipProperties.DomainName) { $hostName = '{0}.{1}' -f $ipProperties.HostName, $ipProperties.DomainName }
        $nameNotice = Get-MssqlCertificateNameNotice -DnsNames $certificate.DnsNames -HostName $hostName -Thumbprint $thumbprint
        if ($nameNotice) { Add-Notice $nameNotice }
        $readers = Set-KeyAccess -Certificate $certificate -EngineAccount ([string]$engine.Account)
        $script:certificate = @{
            thumbprint = $thumbprint
            subject = $certificate.Subject
            dns_names = @($certificate.DnsNames)
            not_after = $certificate.NotAfter.ToUniversalTime().ToString('o')
            key_provider = $certificate.ProviderName
            key_readers = @($readers)
        }
    }

    # The registry writes.
    $plan = Get-MssqlNetworkPlan -Current $registry.Current -Desired @{ TcpPort = $tcpPort; Encryption = $encryption; Thumbprint = $thumbprint }
    foreach ($notice in $plan.Notices) { Add-Notice $notice }
    # Not $change: Invoke-Change's own -Change parameter would hide it inside
    # the script block (variable names ignore case).
    foreach ($write in $plan.Changes) {
        $kind = $write.Kind
        if ($registry.Kinds[$write.Key].ContainsKey($write.Name)) { $kind = $registry.Kinds[$write.Key][$write.Name] }
        $path = $registry.Paths[$write.Key]
        Invoke-Change $write.Description {
            $null = New-ItemProperty -LiteralPath $path -Name $write.Name -Value $write.Value -PropertyType $kind -Force
        }
    }
    $registryChanged = @($plan.Changes).Count -gt 0
    if ($registryChanged -and -not $checkMode) { $script:registry = (Read-NetworkRegistry $base).Current }

    # The firewall: the instance's static ports, as they are after the writes.
    if ($firewall) {
        $portText = [string]$tcpPort
        if ($null -eq $tcpPort) { $portText = [string]$registry.Current.TcpPort }
        $ports = @($portText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($ports.Count -eq 0) {
            throw "firewall needs a static TCP port, and instance $instanceName uses dynamic ports: set tcp_port"
        }
        $script:firewallRules = Set-FirewallRule -Ports $ports
    }

    # The restart, now or later.
    $markerPath = Join-Path $env:ProgramData ("mssql-iac\network\{0}.restart" -f $entry.Id)
    $startedAt = Get-EngineStartTime $engineName
    $changedAt = Read-RestartMarker $markerPath
    $pending = Test-MssqlRestartPending -ChangedAt $changedAt -StartedAt $startedAt
    if ($null -ne $startedAt -and ($registryChanged -or $pending)) {
        if ($restart) {
            Invoke-Change "restart $engineName so the network settings take effect" {
                Restart-Engine -EngineName $engineName -AgentName $agentName -ErrorLogPath $errorLogPath
                if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force }
            }
        }
        else {
            $script:restartRequired = $true
            if ($registryChanged -and -not $checkMode) { Write-RestartMarker $markerPath }
            Add-Notice "The network settings take effect when $engineName restarts: restart it, or run with restart"
        }
    }
    elseif ($null -ne $changedAt -and -not $pending -and -not $checkMode) {
        # The engine started (or stopped) since the settings were written.
        Remove-Item -LiteralPath $markerPath -Force
    }

    # What the engine runs with, from its errorlog; after a restart, checked
    # against what was asked.
    $script:running = $null
    $log = Get-MssqlErrorLogFact -Lines (Read-ErrorLog $errorLogPath)
    if ($errorLogPath) {
        $script:running = @{
            certificate = $log.Certificate; ports = @($log.Ports); ready = $log.Ready; strict_lines = @($log.StrictLines); errorlog = $errorLogPath
        }
    }
    # A line the errorlog lacks is noted; one that names something else fails.
    if ($script:restarted) {
        if ($thumbprint -and -not $log.Certificate) {
            Add-Notice "$engineName restarted, and its errorlog doesn't say which certificate it loaded"
        }
        elseif ($thumbprint -and $log.Certificate -ne $thumbprint) {
            throw "$engineName restarted, but its errorlog says it loaded certificate '$($log.Certificate)', not $thumbprint"
        }
        if ($null -ne $tcpPort -and @($log.Ports).Count -eq 0) {
            Add-Notice "$engineName restarted, and its errorlog doesn't say which TCP ports it listens on"
        }
        elseif ($null -ne $tcpPort -and @($log.Ports) -notcontains $tcpPort) {
            throw "$engineName restarted, but its errorlog says it listens on TCP port(s) '$(@($log.Ports) -join ', ')', not $tcpPort"
        }
    }
    $script:services = @{ engine = Get-ServiceStateText $engineName; agent = Get-ServiceStateText $agentName }
}

function Set-ModuleResult {
    $module.Result.instance = $script:instance
    if ($null -ne $script:registry) {
        $facts = Get-NetworkFact $script:registry
        $module.Result.tcp = $facts.tcp
        $module.Result.encryption = $facts.encryption
    }
    $module.Result.certificate = $script:certificate
    $module.Result.firewall_rules = @($script:firewallRules)
    $module.Result.restart_required = $script:restartRequired
    $module.Result.restarted = $script:restarted
    $module.Result.services = $script:services
    $module.Result.running = $script:running
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
