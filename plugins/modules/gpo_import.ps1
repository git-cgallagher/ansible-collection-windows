#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._GpoCommon

# gpo_import — converge a domain on a git_cgallagher.windows export.
#
# Runs on a Windows management host with RSAT (GroupPolicy + ActiveDirectory
# modules) in the TARGET domain; roles/gpo_import stages the export and calls
# it.
#
# Order of operations:
#   0. refuse any backup containing GPP cpassword (before touching the domain)
#   1. WMI filters (create missing ones only with create_wmi_filters)
#   2. GPO contents: Import-GPO -CreateIfNeeded [-MigrationTable] when the GPO
#      is missing, its backup content-hash changed since the last import
#      (state file, per domain), or force
#   3. GPO properties: status, WMI filter link, security filtering (removed
#      Apply trustees are downgraded to Read, never stripped — MS16-072)
#   4. links: each manifest SOM's whole ordered list (order = precedence),
#      block-inheritance; unmanaged links reported, removed only with
#      remove_unmanaged_links
#
# Before planning, a preflight proves the run could work and reports what it
# found in `preflight`: the manifest parses and matches the staged backup
# folders, the migration table parses, no cpassword, state_dir is writable
# (a probe file is created and removed), the domain, GPMC, links and WMI
# filters can be read. Any preflight failure fails the module, in check mode
# too, before anything is planned or touched.
#
# Check mode plans every action (returned in `actions` and the diff) without
# touching the domain or the state file; `changed` is true whenever there is
# something to do, in both modes.
#
# Windows PowerShell 5.1-compatible. The pure logic (hashing, the manifest's
# encodings, the import decision, the link plan) lives in
# plugins/module_utils/_GpoCommon.psm1, shared with gpo_export (hashing decides
# what re-imports, and the manifest is the two modules' contract) and
# unit-tested with Pester (tests/unit/plugins/).

