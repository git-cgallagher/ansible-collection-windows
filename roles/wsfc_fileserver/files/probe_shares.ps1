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
#
# Each share is retried for up to -RetrySeconds, for a client whose first
# connection to a just-moved file server lands mid-failover.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Server,

    [Parameter(Mandatory = $true)]
    [string[]]$Shares,

    [ValidateSet('roundtrip', 'mark', 'check')]
    [string]$Mode = 'roundtrip',

    [string]$Marker = '',

    [int]$RetrySeconds = 60
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inAnsible = $null -ne (Get-Variable -Name Ansible -ErrorAction SilentlyContinue)

# .NET file calls, each step named in its error (write, read, delete).
function Invoke-Step {
    param([string]$Step, [scriptblock]$Action)
    try {
        & $Action
    }
    catch {
        $message = $_.Exception.Message
        if ($null -ne $_.Exception.InnerException) { $message = $_.Exception.InnerException.Message }
        throw ('{0}: {1}' -f $Step, $message)
    }
}

function Test-RoundTrip {
    param([string]$Unc)
    $token = [guid]::NewGuid().ToString()
    $file = $Unc + '\.wsfc_fileserver-probe-' + $token + '.txt'
    Invoke-Step 'write' { [System.IO.File]::WriteAllText($file, $token) }
    $readError = $null
    try {
        $back = Invoke-Step 'read' { [System.IO.File]::ReadAllText($file).Trim() }
    }
    catch {
        $readError = $_
    }
    # Delete even after a failed read, but report the read's error first.
    Invoke-Step 'delete' { [System.IO.File]::Delete($file) }
    if ($null -ne $readError) { throw $readError }
    if ($back -ne $token) { throw "read back '$back', wrote '$token'" }
}

if ($Mode -ne 'roundtrip' -and -not $Marker) { throw "Mode $Mode needs a Marker" }

$results = [System.Collections.Generic.List[object]]::new()
foreach ($share in $Shares) {
    $unc = "\\$Server\$share"
    $entry = [ordered]@{ share = $share; unc = $unc; ok = $false; error = ''; error_type = ''; attempts = 0 }
    # The write is the reachability check; its error says why a share is
    # unreachable.
    $markerFile = $unc + '\.wsfc_fileserver-failover-' + $Marker + '.txt'
    $markerChecked = $false
    $deadline = (Get-Date).AddSeconds($RetrySeconds)
    while ($true) {
        $entry.attempts++
        try {
            switch ($Mode) {
                'mark' {
                    Invoke-Step 'write marker' { [System.IO.File]::WriteAllText($markerFile, $Marker) }
                }
                'check' {
                    if (-not $markerChecked) {
                        try {
                            $back = [System.IO.File]::ReadAllText($markerFile).Trim()
                        }
                        catch [System.IO.FileNotFoundException] {
                            throw 'the marker written before the failover is gone'
                        }
                        catch {
                            throw ('read marker: {0}' -f $_.Exception.Message)
                        }
                        if ($back -ne $Marker) { throw "the marker reads '$back', expected '$Marker'" }
                        Invoke-Step 'delete marker' { [System.IO.File]::Delete($markerFile) }
                        $markerChecked = $true
                    }
                    Test-RoundTrip -Unc $unc
                }
                default {
                    Test-RoundTrip -Unc $unc
                }
            }
            $entry.ok = $true
            $entry.error = ''
            $entry.error_type = ''
            break
        }
        catch {
            $entry.error = $_.Exception.Message
            $entry.error_type = $_.Exception.GetType().FullName
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Seconds 10
        }
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
