#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._GpoCommon

# gpo_export: back up the named GPOs' settings content to a directory, one
# self-contained Backup-GPO folder per GPO (issue #64). Nothing else: no
# links, WMI filters, security filtering, status or manifest (that's the sync
# layer, gpo_sync_export), no zip and no state file.
#
# Layout under path:
#   <SafeName>\{backup-id}\...     Backup-GPO's own output
#   <SafeName>\manifest.xml        Backup-GPO's index of the folder
#   <SafeName>\gpo-export.json     the export record: the GPO's GUID and the
#                                  hash of the live content the backup holds
#
# The export record is the module's only state, kept in the destination
# itself. A GPO is backed up again only when its folder is missing or
# incomplete, has no record, records another GPO, or its live content hash
# (Get-GpoLiveContentHash: the GPO's SYSVOL folder minus gpt.ini, read in both
# modes) differs from the recorded one. Check mode reads AD and SYSVOL and
# returns the plan; its only write is the preflight's probe file.
#
# Windows PowerShell 5.1-compatible. The pure logic lives in
# plugins/module_utils/_GpoCommon.psm1, unit-tested with Pester.

$spec = @{
    options = @{
        domain = @{ type = 'str'; required = $true }
        server = @{ type = 'str' }
        gpo_names = @{ type = 'list'; elements = 'str'; required = $true }
        path = @{ type = 'path'; required = $true }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Domain = $module.Params.domain
$Server = [string]$module.Params.server
$GpoNames = @($module.Params.gpo_names | Where-Object { $_ })
$DestPath = $module.Params.path
$checkMode = $module.CheckMode

$module.Result.exported = @()
$module.Result.gpos = @()
$module.Result.path = $DestPath
$module.Result.server = $null
$module.Result.errors = @()
# Each fact is $true or $false once checked and $null until then (the run
# stops at the first failure): AD, then GPMC, then the path, cheapest and
# most telling first. path_exists needs neither and is read at once.
$module.Result.preflight = [ordered]@{
    ad = $null
    gpmc = $null
    path_exists = [bool](Test-Path -ErrorAction SilentlyContinue -LiteralPath $DestPath -PathType Container)
    path_writable = $null
    path_probed = $null
}

if ($GpoNames.Count -eq 0) {
    $module.FailJson('gpo_names must name at least one GPO')
}

# FailJson exits through an exception, so the try block only computes;
# failures are reported after it (per-GPO backup failures) or in catch.
$backupErrors = New-Object System.Collections.ArrayList
$failure = $null
try {
    try {
        Import-Module GroupPolicy, ActiveDirectory
    }
    catch {
        throw "The GroupPolicy and ActiveDirectory PowerShell modules are required (install RSAT): $_"
    }

    $module.Result.preflight.ad = $false
    $adDomain = Get-ADDomain -Identity $Domain
    $pdc = $Server
    if (-not $pdc) { $pdc = $adDomain.PDCEmulator }
    $module.Result.server = $pdc
    $module.Result.preflight.ad = $true

    # GPMC before the path, so a path failure still reports whether GPMC
    # answers. One Get-GPO -All rather than Get-GPO -Name per GPO: a missing
    # name is then simply absent, and anything else (access denied, DC
    # unreachable) still throws.
    $module.Result.preflight.gpmc = $false
    $all = @(Get-GPO -All -Domain $Domain -Server $pdc)
    $module.Result.preflight.gpmc = $true

    # --- preflight: can path be written? ------------------------------------
    # The real run proves it by writing the folders; check mode with a
    # uniquely named probe file in path or its nearest existing parent,
    # removed at once.
    $probeDir = Get-NearestExistingDirectory -Path $DestPath
    if (-not $probeDir) {
        throw "preflight failed: path $DestPath can't be created: none of its parents exist."
    }
    if ($checkMode) {
        $module.Result.preflight.path_probed = $probeDir
        $module.Result.preflight.path_writable = $false
        $probeFile = [System.IO.Path]::Combine($probeDir, ('.gpo_export-probe-{0}.tmp' -f [guid]::NewGuid().ToString('N')))
        try {
            [System.IO.File]::WriteAllText($probeFile, 'gpo_export check-mode writability probe')
            $module.Result.preflight.path_writable = $true
        }
        catch {
            throw "preflight failed: path $DestPath isn't writable (probed $probeDir): $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
        }
    }

    # --- resolve the names --------------------------------------------------
    # Names compare case-insensitively, as GPMC's do.
    $selected = [ordered]@{}
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $GpoNames) {
        $gpo = $all | Where-Object { $_.DisplayName -ieq $name } | Select-Object -First 1
        if ($null -eq $gpo) { [void]$missing.Add($name); continue }
        $selected[$gpo.DisplayName] = $gpo
    }
    if ($missing.Count -gt 0) {
        throw ("GPO(s) not found in {0}: {1}" -f $Domain, (($missing | ForEach-Object { "'$_'" }) -join ', '))
    }
    $folders = Get-GpoFolderName -Names @($selected.Keys)

    # --- decide, from the live content and the destination's records -------
    $policies = "\\$pdc\SYSVOL\$Domain\Policies"
    $plan = New-Object System.Collections.ArrayList
    foreach ($name in $folders.Keys) {
        $gpo = $selected[$name]
        $folder = [System.IO.Path]::Combine($DestPath, $folders[$name])
        try {
            $hash = Get-GpoLiveContentHash -Path (Join-Path $policies ('{{{0}}}' -f $gpo.Id))
        }
        catch {
            [void]$backupErrors.Add("GPO '$name': $($_.Exception.Message)")
            continue
        }
        $exists = [bool](Test-Path -ErrorAction SilentlyContinue -LiteralPath $folder -PathType Container)
        $problem = ''
        $record = $null
        if ($exists) {
            $problem = Test-GpoBackupFolder -Path $folder
            $record = Read-GpoExportRecord -Path $folder
        }
        $reason = Get-GpoExportReason -FolderExists $exists -Problem $problem -Record $record `
            -Id ([string]$gpo.Id) -ContentHash $hash
        [void]$plan.Add([ordered]@{
                name = $name
                id = ConvertTo-GpoId -Value ([string]$gpo.Id)
                folder = $folders[$name]
                content_hash = $hash
                reason = $reason
            })
    }
    if ($backupErrors.Count -gt 0) {
        throw ("cannot hash {0} GPO(s), nothing was exported: {1}" -f $backupErrors.Count, ($backupErrors -join '; '))
    }

    # --- real run: back up what changed, record it --------------------------
    # The record is written last, so a backup interrupted halfway leaves a
    # folder without one, which the next run exports again.
    $exported = New-Object System.Collections.ArrayList
    foreach ($entry in $plan) {
        if (-not $entry.reason) { continue }
        if (-not $checkMode) {
            $folder = [System.IO.Path]::Combine($DestPath, $entry.folder)
            try {
                if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
                Backup-GPO -Guid $entry.id -Domain $Domain -Server $pdc -Path $folder `
                    -Comment 'git_cgallagher.windows.gpo_export' | Out-Null
                $problem = Test-GpoBackupFolder -Path $folder
                if ($problem) { throw "Backup-GPO left an incomplete folder ($problem)" }
                Write-Utf8File -Path ([System.IO.Path]::Combine($folder, 'gpo-export.json')) `
                    -Content (ConvertTo-GpoExportRecordJson -Name $entry.name -Id $entry.id -Domain $Domain -ContentHash $entry.content_hash)
            }
            catch {
                [void]$backupErrors.Add("GPO '$($entry.name)': $($_.Exception.Message)")
                continue
            }
        }
        [void]$exported.Add([ordered]@{ name = $entry.name; folder = $entry.folder; reason = $entry.reason })
    }
    # A real run proves path writable by writing a GPO's folder into it; with
    # nothing to export it doesn't write, and path_writable stays $null.
    if (-not $checkMode) {
        $module.Result.preflight.path_exists = [bool](Test-Path -ErrorAction SilentlyContinue -LiteralPath $DestPath -PathType Container)
        if ($exported.Count -gt 0) {
            $module.Result.preflight.path_probed = $DestPath
            $module.Result.preflight.path_writable = $true
        }
    }

    $module.Result.exported = @($exported)
    $module.Result.gpos = @($plan | ForEach-Object {
            [ordered]@{ name = $_.name; id = $_.id; folder = $_.folder; content_hash = $_.content_hash; exported = [bool]$_.reason }
        })
    $module.Result.changed = $exported.Count -gt 0
}
catch {
    $failure = $_
}

if ($failure) {
    $module.Result.errors = @($backupErrors)
    $module.FailJson("gpo_export failed for $($Domain): $($failure.Exception.Message)", $failure)
}
if ($backupErrors.Count -gt 0) {
    $module.Result.errors = @($backupErrors)
    $module.FailJson(("gpo_export failed for {0} GPO(s) in {1}; see errors: {2}" -f
            $backupErrors.Count, $Domain, ($backupErrors -join '; ')))
}

$module.ExitJson()
