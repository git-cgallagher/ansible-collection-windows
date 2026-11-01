# read_export.ps1 — the gpo_export target's view of a working directory, read
# from the file system and the zip (never through the module under test).
#
# Returns:
#   exists        whether the working directory exists
#   files         every file under it: path (relative, lower-cased), size and
#                 last-write ticks, sorted; two reads compare equal when the
#                 directory is byte-for-byte as it was
#   zip_exists    whether gpo-export.zip is there
#   entries       the zip's entry names, sorted
#   zip_gpos      the GPO folder names under gpos/ in the zip, sorted
#   manifest      gpo-manifest.json from the zip, parsed; $null without a zip
#   state_exists  whether the per-domain state file is there
#   state         the state file, parsed: hash_basis, manifest_hash and the
#                 GPO names it records (sorted); $null without one

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkDir,
    [Parameter(Mandatory = $true)][string]$Domain
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$result = [ordered]@{
    exists = [bool](Test-Path -LiteralPath $WorkDir -PathType Container)
    files = @()
    zip_exists = $false
    entries = @()
    zip_gpos = @()
    manifest = $null
    state_exists = $false
    state = $null
}

if ($result.exists) {
    $base = (Get-Item -LiteralPath $WorkDir).FullName.TrimEnd('\') + '\'
    $result.files = @(Get-ChildItem -LiteralPath $WorkDir -Recurse -Force -File | ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($base.Length).ToLowerInvariant()
                size = [long]$_.Length
                mtime = [long]$_.LastWriteTimeUtc.Ticks
            }
        } | Sort-Object { $_.path })

    $zipPath = Join-Path $WorkDir 'gpo-export.zip'
    if (Test-Path -LiteralPath $zipPath) {
        $result.zip_exists = $true
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $result.entries = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object)
            $result.zip_gpos = @($result.entries | Where-Object { $_ -like 'gpos/*/*' } |
                    ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
            $manifestEntry = $zip.GetEntry('gpo-manifest.json')
            if ($manifestEntry) {
                $reader = New-Object System.IO.StreamReader($manifestEntry.Open(), [System.Text.Encoding]::UTF8)
                try { $result.manifest = $reader.ReadToEnd() | ConvertFrom-Json }
                finally { $reader.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }

    $stateFile = Join-Path $WorkDir ('backup-state-{0}.json' -f $Domain.ToLowerInvariant())
    if (Test-Path -LiteralPath $stateFile) {
        $result.state_exists = $true
        $raw = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $hashBasis = $null
        if ($raw.PSObject.Properties['hash_basis']) { $hashBasis = [string]$raw.hash_basis }
        $gpoNames = @()
        if ($raw.PSObject.Properties['gpos']) { $gpoNames = @($raw.gpos.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object) }
        $result.state = [ordered]@{
            hash_basis = $hashBasis
            manifest_hash = [string]$raw.manifest_hash
            gpos = $gpoNames
        }
    }
}

$Ansible.Changed = $false
$Ansible.Result = $result