# The argument spec and Create come first: ansible-test's validate-modules runs
# this file under pwsh on Linux up to Create to read the spec.
$spec = @{
    options = @{
        domain = @{ type = 'str'; required = $true }
        server = @{ type = 'str' }
        source_dir = @{ type = 'path'; required = $true }
        manifest_path = @{ type = 'path'; default = 'gpo-manifest.json' }
        migration_table_path = @{ type = 'path' }
        state_dir = @{ type = 'path'; default = 'C:\ProgramData\gpo-iac' }
        remove_unmanaged_links = @{ type = 'bool'; default = $false }
        create_wmi_filters = @{ type = 'bool'; default = $false }
        force = @{ type = 'bool'; default = $false }
        gpo_names = @{ type = 'list'; elements = 'str'; default = @() }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$Domain = $module.Params.domain
$Server = $module.Params.server
$SourceDir = $module.Params.source_dir
$ManifestPath = $module.Params.manifest_path
$MigrationTablePath = $module.Params.migration_table_path
$StateDir = $module.Params.state_dir
$RemoveUnmanagedLinks = $module.Params.remove_unmanaged_links
$CreateWmiFilters = $module.Params.create_wmi_filters
$ForceImport = $module.Params.force
$GpoNames = @($module.Params.gpo_names)
$checkMode = $module.CheckMode

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'


function Get-GpoOrNull {
    # Get-GPO raises GpoWithNameNotFound for a missing display name. Anything
    # else (access denied, DC unreachable) must still fail loudly instead of
    # being mistaken for "missing" and triggering Import-GPO -CreateIfNeeded.
    param([string]$Name)
    try {
        Get-GPO -Name $Name -Domain $Domain -Server $pdc -ErrorAction Stop
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'GpoWithNameNotFound*' -or $_.CategoryInfo.Category -eq 'ObjectNotFound') {
            return $null
        }
        throw
    }
}

function Get-GpmcWmiFilter {
    param([string]$Name)
    $gpDomain = New-Object -TypeName Microsoft.GroupPolicy.GPDomain -ArgumentList $Domain, $pdc
    $criteria = New-Object -TypeName Microsoft.GroupPolicy.GPSearchCriteria
    $gpDomain.SearchWmiFilters($criteria) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
}

function Sync-GpoSecurity {
    # Security filtering = the allow-Apply trustees. Deny entries are never
    # touched: Set-GPPermission can't create them, and mistaking one for an
    # Apply grant would hand the policy to the group it excludes. A Deny
    # entry the manifest lists but the target lacks is an error (fail closed).
    param([string]$Name, $Entry, $Gpo)
    $perms = @(Get-GPPermission -Guid $Gpo.Id -All -Domain $Domain -Server $pdc)

    $liveDenied = @{}
    foreach ($perm in $perms) {
        if (Test-Denied $perm) {
            $denyName = Get-RelativeTrusteeName -Name ([string]$perm.Trustee.Name) -NetBiosName $netbios
            $liveDenied[('{0}|{1}' -f $denyName, [string]$perm.Permission).ToLowerInvariant()] = $true
        }
    }
    if ($Entry.PSObject.Properties['denied']) {
        foreach ($deny in @($Entry.denied)) {
            if (-not $deny) { continue }
            if (-not $liveDenied.ContainsKey(('{0}|{1}' -f [string]$deny.name, [string]$deny.permission).ToLowerInvariant())) {
                [void]$script:errors.Add(("GPO '{0}': the manifest has a Deny {1} entry for '{2}', which this collection can't create. " +
                        'Add it in GPMC (Delegation > Advanced) and re-run.') -f $Name, $deny.permission, $deny.name)
            }
        }
    }

    if (-not ($Entry.PSObject.Properties['apply_to'] -and $null -ne $Entry.apply_to)) { return }
    $desiredApply = @{}
    foreach ($t in @($Entry.apply_to)) { $desiredApply[([string]$t.name).ToLowerInvariant()] = $t }
    $currentApply = @{}
    foreach ($perm in $perms) {
        if ([string]$perm.Permission -ne 'GpoApply' -or (Test-Denied $perm)) { continue }
        $relName = Get-RelativeTrusteeName -Name ([string]$perm.Trustee.Name) -NetBiosName $netbios
        $sidType = [string]$perm.Trustee.SidType
        $relType = 'Group'
        if ($sidType -eq 'User') { $relType = 'User' }
        elseif ($sidType -eq 'Computer') { $relType = 'Computer' }
        $currentApply[$relName.ToLowerInvariant()] = @{ name = $relName; type = $relType }
    }
    foreach ($key in ($desiredApply.Keys | Sort-Object)) {
        if ($currentApply.ContainsKey($key)) { continue }
        $t = $desiredApply[$key]
        Invoke-Change -Description "GPO '$Name': grant Apply to $($t.type) '$($t.name)'" -Action {
            Set-GPPermission -Guid $Gpo.Id -Domain $Domain -Server $pdc `
                -TargetName ([string]$t.name) -TargetType ([string]$t.type) `
                -PermissionLevel GpoApply | Out-Null
        }
    }
    foreach ($key in ($currentApply.Keys | Sort-Object)) {
        if ($desiredApply.ContainsKey($key)) { continue }
        $t = $currentApply[$key]
        # Downgrade to Read, never remove outright: a principal that cannot
        # read a GPO cannot process it at all (MS16-072).
        Invoke-Change -Description "GPO '$Name': downgrade '$($t.name)' from Apply to Read" -Action {
            Set-GPPermission -Guid $Gpo.Id -Domain $Domain -Server $pdc `
                -TargetName ([string]$t.name) -TargetType ([string]$t.type) `
                -PermissionLevel GpoRead -Replace | Out-Null
        }
    }
}

$actions = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList

function Invoke-Change {
    # Record the action; perform it unless this is a check-mode run.
    param([string]$Description, [scriptblock]$Action)
    [void]$script:actions.Add($Description)
    if (-not $checkMode) { & $Action }
}

function Add-Warning {
    # Shown by Ansible as a warning, and returned as data in `notices`
    # (`warnings` is a reserved result key that Ansible consumes).
    param([string]$Message)
    [void]$script:warnings.Add($Message)
    $module.Warn($Message)
}

# --- preflight: prove the run could work, before planning anything -------------
# Every check records a fact in $preflight; a failing one adds to
# $preflightErrors. Nothing here changes the domain; the only write is the
# state_dir probe file, created and removed again.
$preflight = [ordered]@{}
$preflightErrors = New-Object System.Collections.ArrayList

function Add-PreflightError {
    param([string]$Message)
    [void]$script:preflightErrors.Add($Message)
}

# -- manifest --
# [IO.Path]::Combine, not Join-Path, for paths under source_dir and state_dir:
# Windows PowerShell's Join-Path throws "Cannot find drive" for a directory on
# a drive that doesn't exist, before the preflight could report it.
$manifestFile = [System.IO.Path]::Combine($SourceDir, $ManifestPath)
$preflight.manifest = $manifestFile
$preflight.manifest_valid = $false
$manifest = $null
if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $manifestFile)) {
    Add-PreflightError "manifest not found: $manifestFile"
}
else {
    try {
        $manifest = Get-Content -LiteralPath $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $manifest.PSObject.Properties['gpos'] -or $null -eq $manifest.gpos) {
            Add-PreflightError "manifest $manifestFile has no 'gpos' object"
            $manifest = $null
        }
        else {
            $preflight.manifest_valid = $true
        }
    }
    catch {
        Add-PreflightError "manifest $manifestFile does not parse as JSON: $($_.Exception.Message)"
    }
}

