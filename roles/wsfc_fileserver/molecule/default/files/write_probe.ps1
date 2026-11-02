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
    # Each step separately: write, read back with the provider and with .NET,
    # list the folder, delete.
    $steps = [ordered]@{
        write = { Set-Content -LiteralPath $file -Value 'probe' -Encoding ASCII }
        get_content = { $null = Get-Content -LiteralPath $file -Raw }
        read_all_text = { $null = [System.IO.File]::ReadAllText($file) }
        test_path_root = { if (-not (Test-Path -LiteralPath $target)) { throw 'false' } }
        list = { $null = [System.IO.Directory]::GetFiles($target) }
        delete = { Remove-Item -LiteralPath $file -Force }
    }
    $outcome = foreach ($step in $steps.Keys) {
        try {
            & $steps[$step]
            '{0}=ok' -f $step
        }
        catch {
            '{0}={1} (0x{2:X8})' -f $step, $_.Exception.Message, $_.Exception.HResult
        }
    }
    '{0} -> {1}' -f $target, ($outcome -join ', ')
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
