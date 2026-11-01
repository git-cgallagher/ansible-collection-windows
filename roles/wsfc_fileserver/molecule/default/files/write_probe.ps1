# Diagnostics for verify.yml when a share refuses the client: try a write to
# each share by several names in one logon session, then record which SMB
# connections and Kerberos tickets that session ended up with. Read-only
# apart from the probe files, which it removes.
param([string]$Server, [string]$Domain, [string]$Address, [string[]]$Shares, [string[]]$Local)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false

$targets = @()
foreach ($share in $Shares) {
    foreach ($name in @($Server, "$Server.$Domain", $Address)) {
        if ($name) { $targets += "\\$name\$share" }
    }
}
$targets += @($Local | Where-Object { $_ })

$attempts = foreach ($target in $targets) {
    $file = Join-Path $target ('.lab-probe-{0}.txt' -f [guid]::NewGuid())
    $outcome = 'ok'
    try {
        Set-Content -LiteralPath $file -Value 'probe' -Encoding ASCII
        Remove-Item -LiteralPath $file -Force
    }
    catch {
        $outcome = '{0}: {1} (HRESULT 0x{2:X8})' -f $_.Exception.GetType().Name, $_.Exception.Message, $_.Exception.HResult
    }
    '{0} -> {1}' -f $target, $outcome
}

[ordered]@{
    identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    computer = $env:COMPUTERNAME
    attempts = @($attempts) -join ' || '
    connections = @(Get-SmbConnection -ErrorAction SilentlyContinue | ForEach-Object {
            '{0}\{1} user={2} credential={3} dialect={4}' -f $_.ServerName, $_.ShareName, $_.UserName, $_.Credential, $_.Dialect
        }) -join ' || '
    tickets = @(klist | Select-String -Pattern 'Server:' | ForEach-Object { $_.Line.Trim() }) -join ' || '
}
