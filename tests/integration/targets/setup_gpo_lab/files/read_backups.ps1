# read_backups.ps1 - the gpo_export and gpo_import targets' view of a directory
# of GPO backup folders, read from the file system (never through the modules
# under test or their module util).
#
# Returns:
#   exists   whether the directory exists
#   files    every file under it: path (relative, lower-cased), size and
#            last-write ticks, sorted; two reads compare equal when the
#            directory is byte-for-byte as it was
#   folders  one entry per subfolder, keyed by its name:
#              record   gpo-export.json, parsed; $null without one
#              backups  each {backup-id} subfolder: dir (its name), name,
#                       gpo_id and backup_id from its bkupInfo.xml, and
#                       complete (Backup.xml, bkupInfo.xml and gpreport.xml
#                       all there)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'

$result = [ordered]@{
    exists = [bool](Test-Path -LiteralPath $Path -PathType Container)
    files = @()
    folders = [ordered]@{}
}

if ($result.exists) {
    $base = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\') + '\'
    $result.files = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File | ForEach-Object {
            [ordered]@{
                path = $_.FullName.Substring($base.Length).ToLowerInvariant()
                size = [long]$_.Length
                mtime = [long]$_.LastWriteTimeUtc.Ticks
            }
        } | Sort-Object { $_.path })

    foreach ($folder in @(Get-ChildItem -LiteralPath $Path -Directory -Force | Sort-Object Name)) {
        $entry = [ordered]@{ record = $null; backups = @() }
        $recordFile = Join-Path $folder.FullName 'gpo-export.json'
        if (Test-Path -LiteralPath $recordFile) {
            $entry.record = Get-Content -LiteralPath $recordFile -Raw | ConvertFrom-Json
        }
        $entry.backups = @(Get-ChildItem -LiteralPath $folder.FullName -Directory -Force |
                Where-Object { $_.Name -match '^\{.+\}$' } | Sort-Object Name | ForEach-Object {
                    $b = [ordered]@{ dir = $_.Name; name = $null; gpo_id = $null; backup_id = $null; complete = $true }
                    foreach ($f in 'Backup.xml', 'bkupInfo.xml', 'gpreport.xml') {
                        if (-not (Test-Path -LiteralPath (Join-Path $_.FullName $f))) { $b.complete = $false }
                    }
                    $info = Join-Path $_.FullName 'bkupInfo.xml'
                    if (Test-Path -LiteralPath $info) {
                        [xml]$xml = Get-Content -LiteralPath $info -Raw
                        $ns = New-Object System.Xml.XmlNamespaceManager $xml.NameTable
                        $ns.AddNamespace('m', $xml.DocumentElement.NamespaceURI)
                        $b.name = $xml.SelectSingleNode('//m:GPODisplayName', $ns).InnerText
                        $b.gpo_id = $xml.SelectSingleNode('//m:GPOGuid', $ns).InnerText.Trim('{', '}').ToLowerInvariant()
                        $b.backup_id = $xml.SelectSingleNode('//m:ID', $ns).InnerText.Trim('{', '}').ToLowerInvariant()
                    }
                    $b
                })
        $result.folders[$folder.Name] = $entry
    }
}

$result
