#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._GpoCommon

# gpo_import: import the named GPOs' settings from Backup-GPO folders in a
# local directory into a domain (issue #64). Nothing else: no links, WMI
# filters, security filtering, status or inheritance (that's the sync layer,
# gpo_sync_import), and never a deletion or an unlink.
#
# Each name resolves to the one backup under path whose bkupInfo.xml records
# that display name (Get-GpoBackupIndex: path\{backup-id} or
# path\<folder>\{backup-id}), never by folder name. Import-GPO runs when the
# target GPO is missing, when the backup's content or the migration table
# differs from what this module last imported into it, when the GPO was
# edited since (its version numbers moved), or with force. What it imported
# is recorded per target domain in a JSON file on the host it runs on
# (Read-GpoImportRecord), keyed by the target GPO's GUID, with the GPO's
# versions right after the import: Import-GPO re-serialises the security
# template, so the live GPO can't be compared with the backup directly.
#
# A preflight proves the run could work before anything is planned: the
# backups resolve and are complete, no cpassword, the migration table parses,
# the record's directory takes a file (a probe file, removed at once), the
# domain and GPMC answer. A missing or unreadable record only means "import". Check mode plans and writes nothing else.
#
# Windows PowerShell 5.1-compatible. The pure logic lives in
# plugins/module_utils/_GpoCommon.psm1, unit-tested with Pester.