# -- backup folders: every one the manifest names and the export carries must be
#    a complete Backup-GPO folder (one {GUID} subfolder with Backup.xml and
#    gpreport.xml). A GPO whose folder is absent is handled per GPO below, as
#    before (properties only, or an error if the GPO is missing too). --
$gposRoot = [System.IO.Path]::Combine($SourceDir, 'gpos')
$preflight.backup_folders = 0
$preflight.backup_folders_incomplete = @()
if ($manifest) {
    $incomplete = New-Object System.Collections.ArrayList
    foreach ($p in $manifest.gpos.PSObject.Properties) {
        $dir = [string]$p.Value.backup_dir
        if (-not $dir) { $dir = ConvertTo-SafeName -Name $p.Name }
        $wrapper = [System.IO.Path]::Combine($gposRoot, $dir)
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $wrapper)) { continue }
        $preflight.backup_folders++
        $problem = Test-GpoBackupFolder -Path $wrapper
        if ($problem) {
            [void]$incomplete.Add("GPO '$($p.Name)': backup folder '$dir' is incomplete ($problem)")
        }
    }
    $preflight.backup_folders_incomplete = @($incomplete)
    foreach ($i in $incomplete) { Add-PreflightError $i }
}

# -- cpassword: GPP cpassword is deprecated, trivially decryptable, and a secret
#    in Git. Only a non-empty value is one: GPP writes cpassword="" on items that
#    set no password (renaming the built-in Administrator, for example). --
$preflight.cpassword_clean = $true
if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $gposRoot) {
    $hits = @(
        Get-ChildItem -LiteralPath $gposRoot -Recurse -Filter '*.xml' -File |
            Select-String -Pattern 'cpassword="[^"]+"' -List
    )
    if ($hits.Count -gt 0) {
        $paths = ($hits | ForEach-Object { $_.Path }) -join '; '
        $preflight.cpassword_clean = $false
        $module.Result.cpassword_files = @($hits | ForEach-Object { $_.Path })
        $module.Result.preflight = $preflight
        $module.FailJson("Refusing to import: GPP cpassword found in: $paths. Remove the preference (use LAPS/gMSA instead) and re-export.")
    }
}

# -- migration table --
$migTable = ''
$preflight.migration_table = $null
$preflight.migration_table_valid = $null
if ($MigrationTablePath) {
    $migTable = Resolve-GpoMigrationTablePath -Path $MigrationTablePath -SourceDir $SourceDir
    $preflight.migration_table = $migTable
    $preflight.migration_table_valid = $false
    if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $migTable)) {
        Add-PreflightError "migration table not found: $migTable"
    }
    else {
        try {
            $migXml = New-Object System.Xml.XmlDocument
            $migXml.Load($migTable)
            if ($migXml.DocumentElement.LocalName -ne 'MigrationTable') {
                Add-PreflightError "migration table $migTable is XML but its root is <$($migXml.DocumentElement.LocalName)>, not <MigrationTable>"
            }
            else {
                $preflight.migration_table_valid = $true
            }
        }
        catch {
            Add-PreflightError "migration table $migTable does not parse as XML: $($_.Exception.Message)"
        }
    }
}
# Part of each GPO's recorded import key: editing the migration table (say,
# to map a principal that was missing) must re-import what it applies to.
$migTableHash = ''
if ($migTable -and $preflight.migration_table_valid) { $migTableHash = (Get-FileHash -LiteralPath $migTable -Algorithm SHA256).Hash }

