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
    $parent = @{}
    if ($level.ParentPath) {
        foreach ($entry in (Get-IisMimeMapEntry -Collection (Get-IisSectionCollection -AdminManager $reader -Section $section -ConfigPath $level.ParentPath))) {
            $parent[$entry.Extension] = $entry.MimeType
        }
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

# Sorted by extension, ordinally and ignoring case, so the order doesn't
# depend on the host's culture.
$sorted = [System.Collections.Generic.List[object]]$entries
$sorted.Sort([System.Comparison[object]] {
        param ($x, $y)
        [string]::CompareOrdinal($x.Extension.ToLowerInvariant(), $y.Extension.ToLowerInvariant())
    })

# An entry is inherited when the parent level serves the same mapping and the
# level doesn't store its own (in a <location> element of applicationHost.config
# or in the level's web.config). At the server level nothing is inherited.
$mimeTypes = New-Object -TypeName 'System.Collections.Generic.List[object]'
foreach ($entry in $sorted) {
    if ($null -ne $extension -and $entry.Extension -ne $extension) {
        continue
    }
    if ($null -ne $mimeType -and $entry.MimeType -ne $mimeType) {
        continue
    }

    $sameAsParent = $parent.ContainsKey($entry.Extension) -and $parent[$entry.Extension] -ceq $entry.MimeType
    $definedHere = $null -ne $stored -and $stored.Contains($entry.Extension)
    $mimeTypes.Add([ordered]@{
            extension = $entry.Extension
            mime_type = $entry.MimeType
            config_path = $level.ConfigPath
            inherited = [bool]($sameAsParent -and -not $definedHere)
        })
}

$module.Result.mime_types = $mimeTypes
$module.ExitJson()
