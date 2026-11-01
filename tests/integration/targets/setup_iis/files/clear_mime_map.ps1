# clear_mime_map.ps1: puts the test website and its applications back to
# inheriting the server's MIME map, for the IIS targets' cleanup. Deletes the
# <location> elements for the website and the paths under it from
# applicationHost.config, which hold only what the tests wrote there, and the
# web.config files in the given directories, which setup_iis doesn't create.
# Run through ansible.windows.win_powershell. Windows PowerShell 5.1.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]
    $Site,

    [string[]]
    $PhysicalPath = @()
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false

$appHostPath = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'inetsrv', 'config', 'applicationHost.config')
$appHost = New-Object -TypeName System.Xml.XmlDocument
$appHost.PreserveWhitespace = $true
$appHost.Load($appHostPath)

$stale = @(
    foreach ($node in $appHost.SelectNodes('/configuration/location')) {
        $path = $node.GetAttribute('path')
        if ($path -eq $Site -or $path.StartsWith("$Site/", [System.StringComparison]::OrdinalIgnoreCase)) {
            $node
        }
    }
)
foreach ($node in $stale) {
    $null = $node.ParentNode.RemoveChild($node)
}
if ($stale.Count -gt 0) {
    $appHost.Save($appHostPath)
    $Ansible.Changed = $true
}

foreach ($directory in $PhysicalPath) {
    $webConfig = [System.IO.Path]::Combine($directory, 'web.config')
    if (Test-Path -LiteralPath $webConfig -PathType Leaf) {
        Remove-Item -LiteralPath $webConfig -Force
        $Ansible.Changed = $true
    }
}