# -- state_dir: the real run writes the state file there, so prove it can. The
#    nearest existing ancestor stands in for a directory that doesn't exist yet
#    (New-Item creates the rest). The probe file is removed again. --
$probeDir = Get-NearestExistingDirectory -Path $StateDir
$preflight.state_dir = $StateDir
$preflight.state_dir_exists = [bool](Test-Path -ErrorAction SilentlyContinue -LiteralPath $StateDir -PathType Container)
$preflight.state_dir_probe = $probeDir
$preflight.state_dir_writable = $false
if (-not $probeDir) {
    Add-PreflightError "state_dir $StateDir has no existing parent directory to create it under"
}
else {
    $probeFile = Join-Path $probeDir ('.gpo-import-probe-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probeFile, 'gpo_import preflight')
        $preflight.state_dir_writable = $true
    }
    catch {
        Add-PreflightError "state_dir $StateDir is not writable (probed $probeDir): $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
    }
}

# -- domain, GPMC, links, WMI filters: what the plan reads and the run writes --
try {
    Import-Module GroupPolicy, ActiveDirectory
}
catch {
    $module.Result.preflight = $preflight
    $module.FailJson("The GroupPolicy and ActiveDirectory PowerShell modules are required (install RSAT): $($_.Exception.Message)", $_)
}

