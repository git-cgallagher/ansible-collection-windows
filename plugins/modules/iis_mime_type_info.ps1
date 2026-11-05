#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._IisConfig

# The argument spec and Create come first: ansible-test's validate-modules runs
# this file under pwsh on Linux up to Create to read the spec.
$spec = @{
    options = @{
        extension = @{ type = 'str' }
        mime_type = @{ type = 'str' }
        site = @{ type = 'str' }
        application = @{ type = 'str' }
    }
    required_by = @{ application = 'site' }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$section = 'system.webServer/staticContent'
$extension = $module.Params.extension
$mimeType = $module.Params.mime_type

if ($null -ne $extension) {
    if ($extension -eq '' -or $extension -eq '.') {
        $module.FailJson('extension must not be empty; omit it to list every mapping.')
    }
    $extension = ConvertTo-IisFileExtension -Extension $extension
}

try {
    $reader = New-IisAdminManager
    $level = Resolve-IisConfigLevel -AdminManager $reader -Site $module.Params.site -Application $module.Params.application
    $entries = @(Get-IisMimeMapEntry -Collection (Get-IisSectionCollection -AdminManager $reader -Section $section -ConfigPath $level.ConfigPath))

    # What the parent level serves, to tell inherited entries from local ones.
    $parentEntries = @()
    if ($level.ParentPath) {
        $parentEntries = @(Get-IisMimeMapEntry -Collection (Get-IisSectionCollection -AdminManager $reader -Section $section -ConfigPath $level.ParentPath))
    }
}
catch {
    $module.FailJson($_.Exception.Message, $_)
}

# An entry that repeats the parent level's mapping is local only when the
# level's own configuration stores it: IIS doesn't report where an entry is
# defined.
$stored = $null
if ($level.ParentPath) {
    try {
        $stored = Get-IisStoredMimeMapExtension -ConfigPath $level.ConfigPath -PhysicalPath $level.PhysicalPath
    }
    catch {
        $msg = "Couldn't read the configuration stored for $($level.ConfigPath), so entries that repeat the parent level's mapping "
        $msg += "are reported as inherited: $($_.Exception.Message)"
        $module.Warn($msg)
    }
}

# Sorted by extension, filtered, and each entry marked inherited (the parent
# level serves the same mapping and the level doesn't store its own) or not.
$listArgs = @{
    Entries = $entries
    ParentEntries = $parentEntries
    Stored = $stored
    ConfigPath = $level.ConfigPath
    Extension = $extension
    MimeType = $mimeType
}
$module.Result.mime_types = Get-IisMimeTypeList @listArgs
$module.ExitJson()
