# read_mime_map.ps1: the IIS targets' own view of one configuration level's
# MIME map, so the modules under test are never their own witness. Run through
# ansible.windows.win_powershell (depth: 5); $Ansible.Result holds:
#
#   effective         [{extension, mime_type}]: what IIS serves at the level,
#                     read with appcmd.exe
#   application_host  [{element, extension, mime_type}]: the level's own
#                     mimeMap, remove and clear elements in applicationHost.config
#                     (its <location> elements, or the root at the server level)
#   web_config        the same for the web.config in PhysicalPath ([] without one)
#
# Windows PowerShell 5.1.

[CmdletBinding()]
param (
    # The website; '' for the server level.
    [string]
    $Site = '',

    # A virtual path under the website, such as /app1; '' for the site level.
    [string]
    $Application = '',

    # Only this extension, compared case-insensitively; '' for every entry.
    [string]
    $Extension = '',

    # The level's directory, where its web.config lives; '' to skip it.
    [string]
    $PhysicalPath = ''
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false

Function Get-StoredEntry {
    param (
        [AllowNull()]
        [object]
        $Node,

        [string]
        $Extension
    )

    foreach ($child in $Node) {
        if ($child.LocalName -notin @('mimeMap', 'remove', 'clear')) {
            continue
        }
        $fileExtension = $child.GetAttribute('fileExtension')
        if ($child.LocalName -eq 'clear' -or -not $Extension -or $fileExtension -eq $Extension) {
            [ordered]@{
                element = $child.LocalName
                extension = $fileExtension
                mime_type = $child.GetAttribute('mimeType')
            }
        }
    }
}

$location = ''
$appcmdArgs = @('list', 'config')
if ($Site) {
    $location = $Site + $Application
    $appcmdArgs += $location
}
$appcmdArgs += '-section:system.webServer/staticContent'

$appcmd = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'inetsrv', 'appcmd.exe')
$output = & $appcmd @appcmdArgs
if ($LASTEXITCODE -ne 0) {
    throw "appcmd.exe $($appcmdArgs -join ' ') failed with exit code ${LASTEXITCODE}: $output"
}
$served = New-Object -TypeName System.Xml.XmlDocument
$served.LoadXml(($output -join "`n"))
$effective = @(
    foreach ($node in $served.SelectNodes('/system.webServer/staticContent/mimeMap')) {
        if (-not $Extension -or $node.GetAttribute('fileExtension') -eq $Extension) {
            [ordered]@{
                extension = $node.GetAttribute('fileExtension')
                mime_type = $node.GetAttribute('mimeType')
            }
        }
    }
)

$appHost = New-Object -TypeName System.Xml.XmlDocument
$appHost.Load([System.IO.Path]::Combine($env:SystemRoot, 'System32', 'inetsrv', 'config', 'applicationHost.config'))
if ($location) {
    $xpath = "/configuration/location[@path='$location']/system.webServer/staticContent/*"
}
else {
    $xpath = '/configuration/system.webServer/staticContent/*'
}
$applicationHost = @(Get-StoredEntry -Node $appHost.SelectNodes($xpath) -Extension $Extension)

$webConfig = @()
if ($PhysicalPath) {
    $webConfigPath = [System.IO.Path]::Combine($PhysicalPath, 'web.config')
    if (Test-Path -LiteralPath $webConfigPath -PathType Leaf) {
        $document = New-Object -TypeName System.Xml.XmlDocument
        $document.Load($webConfigPath)
        $webConfig = @(Get-StoredEntry -Node $document.SelectNodes('/configuration/system.webServer/staticContent/*') -Extension $Extension)
    }
}

$Ansible.Result = @{
    effective = $effective
    application_host = $applicationHost
    web_config = $webConfig
}