$preflight.domain_reachable = $false
$adDomain = $null
try {
    $adDomain = Get-ADDomain -Identity $Domain
    $preflight.domain_reachable = $true
}
catch {
    Add-PreflightError "cannot read domain $($Domain): $($_.Exception.Message)"
}
$pdc = $Server
$rootDn = $null
$netbios = $null
$somContainer = $null
$preflight.gpmc_reachable = $false
$preflight.links_readable = $false
$preflight.wmi_filters_readable = $false
if ($adDomain) {
    if (-not $pdc) { $pdc = $adDomain.PDCEmulator }
    $rootDn = $adDomain.DistinguishedName
    $netbios = $adDomain.NetBIOSName
    $somContainer = "CN=SOM,CN=WMIPolicy,CN=System,$rootDn"
    $module.Result.server = $pdc
    $preflight.server = $pdc
    try {
        $preflight.live_gpo_count = @(Get-GPO -All -Domain $Domain -Server $pdc).Count
        $preflight.gpmc_reachable = $true
    }
    catch {
        Add-PreflightError "GPMC cannot read the GPOs of $Domain on $($pdc): $($_.Exception.Message)"
    }
    try {
        Get-GPInheritance -Target $rootDn -Domain $Domain -Server $pdc | Out-Null
        $preflight.links_readable = $true
    }
    catch {
        Add-PreflightError "cannot read the links on $($rootDn): $($_.Exception.Message)"
    }
    try {
        $preflight.live_wmi_filter_count = @(
            Get-ADObject -SearchBase $somContainer -SearchScope OneLevel -Server $pdc `
                -LDAPFilter '(objectClass=msWMI-Som)' -Properties msWMI-Name
        ).Count
        $preflight.wmi_filters_readable = $true
    }
    catch {
        Add-PreflightError "cannot read the WMI filters in $($somContainer): $($_.Exception.Message)"
    }
}

$preflight.passed = ($preflightErrors.Count -eq 0)
$preflight.errors = @($preflightErrors)
$module.Result.preflight = $preflight
if ($preflightErrors.Count -gt 0) {
    $module.FailJson("gpo_import preflight failed, nothing was planned or changed: " + ($preflightErrors -join '; '))
}

# --- state ------------------------------------------------------------------
$stateFile = [System.IO.Path]::Combine($StateDir, ("import-state-{0}.json" -f $Domain.ToLowerInvariant()))
$state = @{}
if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $stateFile) {
    $rawState = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($rawState.PSObject.Properties['gpos']) {
        foreach ($p in $rawState.gpos.PSObject.Properties) {
            $state[$p.Name] = [string]$p.Value.imported_hash
        }
    }
}
# Start from the recorded state so a filtered (gpo_names) run doesn't drop
# the other GPOs' entries and force them all to re-import next time.
$newState = @{}
foreach ($k in $state.Keys) { $newState[$k] = $state[$k] }

# --- 1. WMI filters ------------------------------------------------------------
$liveFilters = @{}
foreach ($f in @(
        Get-ADObject -SearchBase $somContainer -SearchScope OneLevel -Server $pdc `
            -LDAPFilter '(objectClass=msWMI-Som)' -Properties msWMI-Name
    )) {
    $liveFilters[[string]$f.'msWMI-Name'] = $f
}

$manifestFilters = @{}
if ($manifest.PSObject.Properties['wmi_filters'] -and $manifest.wmi_filters) {
    foreach ($p in $manifest.wmi_filters.PSObject.Properties) { $manifestFilters[$p.Name] = $p.Value }
}
foreach ($name in ($manifestFilters.Keys | Sort-Object)) {
    if ($liveFilters.ContainsKey($name)) { continue }
    $def = $manifestFilters[$name]
    if (-not $CreateWmiFilters) {
        Add-Warning "WMI filter '$name' does not exist in $Domain (set create_wmi_filters to create it)"
        continue
    }
    if (-not $def.query) {
        [void]$errors.Add("WMI filter '$name' has no parsed query in the manifest (multi-query filters are unsupported); create it manually")
        continue
    }
    $ns = $def.namespace
    if (-not $ns) { $ns = 'root\CIMv2' }
    try {
        Invoke-Change -Description "create WMI filter '$name'" -Action {
            $id = '{' + [guid]::NewGuid().ToString() + '}'
            $now = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff-000')
            $desc = [string]$def.description
            if (-not $desc) { $desc = ' ' }   # empty msWMI-Parm1 breaks GPMC's filter list
            New-ADObject -Type 'msWMI-Som' -Name $id -Path $somContainer -Server $pdc -OtherAttributes @{
                'msWMI-Name' = $name
                'msWMI-Parm1' = $desc
                'msWMI-Parm2' = (ConvertTo-WmiFilterParm2 -Namespace $ns -Query ([string]$def.query))
                'msWMI-ID' = $id
                'msWMI-Author' = 'git_cgallagher.windows'
                'msWMI-ChangeDate' = $now
                'msWMI-CreationDate' = $now
            } | Out-Null
        }
        if (-not $checkMode) {
            $created = Get-ADObject -SearchBase $somContainer -SearchScope OneLevel -Server $pdc `
                -LDAPFilter "(&(objectClass=msWMI-Som)(msWMI-Name=$(ConvertTo-LdapFilterValue -Value $name)))" -Properties msWMI-Name |
                Select-Object -First 1
            if ($created) { $liveFilters[$name] = $created }
        }
    }
    catch {
        [void]$errors.Add("WMI filter '$name': $($_.Exception.Message)")
    }
}

# --- 2 + 3. GPO contents and properties ----------------------------------------
$manifestGpos = @{}
foreach ($p in $manifest.gpos.PSObject.Properties) { $manifestGpos[$p.Name] = $p.Value }
$gpoOrder = @($manifestGpos.Keys | Sort-Object)
if ($GpoNames.Count -gt 0) {
    $gpoOrder = @($gpoOrder | Where-Object { $GpoNames -contains $_ })
}

$importedCount = 0
foreach ($name in $gpoOrder) {
    try {
        $entry = $manifestGpos[$name]
        $backupDir = [string]$entry.backup_dir
        if (-not $backupDir) { $backupDir = ConvertTo-SafeName -Name $name }
        $wrapper = [System.IO.Path]::Combine($gposRoot, $backupDir)

        $liveGpo = Get-GpoOrNull -Name $name
        $existed = $null -ne $liveGpo

        # Narrow an existing GPO's security filtering before new content lands,
        # so the new settings never apply to the old, wider scope.
        if ($existed) { Sync-GpoSecurity -Name $name -Entry $entry -Gpo $liveGpo }

        # -- contents --
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $wrapper)) {
            if ($liveGpo) {
                Add-Warning "GPO '$name': no backup folder in the export; contents unmanaged, reconciling properties only"
            }
            else {
                [void]$errors.Add("GPO '$name': does not exist in $Domain and the export has no backup folder to create it from")
                continue
            }
        }
        else {
            $backupHash = Get-DirContentHash -Path (Get-GpoSysvolPath -BackupDir $wrapper)
            $importKey = Get-StringHash -Text ($backupHash + '|' + $migTableHash)
            $reason = Get-GpoImportReason -Force $ForceImport -LiveExists ($null -ne $liveGpo) `
                -Recorded $state.ContainsKey($name) -RecordedKey ([string]$state[$name]) -ImportKey $importKey
            if ($reason) {
                $desc = "import GPO '$name' ($reason)"
                if ($migTable) { $desc += ' [migration table]' }
                Invoke-Change -Description $desc -Action {
                    $importArgs = @{
                        BackupGpoName = $name
                        Path = $wrapper
                        TargetName = $name
                        CreateIfNeeded = $true
                        Domain = $Domain
                        Server = $pdc
                    }
                    if ($migTable) { $importArgs.MigrationTable = $migTable }
                    Import-GPO @importArgs | Out-Null
                }
                $importedCount++
                if (-not $checkMode) {
                    # Recorded only after Import-GPO succeeded (a throw skips
                    # this), so a failed import is retried on the next run.
                    $newState[$name] = $importKey
                    $liveGpo = Get-GpoOrNull -Name $name
                }
            }
        }

        if (-not $liveGpo) {
            # Check-mode run against a GPO that doesn't exist yet: the
            # property/link work below needs the live object, so just plan it.
            [void]$actions.Add("set status/filtering/WMI filter on '$name' (after create)")
            continue
        }
        if (-not $existed) { Sync-GpoSecurity -Name $name -Entry $entry -Gpo $liveGpo }

        # -- status --
        $desiredStatus = [string]$entry.status
        if ($desiredStatus -and ($liveGpo.GpoStatus.ToString() -ne $desiredStatus)) {
            Invoke-Change -Description "GPO '$name': status $($liveGpo.GpoStatus) -> $desiredStatus" -Action {
                $liveGpo.GpoStatus = [Microsoft.GroupPolicy.GpoStatus]$desiredStatus
            }
        }

        # -- WMI filter link, through GPMC's API (not a raw gPCWQLFilter write:
        #    Set-ADObject on a GPO's AD object was refused in the lab even as
        #    Domain Admin, while GPMC's writes to the same objects succeeded) --
        $desiredFilter = $null
        if ($entry.PSObject.Properties['wmi_filter']) { $desiredFilter = $entry.wmi_filter }
        $currentFilter = $null
        if ($liveGpo.WmiFilter) { $currentFilter = $liveGpo.WmiFilter.Name }
        if ([string]$desiredFilter -ne [string]$currentFilter) {
            if (-not $desiredFilter) {
                Invoke-Change -Description "GPO '$name': clear WMI filter (was '$currentFilter')" -Action {
                    $liveGpo.WmiFilter = $null
                }
            }
            elseif ($liveFilters.ContainsKey([string]$desiredFilter)) {
                Invoke-Change -Description "GPO '$name': WMI filter '$currentFilter' -> '$desiredFilter'" -Action {
                    $filter = Get-GpmcWmiFilter -Name ([string]$desiredFilter)
                    if (-not $filter) { throw "GPMC cannot see WMI filter '$desiredFilter'" }
                    $liveGpo.WmiFilter = $filter
                }
            }
            elseif ($checkMode -and $CreateWmiFilters) {
                [void]$actions.Add("GPO '$name': link WMI filter '$desiredFilter' (after create)")
            }
            else {
                [void]$errors.Add("GPO '$name': WMI filter '$desiredFilter' not found in $Domain; filter link not set")
            }
        }
    }
    catch {
        [void]$errors.Add("GPO '$name': $($_.Exception.Message)")
    }
}

# --- 4. links, precedence, inheritance ------------------------------------------
$soms = @()
if ($manifest.PSObject.Properties['soms'] -and $manifest.soms) { $soms = @($manifest.soms) }
foreach ($som in $soms) {
    # Targets are relative to the domain root ('' = the root itself), so the
    # same manifest rebases onto whichever domain this run targets.
    $relative = [string]$som.target
    if ($relative) { $target = "$relative,$rootDn" } else { $target = $rootDn }
    try {
        try {
            Get-ADObject -Identity $target -Server $pdc | Out-Null
        }
        catch {
            [void]$errors.Add("SOM '$target' does not exist in $Domain; links not applied")
            continue
        }

        $inh = Get-GPInheritance -Target $target -Domain $Domain -Server $pdc
        $blocked = [bool]$inh.GpoInheritanceBlocked
        $desiredBlocked = [bool]$som.block_inheritance
        if ($blocked -ne $desiredBlocked) {
            Invoke-Change -Description "SOM '$target': block inheritance -> $desiredBlocked" -Action {
                Set-GPInheritance -Target $target -Domain $Domain -Server $pdc `
                    -IsBlocked (Get-YesNo $desiredBlocked) | Out-Null
            }
        }

        # Reconcile the whole ordered list (Get-GpoLinkPlan: Set-GPLink -Order
        # renumbers neighbours, so the plan tracks positions in a simulated
        # work list rather than checking each link against a stale snapshot).
        $currentLinks = @($inh.GpoLinks | Sort-Object Order | ForEach-Object {
                @{ name = $_.DisplayName; enforced = [bool]$_.Enforced; enabled = [bool]$_.Enabled }
            })
        $plan = @(Get-GpoLinkPlan -Current $currentLinks -Desired @($som.links) -RemoveUnmanaged ([bool]$RemoveUnmanagedLinks))
        foreach ($op in $plan) {
            $opName = [string]$op.name
            $opOrder = $op.order
            $opEnf = [bool]$op.enforced
            $opEna = [bool]$op.enabled
            switch ($op.action) {
                'new' {
                    try {
                        Invoke-Change -Description "SOM '$target': link '$opName' at order $opOrder (enforced=$opEnf, enabled=$opEna)" -Action {
                            New-GPLink -Name $opName -Target $target -Domain $Domain -Server $pdc `
                                -LinkEnabled (Get-YesNo $opEna) -Enforced (Get-YesNo $opEnf) -Order $opOrder | Out-Null
                        }
                    }
                    catch {
                        [void]$errors.Add("SOM '$target', link '$opName': $($_.Exception.Message)")
                    }
                }
                'set' {
                    try {
                        Invoke-Change -Description "SOM '$target': set link '$opName' order $opOrder (enforced=$opEnf, enabled=$opEna)" -Action {
                            Set-GPLink -Name $opName -Target $target -Domain $Domain -Server $pdc `
                                -LinkEnabled (Get-YesNo $opEna) -Enforced (Get-YesNo $opEnf) -Order $opOrder | Out-Null
                        }
                    }
                    catch {
                        [void]$errors.Add("SOM '$target', link '$opName': $($_.Exception.Message)")
                    }
                }
                'remove' {
                    Invoke-Change -Description "SOM '$target': remove unmanaged link '$opName'" -Action {
                        Remove-GPLink -Name $opName -Target $target -Domain $Domain -Server $pdc | Out-Null
                    }
                }
                default {
                    Add-Warning "SOM '$target': unmanaged link '$opName' left in place (remove_unmanaged_links not set)"
                }
            }
        }
    }
    catch {
        [void]$errors.Add("SOM '$target': $($_.Exception.Message)")
    }
}

# --- state + result -------------------------------------------------------------
# The state file records what landed; a check-mode run writes nothing.
if (-not $checkMode) {
    try {
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $StateDir)) {
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        }
        $stateOut = [ordered]@{ gpos = [ordered]@{} }
        foreach ($name in ($newState.Keys | Sort-Object)) {
            $stateOut.gpos[$name] = [ordered]@{ imported_hash = $newState[$name] }
        }
        Write-Utf8File -Path $stateFile -Content ($stateOut | ConvertTo-Json -Depth 10)
    }
    catch {
        [void]$errors.Add("state file $($stateFile): $($_.Exception.Message)")
    }
}

$module.Result.changed = ($actions.Count -gt 0)
$module.Result.actions = @($actions)
$module.Result.notices = @($warnings)
$module.Result.errors = @($errors)
$module.Result.imported = $importedCount
$module.Result.gpo_count = $gpoOrder.Count
$module.Result.som_count = $soms.Count
$module.Result.state_file = $stateFile
$module.Diff.prepared = (@($actions) -join "`n")

if ($errors.Count -gt 0) {
    $module.FailJson("gpo_import finished with $($errors.Count) error(s); see errors")
}
$module.ExitJson()
