#Requires -Version 5.1
# Reaches a clustered file server's shares the way a client does, through
# \\<server>\<share>, and proves each one takes a write and returns it.
#
#   roundtrip  write a probe file, read it back, delete it
#   mark       leave a marker file in each share (before a failover)
#   check      read and delete the marker files, then roundtrip
#
# Run by the validate and failover entry points on the client host. Changes
# nothing that outlives it except the markers, which check removes.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Server,

    [Parameter(Mandatory = $true)]
    [string[]]$Shares,

    [ValidateSet('roundtrip', 'mark', 'check')]
    [string]$Mode = 'roundtrip',

    [string]$Marker = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inAnsible = $null -ne (Get-Variable -Name Ansible -ErrorAction SilentlyContinue)

function Test-RoundTrip {
    param([string]$Unc)
    $token = [guid]::NewGuid().ToString()
    $file = Join-Path $Unc ".wsfc_fileserver-probe-$token.txt"
    Set-Content -LiteralPath $file -Value $token -Encoding ASCII
    try {
        $back = (Get-Content -LiteralPath $file -Raw).Trim()
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
    if ($back -ne $token) { throw "read back '$back', wrote '$token'" }
}

if ($Mode -ne 'roundtrip' -and -not $Marker) { throw "Mode $Mode needs a Marker" }

$results = [System.Collections.Generic.List[object]]::new()
foreach ($share in $Shares) {
    $unc = "\\$Server\$share"
    $entry = [ordered]@{ share = $share; unc = $unc; ok = $false; error = ''; error_type = '' }
    try {
        # Not Test-Path: on a share root it raised "Access is denied" under
        # $ErrorActionPreference = 'Stop' in the lab, though writes worked.
        # These return false instead of throwing.
        if (-not [System.IO.Directory]::Exists($unc)) { throw 'the share is not reachable' }
        $markerFile = Join-Path $unc ".wsfc_fileserver-failover-$Marker.txt"
        switch ($Mode) {
            'mark' {
                Set-Content -LiteralPath $markerFile -Value $Marker -Encoding ASCII
            }
            'check' {
                if (-not [System.IO.File]::Exists($markerFile)) { throw 'the marker written before the failover is gone' }
                $back = (Get-Content -LiteralPath $markerFile -Raw).Trim()
                Remove-Item -LiteralPath $markerFile -Force
                if ($back -ne $Marker) { throw "the marker reads '$back', expected '$Marker'" }
                Test-RoundTrip -Unc $unc
            }
            default {
                Test-RoundTrip -Unc $unc
            }
        }
        $entry.ok = $true
    }
    catch {
        $entry.error = $_.Exception.Message
        $entry.error_type = $_.Exception.GetType().FullName
    }
    $results.Add([pscustomobject]$entry)
}

$failedShares = @($results | Where-Object { -not $_.ok })
$result = [ordered]@{
    server = $Server
    mode = $Mode
    # Who reached the shares: a WinRM logon without credentials (no become)
    # reaches them anonymously, the double hop.
    identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    shares = $results.ToArray()
    failed = @($failedShares | ForEach-Object { $_.share })
}
if ($inAnsible) {
    $Ansible.Changed = $false
    $Ansible.Result = $result
    if ($failedShares.Count -gt 0) { $Ansible.Failed = $true }
}
else {
    [pscustomobject]$result
}
