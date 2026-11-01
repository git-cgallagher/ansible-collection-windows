#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._GpoCommon

# Export a domain's GPOs plus a topology manifest. Runs on a Windows
# management host with RSAT (GroupPolicy + ActiveDirectory modules); roles/gpo_backup
# calls it and fetches the zip.
#
# Output layout (zipped into <work_dir>\gpo-export.zip):
#   export\gpos\<SafeName>\manifest.xml + {backup-guid}\...   one self-contained
#       Backup-GPO folder per GPO: only GPOs whose live SYSVOL content changed
#       since the last run are included (the state file keeps the hashes)
#   export\gpo-manifest.json                                  always included
#
# Change detection hashes each GPO's live Group Policy Template under
# \\<dc>\SYSVOL\<domain>\Policies\{guid} (Get-GpoLiveContentHash), never the
# backup, so check mode decides exactly like a real run without running
# Backup-GPO or writing anything: it reads AD and SYSVOL and returns the plan.
#
# Windows PowerShell 5.1-compatible. The pure logic (hashing, the zip, the
# manifest's encodings, the state decisions) lives in
# plugins/module_utils/_GpoCommon.psm1, shared with gpo_import and unit-tested
# with Pester (tests/unit/plugins/).

# The argument spec and Create come first: ansible-test's validate-modules runs
# this file under pwsh on Linux up to Create to read the spec.
$spec = @{
    options = @{
        domain = @{ type = 'str'; required = $true }
        server = @{ type = 'str' }
        work_dir = @{ type = 'str'; default = 'C:\ProgramData\gpo-iac\backup' }
        gpo_names = @{ type = 'list'; elements = 'str'; default = @() }
        full_export = @{ type = 'bool'; default = $false }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Domain = $module.Params.domain
$Server = [string]$module.Params.server
$WorkDir = $module.Params.work_dir
$GpoNames = @($module.Params.gpo_names)
$FullExport = [bool]$module.Params.full_export
$checkMode = $module.CheckMode


$module.Result.shipped = @()
$module.Result.deleted = @()
$module.Result.manifest_changed = $false
$module.Result.gpo_count = 0
$module.Result.zip = $null
$module.Result.server = $null
$module.Result.errors = @()
# What the run proved before doing anything: AD and GPMC answer for the
# domain, and work_dir (or the nearest existing parent it would be created
# under) takes a file. In check mode the latter is a uniquely named probe
# file, created and removed at once: the one write check mode makes.
$module.Result.preflight = [ordered]@{
    ad = $false
    gpmc = $false
    work_dir_exists = $false
    work_dir_writable = $false
    work_dir_probed = $null
}

# FailJson exits through an exception, so the try block below only computes;
# failures are reported after it (a per-GPO backup failure) or in catch.
$backupErrors = New-Object System.Collections.ArrayList
$preflightFailure = $null
try {
    try {
        Import-Module GroupPolicy, ActiveDirectory
    }
    catch {
        throw "The GroupPolicy and ActiveDirectory PowerShell modules are required (install RSAT): $_"
    }

    # --- resolve domain context ---------------------------------------------
    $adDomain = Get-ADDomain -Identity $Domain
    $pdc = $Server
    if (-not $pdc) { $pdc = $adDomain.PDCEmulator }
    $rootDn = $adDomain.DistinguishedName
    $netbios = $adDomain.NetBIOSName
    $module.Result.server = $pdc
    $module.Result.preflight.ad = $true

    # --- preflight: can the export be written? ------------------------------
    $module.Result.preflight.work_dir_exists = [bool](Test-Path -ErrorAction SilentlyContinue -LiteralPath $WorkDir -PathType Container)
    if ($checkMode) {
        $probeDir = Get-NearestExistingDirectory -Path $WorkDir
        if (-not $probeDir) {
            $preflightFailure = "work_dir $WorkDir can't be created: none of its parents exist."
        }
        else {
            $module.Result.preflight.work_dir_probed = $probeDir
            $probeFile = Join-Path $probeDir ('gpo_export-probe-{0}.tmp' -f [guid]::NewGuid())
            try {
                [System.IO.File]::WriteAllText($probeFile, 'gpo_export check-mode writability probe')
                $module.Result.preflight.work_dir_writable = $true
            }
            catch {
                $preflightFailure = "work_dir $WorkDir isn't writable (probed $probeDir): $($_.Exception.Message)"
            }
            finally {
                if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $probeFile) { Remove-Item -LiteralPath $probeFile -Force }
            }
        }
    }

    # --- state --------------------------------------------------------------
    # Read-only here: check mode must not create work_dir either.
    $stateFile = Join-Path $WorkDir ("backup-state-{0}.json" -f $Domain.ToLowerInvariant())
    $state = @{ gpos = @{}; manifest_hash = '' }
    if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $stateFile) {
        $rawState = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rawState.PSObject.Properties['gpos']) {
            foreach ($p in $rawState.gpos.PSObject.Properties) {
                $state.gpos[$p.Name] = @{ hash = [string]$p.Value.hash; dir = [string]$p.Value.dir }
            }
        }
        if ($rawState.PSObject.Properties['manifest_hash']) {
            $state.manifest_hash = [string]$rawState.manifest_hash
        }
    }

    # --- decide what ships, from the live GPOs ------------------------------
    $live = @(Get-GPO -All -Domain $Domain -Server $pdc | Sort-Object DisplayName)
    $module.Result.preflight.gpmc = $true
    if ($preflightFailure) { throw "check-mode preflight failed: $preflightFailure" }
    if ($GpoNames.Count -gt 0) {
        $live = @($live | Where-Object { $GpoNames -contains $_.DisplayName })
    }
    $module.Result.gpo_count = $live.Count
    $policies = "\\$pdc\SYSVOL\$Domain\Policies"

    $safeSeen = @{}
    $shipped = New-Object System.Collections.ArrayList
    # A filtered run (gpo_names) keeps the unselected GPOs' recorded hashes, so
    # the next full export doesn't re-ship them; the selected ones are rewritten
    # below. An unfiltered run starts empty, which is how a deleted GPO shows.
    $newState = @{ gpos = (Get-CarriedOverGpoState -State $state.gpos -Selected $GpoNames); manifest_hash = '' }

    foreach ($gpo in $live) {
        $safe = ConvertTo-SafeName -Name $gpo.DisplayName
        if ($safeSeen.ContainsKey($safe.ToLowerInvariant())) {
            throw ("GPO display names '{0}' and '{1}' map to the same folder name '{2}'; rename one." -f
                $safeSeen[$safe.ToLowerInvariant()], $gpo.DisplayName, $safe)
        }
        $safeSeen[$safe.ToLowerInvariant()] = $gpo.DisplayName

        # One broken GPO (missing SYSVOL folder, unreadable files) must not hide
        # the others: collect every failure, then fail the run without saving state.
        try {
            $gpt = Join-Path $policies ('{{{0}}}' -f $gpo.Id)
            if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $gpt -PathType Container)) {
                throw "its SYSVOL folder $gpt does not exist"
            }
            $hash = Get-GpoLiveContentHash -Path $gpt
        }
        catch {
            [void]$backupErrors.Add("GPO '$($gpo.DisplayName)': $($_.Exception.Message)")
            $newState.gpos[$gpo.DisplayName] = @{ hash = ''; dir = $safe }
            continue
        }
        $newState.gpos[$gpo.DisplayName] = @{ hash = $hash; dir = $safe }

        $prev = $null
        if ($state.gpos.ContainsKey($gpo.DisplayName)) { $prev = $state.gpos[$gpo.DisplayName].hash }
        if ($FullExport -or ($hash -ne $prev)) {
            [void]$shipped.Add([ordered]@{ name = $gpo.DisplayName; backup_dir = $safe; id = $gpo.Id })
        }
    }

    # GPOs recorded in state but gone from the domain (skip when filtering: an
    # unselected GPO is not a deleted one).
    $deleted = @(Get-DeletedGpoEntry -Recorded $state.gpos -Live $newState.gpos -Filtered ($GpoNames.Count -gt 0))

    # --- build the topology manifest -----------------------------------------
    $manifest = [ordered]@{
        domain = $Domain
        netbios = $netbios
        root_dn = $rootDn
        domain_sid = $adDomain.DomainSID.Value
        gpos = [ordered]@{}
        wmi_filters = [ordered]@{}
        soms = @()
    }

    foreach ($gpo in $live) {
        $wmiName = $null
        if ($gpo.WmiFilter) { $wmiName = $gpo.WmiFilter.Name }
        $perms = @(Get-GPPermission -Guid $gpo.Id -All -Domain $Domain -Server $pdc)
        $applyTo = @(
            $perms | Where-Object { [string]$_.Permission -eq 'GpoApply' -and -not (Test-Denied $_) } |
                ForEach-Object { Get-TrusteeEntry -Permission $_ -NetBiosName $netbios } |
                Sort-Object { $_['name'] }
        )
        # Recorded so they're visible in Git and checked on import; this
        # collection can't create Deny entries (Set-GPPermission has no deny).
        $denied = @(
            $perms | Where-Object { Test-Denied $_ } | ForEach-Object {
                $trustee = Get-TrusteeEntry -Permission $_ -NetBiosName $netbios
                $trustee['permission'] = [string]$_.Permission
                $trustee
            } | Sort-Object { $_['name'] }
        )
        $manifest.gpos[$gpo.DisplayName] = [ordered]@{
            backup_dir = $newState.gpos[$gpo.DisplayName].dir
            status = $gpo.GpoStatus.ToString()
            wmi_filter = $wmiName
            apply_to = $applyTo
            denied = $denied
        }
    }

    $somContainer = "CN=SOM,CN=WMIPolicy,CN=System,$rootDn"
    $filters = @(
        Get-ADObject -SearchBase $somContainer -SearchScope OneLevel -Server $pdc `
            -LDAPFilter '(objectClass=msWMI-Som)' `
            -Properties msWMI-Name, msWMI-Parm1, msWMI-Parm2 -ErrorAction SilentlyContinue
    ) | Sort-Object { [string]$_.'msWMI-Name' }
    foreach ($f in $filters) {
        $parsed = ConvertFrom-WmiFilterParm2 -Parm2 ([string]$f.'msWMI-Parm2')
        $entry = [ordered]@{
            description = [string]$f.'msWMI-Parm1'
            namespace = $null
            query = $null
            raw_parm2 = [string]$f.'msWMI-Parm2'
        }
        if ($parsed) {
            $entry.namespace = $parsed.namespace
            $entry.query = $parsed.query
        }
        $manifest.wmi_filters[[string]$f.'msWMI-Name'] = $entry
    }

    # Scopes of management: the domain root plus every OU, shallowest first.
    $somDns = @($rootDn) + @(
        Get-ADOrganizationalUnit -Filter * -SearchBase $rootDn -Server $pdc |
            Select-Object -ExpandProperty DistinguishedName |
            Sort-Object @{ Expression = { ($_ -split ',(?=OU=|DC=)').Count } }, @{ Expression = { $_ } }
    )
    foreach ($dn in $somDns) {
        $inh = Get-GPInheritance -Target $dn -Domain $Domain -Server $pdc
        $blocked = [bool]$inh.GpoInheritanceBlocked
        $links = @(
            $inh.GpoLinks | Sort-Object Order | ForEach-Object {
                [ordered]@{
                    gpo = $_.DisplayName
                    enforced = [bool]$_.Enforced
                    enabled = [bool]$_.Enabled
                }
            }
        )
        if ($links.Count -gt 0 -or $blocked) {
            $manifest.soms += , ([ordered]@{
                    target = ConvertTo-RelativeDn -Dn $dn -RootDn $rootDn
                    block_inheritance = $blocked
                    links = $links
                })
        }
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    $manifestHash = Get-StringHash -Text $manifestJson
    $newState.manifest_hash = $manifestHash
    $manifestChanged = ($manifestHash -ne $state.manifest_hash)

    # --- real run only: stage, back up what ships, zip, save state ----------
    if (-not $checkMode) {
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $WorkDir)) {
            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
        }
        $stage = Join-Path $WorkDir 'stage'
        if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        $exportRoot = Join-Path $stage 'export'
        $exportGpos = Join-Path $exportRoot 'gpos'
        New-Item -ItemType Directory -Path $exportGpos -Force | Out-Null
        $module.Result.preflight.work_dir_probed = $WorkDir
        $module.Result.preflight.work_dir_writable = $true

        foreach ($entry in $shipped) {
            try {
                $backupDir = Join-Path $exportGpos $entry.backup_dir
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                Backup-GPO -Guid $entry.id -Domain $Domain -Server $pdc -Path $backupDir `
                    -Comment 'git_cgallagher.windows export' | Out-Null
            }
            catch {
                [void]$backupErrors.Add("GPO '$($entry.name)': $($_.Exception.Message)")
            }
        }

        Write-Utf8File -Path (Join-Path $exportRoot 'gpo-manifest.json') -Content $manifestJson

        $zipPath = Join-Path $WorkDir 'gpo-export.zip'
        if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
        New-ZipFromDirectory -Source $exportRoot -Destination $zipPath
        $module.Result.zip = $zipPath

        # A failed GPO must not be "used up": with errors, keep the old state so
        # the next run re-exports everything that changed.
        if ($backupErrors.Count -eq 0) {
            $stateOut = [ordered]@{
                hash_basis = 'sysvol'
                gpos = [ordered]@{}
                manifest_hash = $newState.manifest_hash
            }
            foreach ($name in ($newState.gpos.Keys | Sort-Object)) {
                $stateOut.gpos[$name] = [ordered]@{
                    hash = $newState.gpos[$name].hash
                    dir = $newState.gpos[$name].dir
                }
            }
            Write-Utf8File -Path $stateFile -Content ($stateOut | ConvertTo-Json -Depth 10)
        }
    }

    foreach ($entry in $shipped) { $entry.Remove('id') }
    $module.Result.shipped = @($shipped)
    $module.Result.deleted = @($deleted)
    $module.Result.manifest_changed = $manifestChanged
    $module.Result.errors = @($backupErrors)
    $module.Result.changed = ($shipped.Count -gt 0) -or ($deleted.Count -gt 0) -or $manifestChanged
}
catch {
    $module.Result.errors = @($backupErrors)
    $module.FailJson("gpo_export failed for $($Domain): $($_.Exception.Message)", $_)
}

if ($backupErrors.Count -gt 0) {
    $module.FailJson(("gpo_export failed for {0} GPO(s) in {1}; see errors: {2}" -f
            $backupErrors.Count, $Domain, ($backupErrors -join '; ')))
}

$module.ExitJson()