$spec = @{
    options = @{
        domain = @{ type = 'str'; required = $true }
        server = @{ type = 'str' }
        path = @{ type = 'path'; required = $true }
        gpo_names = @{ type = 'list'; elements = 'str'; required = $true }
        migration_table_path = @{ type = 'path' }
        force = @{ type = 'bool'; default = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Domain = $module.Params.domain
$Server = [string]$module.Params.server
$SourcePath = $module.Params.path
$GpoNames = @($module.Params.gpo_names | Where-Object { $_ })
$MigrationTablePath = $module.Params.migration_table_path
$ForceImport = [bool]$module.Params.force
$checkMode = $module.CheckMode

# The record's place: fixed, next to the sync layer's state (a file of its own).
$recordDir = 'C:\ProgramData\gpo-iac'
$recordFile = [System.IO.Path]::Combine($recordDir, ('gpo-import-{0}.json' -f $Domain.ToLowerInvariant()))

$module.Result.imported = @()
$module.Result.gpos = @()
$module.Result.path = $SourcePath
$module.Result.server = $null
$module.Result.record_file = $recordFile
$module.Result.errors = @()

if ($GpoNames.Count -eq 0) {
    $module.FailJson('gpo_names must name at least one GPO')
}

# --- preflight: prove the run could work, before planning anything ------------
# Every check runs, whatever failed before it, except the cpassword refusal,
# which stops at once. A fact is $true or $false once checked and $null when
# it couldn't be (resolved and cpassword_clean without a path, the domain's
# after a refusal).
$preflight = [ordered]@{
    path_exists = [bool](Test-Path -ErrorAction SilentlyContinue -LiteralPath $SourcePath -PathType Container)
    backups = 0
    resolved = $null
    migration_table = $null
    migration_table_valid = $null
    cpassword_clean = $null
    record_valid = $false
    record_dir_writable = $null
    record_dir_probed = $null
    domain_reachable = $null
    gpmc_reachable = $null
    passed = $false
    errors = @()
}
$preflightErrors = New-Object System.Collections.ArrayList

# -- the backups: each name resolves to exactly one complete backup --
$resolution = @{ resolved = [ordered]@{}; missing = @(); ambiguous = @() }
if (-not $preflight.path_exists) {
    [void]$preflightErrors.Add("path not found: $SourcePath")
}
else {
    $index = Get-GpoBackupIndex -Path $SourcePath
    $preflight.backups = @($index.backups).Count
    $resolution = Resolve-GpoBackupName -Backups @($index.backups) -Names $GpoNames
    if ($resolution.missing.Count -gt 0) {
        $msg = "no backup under $SourcePath records GPO(s) " + (($resolution.missing | ForEach-Object { "'$_'" }) -join ', ')
        if ($index.unreadable.Count -gt 0) { $msg += " (unreadable bkupInfo.xml in: $($index.unreadable -join ', '))" }
        [void]$preflightErrors.Add($msg)
    }
    foreach ($a in $resolution.ambiguous) {
        [void]$preflightErrors.Add("more than one backup records GPO $a; keep one")
    }
    foreach ($name in $resolution.resolved.Keys) {
        $problem = Test-GpoBackupInstance -Path $resolution.resolved[$name].dir
        if ($problem) { [void]$preflightErrors.Add("GPO '$name': backup $($resolution.resolved[$name].dir) is incomplete ($problem)") }
    }
    $preflight.resolved = ($resolution.missing.Count -eq 0 -and $resolution.ambiguous.Count -eq 0)
}

# -- cpassword: deprecated, trivially decryptable, and a secret. Checked in the
#    backups this run would import only, before touching the domain. --
if ($preflight.path_exists) { $preflight.cpassword_clean = $true }
# @(): one file would otherwise unroll to a string, not a list.
$cpasswordFiles = @(Get-GpoCpasswordFile -Path @($resolution.resolved.Values | ForEach-Object { $_.dir }))
if ($cpasswordFiles.Count -gt 0) {
    $preflight.cpassword_clean = $false
    $module.Result.cpassword_files = @($cpasswordFiles)
    $module.Result.preflight = $preflight
    $module.FailJson(("Refusing to import: GPP cpassword found in: {0}. " -f ($cpasswordFiles -join '; ')) +
        'Remove the preference (use LAPS/gMSA instead) and back the GPO up again.')
}

# -- migration table --
$migTable = ''
$migTableHash = ''
if ($MigrationTablePath) {
    $migTable = Resolve-GpoMigrationTablePath -Path $MigrationTablePath -SourceDir $SourcePath
    $preflight.migration_table = $migTable
    $preflight.migration_table_valid = $false
    if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $migTable -PathType Leaf)) {
        [void]$preflightErrors.Add("migration table not found: $migTable")
    }
    else {
        try {
            $migXml = New-Object System.Xml.XmlDocument
            $migXml.Load($migTable)
            if ($migXml.DocumentElement.LocalName -ne 'MigrationTable') {
                [void]$preflightErrors.Add("migration table $migTable is XML but its root is <$($migXml.DocumentElement.LocalName)>, not <MigrationTable>")
            }
            else {
                $preflight.migration_table_valid = $true
                $migTableHash = (Get-FileHash -LiteralPath $migTable -Algorithm SHA256).Hash
            }
        }
        catch {
            [void]$preflightErrors.Add("migration table $migTable does not parse as XML: $($_.Exception.Message)")
        }
    }
}

# -- the record: its directory must take a file (the probe is removed). A
#    record that doesn't parse never fails the run or skips an import: it
#    reads as empty, so every named GPO is imported, and the first import
#    writes a valid record over it. --
$record = @{}
try {
    $record = Read-GpoImportRecord -Path $recordFile
    $preflight.record_valid = $true
}
catch {
    $module.Warn("import record $recordFile does not parse, so every named GPO is imported and the record rewritten: $($_.Exception.Message)")
}
$probeDir = Get-NearestExistingDirectory -Path $recordDir
$preflight.record_dir_probed = $probeDir
if (-not $probeDir) {
    [void]$preflightErrors.Add("record directory $recordDir has no existing parent to create it under")
}
else {
    $preflight.record_dir_writable = $false
    $probeFile = [System.IO.Path]::Combine($probeDir, ('.gpo_import-probe-{0}.tmp' -f [guid]::NewGuid().ToString('N')))
    try {
        [System.IO.File]::WriteAllText($probeFile, 'gpo_import preflight')
        $preflight.record_dir_writable = $true
    }
    catch {
        [void]$preflightErrors.Add("record directory $recordDir is not writable (probed $probeDir): $($_.Exception.Message)")
    }
    finally {
        if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
    }
}

# -- domain and GPMC --
try {
    Import-Module GroupPolicy, ActiveDirectory
}
catch {
    $module.Result.preflight = $preflight
    $module.FailJson("The GroupPolicy and ActiveDirectory PowerShell modules are required (install RSAT): $($_.Exception.Message)", $_)
}
$pdc = $Server
$live = @()
# $null until checked (a cpassword refusal stops before), $false when it failed.
$preflight.domain_reachable = $false
try {
    $adDomain = Get-ADDomain -Identity $Domain
    $preflight.domain_reachable = $true
    if (-not $pdc) { $pdc = $adDomain.PDCEmulator }
    $module.Result.server = $pdc
    $preflight.gpmc_reachable = $false
    try {
        $live = @(Get-GPO -All -Domain $Domain -Server $pdc)
        $preflight.gpmc_reachable = $true
    }
    catch {
        [void]$preflightErrors.Add("GPMC cannot read the GPOs of $Domain on $($pdc): $($_.Exception.Message)")
    }
}
catch {
    [void]$preflightErrors.Add("cannot read domain $($Domain): $($_.Exception.Message)")
}

$preflight.passed = ($preflightErrors.Count -eq 0)
$preflight.errors = @($preflightErrors)
$module.Result.preflight = $preflight
if ($preflightErrors.Count -gt 0) {
    $module.FailJson("gpo_import preflight failed, nothing was planned or changed: " + ($preflightErrors -join '; '))
}

# --- plan and import ------------------------------------------------------------
$errors = New-Object System.Collections.ArrayList
$imported = New-Object System.Collections.ArrayList
$gpos = New-Object System.Collections.ArrayList
$recordChanged = $false
foreach ($name in $resolution.resolved.Keys) {
    $backup = $resolution.resolved[$name]
    $target = $live | Where-Object { $_.DisplayName -ieq $backup.name } | Select-Object -First 1
    $targetId = $null
    $liveVersion = ''
    if ($target) {
        $targetId = ConvertTo-GpoId -Value ([string]$target.Id)
        $liveVersion = Get-GpoVersionStamp -Gpo $target
    }
    $importKey = Get-GpoImportKey -BackupDir $backup.dir -MigrationTableHash $migTableHash
    $reason = Get-GpoImportDecision -Force $ForceImport -TargetId $targetId -LiveVersion $liveVersion `
        -Record $record -ImportKey $importKey

    if ($reason) {
        try {
            if (-not $checkMode) {
                # An existing GPO is imported into by GUID, so it keeps its GUID
                # and whatever the name lookup matched; a missing one is created.
                $importArgs = @{
                    BackupId = $backup.backup_id
                    Path = $backup.parent
                    Domain = $Domain
                    Server = $pdc
                }
                if ($target) { $importArgs.TargetGuid = $target.Id }
                else {
                    $importArgs.TargetName = $backup.name
                    $importArgs.CreateIfNeeded = $true
                }
                if ($migTable) { $importArgs.MigrationTable = $migTable }
                $result = Import-GPO @importArgs
                # Recorded only after Import-GPO succeeded, so a failed import is
                # retried on the next run, with the versions the import left: a
                # later edit in GPMC bumps them, and the next run imports again.
                $targetId = ConvertTo-GpoId -Value ([string]$result.Id)
                $after = Get-GPO -Guid $targetId -Domain $Domain -Server $pdc
                $record[$targetId] = @{ name = $backup.name; import_key = $importKey; version = (Get-GpoVersionStamp -Gpo $after) }
                $recordChanged = $true
            }
            [void]$imported.Add([ordered]@{ name = $backup.name; reason = $reason; backup = $backup.dir })
        }
        catch {
            [void]$errors.Add("GPO '$($backup.name)': $($_.Exception.Message)")
        }
    }
    [void]$gpos.Add([ordered]@{
            name = $backup.name
            backup = $backup.dir
            backup_id = $backup.backup_id
            target_id = $targetId
            imported = [bool]$reason
        })
}

# --- record + result ------------------------------------------------------------
# Written only when an import landed: a run with nothing to do leaves it as it was.
if (-not $checkMode) {
    if ($recordChanged) {
        try {
            if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $recordDir)) {
                New-Item -ItemType Directory -Path $recordDir -Force | Out-Null
            }
            Write-Utf8File -Path $recordFile -Content (ConvertTo-GpoImportRecordJson -Record $record)
        }
        catch {
            [void]$errors.Add("import record $($recordFile): $($_.Exception.Message)")
        }
    }
}

$module.Result.imported = @($imported)
$module.Result.gpos = @($gpos)
$module.Result.errors = @($errors)
$module.Result.changed = $imported.Count -gt 0
if ($errors.Count -gt 0) {
    $module.FailJson("gpo_import finished with $($errors.Count) error(s): $($errors -join '; ')")
}
$module.ExitJson()
