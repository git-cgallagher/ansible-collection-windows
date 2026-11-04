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

# --- validate ------------------------------------------------------------------
$problem = Get-IisFileExtensionProblem -Extension $extension
if ($problem) {
    $module.FailJson("extension $problem; got '$extension'.")
}
$extension = ConvertTo-IisFileExtension -Extension $extension

if ($state -eq 'present' -and -not (Test-IisMimeType -MimeType $mimeType)) {
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
$decision = Get-IisMimeMapDecision -Current $current -State $state -Extension $extension -MimeType $mimeType
$currentMimeType = $null
if ($current) {
    $currentMimeType = $current.MimeType
}
$changed = $decision.Changed

$module.Diff.before = $decision.Before
$module.Diff.after = $decision.After
$module.Result.mime_type = $mimeType

# changed stays false until the change has gone through (or would have, in
# check mode), so a refusal or a failed write doesn't report a change.
if (-not $changed) {
    $module.ExitJson()
}

# --- change it: in memory first, so check mode follows the same path, then one commit ---
$target = Get-IisCommitTarget -Level $level -WebConfig:$useWebConfig
$file = $target.File

if (-not $useWebConfig -and $level.Site) {
    try {
        $override = Get-IisWebConfigOverride -PhysicalPath $level.PhysicalPath -Extension $extension
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
    $writer = New-IisAdminManager -CommitPath $target.CommitPath
    $collection = Get-IisSectionCollection -AdminManager $writer -Section $section -ConfigPath $level.ConfigPath
    $changeArgs = @{
        Writer = $writer
        Collection = $collection
        Extension = $extension
        Mapping = $decision.After
        CurrentMimeType = $currentMimeType
        ConfigPath = $level.ConfigPath
        File = $file
        CheckMode = $module.CheckMode
    }
    $refusal = Invoke-IisMimeMapChange @changeArgs
    if (-not $refusal -and -not $module.CheckMode) {
        $module.Result.changed = $true
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
