#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._IisConfig

# The argument spec and Create come first: ansible-test's validate-modules runs
# this file under pwsh on Linux up to Create to read the spec.
$spec = @{
    options = @{
        extension = @{ type = 'str'; required = $true }
        mime_type = @{ type = 'str' }
        state = @{ type = 'str'; default = 'present'; choices = 'absent', 'present' }
        site = @{ type = 'str' }
        application = @{ type = 'str' }
        config_file = @{ type = 'str'; default = 'applicationHost.config'; choices = 'applicationHost.config', 'web.config' }
    }
    required_if = @(, @('state', 'present', @('mime_type')))
    required_by = @{ application = 'site' }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$section = 'system.webServer/staticContent'
$extension = $module.Params.extension
$mimeType = $module.Params.mime_type
$state = $module.Params.state
$useWebConfig = $module.Params.config_file -eq 'web.config'

Function Get-WebConfigOverride {
    <#
    .SYNOPSIS
    Describes what in a level's own web.config would override a mapping stored in
    applicationHost.config for that level, or returns $null.

    .DESCRIPTION
    IIS reads a level's <location> element in applicationHost.config before the
    level's web.config, so that file's <clear />, or its own element for the
    extension, wins over (or collides with) anything written to the <location>.
    #>
    param (
        [AllowNull()]
        [string]
        $PhysicalPath,

        [Parameter(Mandatory = $true)]
        [string]
        $Extension
    )

    if (-not $PhysicalPath) {
        return $null
    }
    $path = [System.IO.Path]::Combine($PhysicalPath, 'web.config')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    $xml = New-Object -TypeName System.Xml.XmlDocument
    $xml.Load($path)
    $xpath = "/*[local-name()='configuration']/*[local-name()='system.webServer']/*[local-name()='staticContent']/*"
    foreach ($node in $xml.SelectNodes($xpath)) {
        if ($node.LocalName -eq 'clear') {
            return "$path clears the inherited MIME map (<clear />)"
        }
        if ($node.GetAttribute('fileExtension') -eq $Extension) {
            return "$path has its own <$($node.LocalName)> element for $Extension"
        }
    }
    $null
}

# --- validate ------------------------------------------------------------------
$problem = $null
if ([string]::IsNullOrEmpty($extension) -or $extension -eq '.') {
    $problem = 'must not be empty'
}
elseif ($extension -match '\s') {
    $problem = 'must not contain whitespace'
}
elseif ($extension -match '["''/\\]') {
    $problem = 'must not contain quotes or path separators (/ or \)'
}
if ($problem) {
    $module.FailJson("extension $problem; got '$extension'.")
}
$extension = ConvertTo-IisFileExtension -Extension $extension

if ($state -eq 'present' -and $mimeType -notmatch '^[^\s/]+/[^\s/]+$') {
    $module.FailJson("mime_type must look like type/subtype, with exactly one '/' and no whitespace; got '$mimeType'.")
}
if ($state -eq 'absent') {
    $mimeType = $null
}
if ($useWebConfig -and $null -eq $module.Params.site) {
    $module.FailJson('config_file=web.config needs site: server-level mappings always live in applicationHost.config.')
}

# --- read what IIS serves at the level --------------------------------------------
try {
    $reader = New-IisAdminManager
    $level = Resolve-IisConfigLevel -AdminManager $reader -Site $module.Params.site -Application $module.Params.application
    $effective = Get-IisSectionCollection -AdminManager $reader -Section $section -ConfigPath $level.ConfigPath
    $current = Get-IisMimeMapEntry -Collection $effective -Extension $extension | Select-Object -First 1
}
catch {
    $module.FailJson($_.Exception.Message, $_)
}

$module.Result.extension = $extension
$module.Result.config_path = $level.ConfigPath

# The decision is made against the effective map, inherited entries included:
# a matching inherited entry is left alone rather than copied to this level.
$before = $null
$currentMimeType = $null
if ($current) {
    $currentMimeType = $current.MimeType
    $before = @{ extension = $current.Extension; mime_type = $current.MimeType }
}

$after = $null
if ($state -eq 'present') {
    $key = $extension
    if ($current) {
        $key = $current.Extension
    }
    $after = @{ extension = $key; mime_type = $mimeType }
    $changed = $currentMimeType -cne $mimeType
}
else {
    $changed = $null -ne $current
}

$module.Diff.before = $before
$module.Diff.after = $after
$module.Result.mime_type = $mimeType

# changed stays false until the change has gone through (or would have, in
# check mode), so a refusal or a failed write doesn't report a change.
if (-not $changed) {
    $module.ExitJson()
}

# --- change it: in memory first, so check mode follows the same path, then one commit ---
$commitPath = 'MACHINE/WEBROOT/APPHOST'
$file = 'applicationHost.config'
if ($useWebConfig) {
    $commitPath = $level.ConfigPath
    $file = "the web.config of $($level.ConfigPath)"
}

if (-not $useWebConfig -and $level.Site) {
    try {
        $override = Get-WebConfigOverride -PhysicalPath $level.PhysicalPath -Extension $extension
    }
    catch {
        $override = $null
        $module.Warn("Couldn't check the web.config at $($level.PhysicalPath) for entries that would override this mapping: $($_.Exception.Message)")
    }
    if ($override) {
        $msg = "Refusing to change $extension at $($level.ConfigPath) in applicationHost.config: $override, and IIS reads that file after "
        $msg += "applicationHost.config, so it would override the change or collide with it. Use config_file=web.config to change the mapping there."
        $module.FailJson($msg)
    }
}

# FailJson exits through an exception, so the try block below only records a
# refusal; it's reported after the block.
$refusal = $null
try {
    $writer = New-IisAdminManager -CommitPath $commitPath
    $collection = Get-IisSectionCollection -AdminManager $writer -Section $section -ConfigPath $level.ConfigPath
    $stored = Get-IisMimeMapEntry -Collection $collection -Extension $extension | Select-Object -First 1

    # The file being written must see the mapping IIS serves, or a change made
    # there can't take effect (for example an entry from a web.config that a
    # <location> element in applicationHost.config can't override).
    $storedMimeType = $null
    if ($stored) {
        $storedMimeType = $stored.MimeType
    }
    if ($storedMimeType -cne $currentMimeType) {
        $refusal = "Can't change $extension at $($level.ConfigPath) through ${file}: IIS serves '$currentMimeType', "
        $refusal += "but that file sees '$storedMimeType'."
    }
    else {
        # Delete what this file sees for the extension. Deleting an entry
        # inherited from a parent level writes a <remove> element at this level.
        # If an inherited entry shows through after deleting a local one, delete
        # that too.
        for ($attempt = 0; $attempt -lt 2 -and $stored; $attempt++) {
            $null = Invoke-IisComMember -Object $collection -Name 'DeleteElement' -ArgumentList $stored.Index
            $stored = Get-IisMimeMapEntry -Collection $collection -Extension $extension | Select-Object -First 1
        }

        if ($stored) {
            $refusal = "Couldn't delete $extension from $file at $($level.ConfigPath): it is still there after two deletions."
        }
        else {
            if ($state -eq 'present') {
                $element = Invoke-IisComMember -Object $collection -Name 'CreateNewElement' -ArgumentList 'mimeMap'
                Set-IisElementValue -Element $element -Name 'fileExtension' -Value $after.extension
                Set-IisElementValue -Element $element -Name 'mimeType' -Value $mimeType
                $null = Invoke-IisComMember -Object $collection -Name 'AddElement' -ArgumentList @($element, -1)
            }

            if (-not $module.CheckMode) {
                $null = Invoke-IisComMember -Object $writer -Name 'CommitChanges'
                $module.Result.changed = $true
            }
        }
    }
}
catch {
    $msg = $_.Exception.Message
    if ($msg -like '*locked*') {
        $hint = 'Unlock it for this path (overrideMode="Allow"), or keep the mapping in applicationHost.config, the default.'
        $module.FailJson("system.webServer/staticContent is locked at a parent level, so $file can't hold it: $msg $hint", $_)
    }
    $module.FailJson("Couldn't change $extension in $file at $($level.ConfigPath): $msg", $_)
}

if ($refusal) {
    $module.FailJson($refusal)
}
if ($module.CheckMode) {
    $module.Result.changed = $true
    $module.ExitJson()
}

# --- read back what IIS now serves --------------------------------------------------
try {
    $verifier = New-IisAdminManager
    $served = Get-IisSectionCollection -AdminManager $verifier -Section $section -ConfigPath $level.ConfigPath
    $now = Get-IisMimeMapEntry -Collection $served -Extension $extension | Select-Object -First 1
}
catch {
    $module.FailJson("Committed the change to $file, but couldn't read $($level.ConfigPath) back: $($_.Exception.Message)", $_)
}

$nowMimeType = $null
if ($now) {
    $nowMimeType = $now.MimeType
}
if ($nowMimeType -cne $mimeType) {
    $msg = "Committed the change to $file, but IIS now serves '$nowMimeType' for $extension at $($level.ConfigPath) instead of '$mimeType': "
    $msg += 'something else at this level overrides it.'
    $module.FailJson($msg)
}

$module.ExitJson()
