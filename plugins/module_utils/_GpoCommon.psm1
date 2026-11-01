# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the gpo_export and gpo_import modules: the pure logic of Group
# Policy as code, with no Ansible.Basic, Active Directory or GPMC calls, so
# Pester tests it without a domain (tests/unit/plugins/module_utils/).
# Private to this collection, with no compatibility promise. Windows
# PowerShell 5.1 syntax only.
#
# Hashing decides what the export ships and what the import re-imports, and
# the manifest is the two modules' contract: change a function here and both
# sides change together. Get-DirContentHash's output format must never change
# (every recorded state would stop matching); its unit test pins a value.

Function ConvertTo-SafeName {
    <#
    .SYNOPSIS
    Returns a GPO display name as a folder name: \/:*?"<>| become _, trailing
    dots and spaces go, and an empty result is _.
    #>
    [CmdletBinding()]
    param ([string]$Name)

    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    $safe = $safe.TrimEnd('.', ' ')
    if (-not $safe) { $safe = '_' }
    $safe
}

Function Get-StringHash {
    <#
    .SYNOPSIS
    Returns the SHA-256 of a string's UTF-8 bytes as upper-case hex.
    #>
    [CmdletBinding()]
    param ([string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '')
    }
    finally { $sha.Dispose() }
}

Function Get-DirContentHash {
    <#
    .SYNOPSIS
    Returns a deterministic hash of a directory tree, or '' when the path is
    empty or missing.

    .DESCRIPTION
    One line per item, sorted by relative path (case-folded): "dir|<rel>" for
    a directory, empty ones included, so a GPO gaining or losing an empty
    User/ folder still registers, and "file|<rel>|<SHA-256>" for a file. The
    hash is Get-StringHash of those lines. Exclude names relative paths
    (case-insensitive) to leave out.
    #>
    [CmdletBinding()]
    param (
        [string]$Path,
        [string[]]$Exclude = @()
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $excluded = @($Exclude | ForEach-Object { $_.ToLowerInvariant() })
    $base = (Get-Item -LiteralPath $Path).FullName
    $sb = New-Object System.Text.StringBuilder
    $items = Get-ChildItem -LiteralPath $base -Recurse -Force |
        Sort-Object { $_.FullName.Substring($base.Length).ToLowerInvariant() }
    foreach ($it in $items) {
        $rel = $it.FullName.Substring($base.Length).TrimStart('\', '/').ToLowerInvariant()
        if ($excluded -contains $rel) { continue }
        if ($it.PSIsContainer) {
            [void]$sb.AppendLine("dir|$rel")
        }
        else {
            $h = (Get-FileHash -LiteralPath $it.FullName -Algorithm SHA256).Hash
            [void]$sb.AppendLine("file|$rel|$h")
        }
    }
    Get-StringHash -Text $sb.ToString()
}

Function Get-GpoLiveContentHash {
    <#
    .SYNOPSIS
    Returns the hash of a GPO's live Group Policy Template (its SYSVOL folder),
    in Get-DirContentHash's format, without gpt.ini.

    .DESCRIPTION
    gpt.ini holds the version counter, which GPMC bumps on every edit, and the
    display name, neither of which is settings content. Throws when the folder
    doesn't exist.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "its SYSVOL folder $Path does not exist"
    }
    Get-DirContentHash -Path $Path -Exclude 'gpt.ini'
}

Function Get-GpoSysvolPath {
    <#
    .SYNOPSIS
    Returns the {backup-guid}\DomainSysvol folder of a Backup-GPO folder, or
    $null when there is none.

    .DESCRIPTION
    Hashing only that subtree keeps the hash stable across re-backups
    (Backup.xml, bkupInfo.xml and gpreport.xml carry timestamps and a fresh
    backup GUID every time). A GPO with no settings has no DomainSysvol: $null
    hashes as '', rather than falling back to those volatile files.
    #>
    [CmdletBinding()]
    param ([string]$BackupDir)

    $guidDir = Get-ChildItem -LiteralPath $BackupDir -Directory |
        Where-Object { $_.Name -match '^\{.+\}$' } | Select-Object -First 1
    if ($null -eq $guidDir) { return $null }
    $sysvol = Join-Path $guidDir.FullName 'DomainSysvol'
    if (Test-Path -LiteralPath $sysvol) { return $sysvol }
    return $null
}

Function Test-GpoBackupFolder {
    <#
    .SYNOPSIS
    Returns why a Backup-GPO folder is incomplete, or '' when it is complete:
    exactly one {GUID} subfolder holding Backup.xml and gpreport.xml.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $guidDirs = @(Get-ChildItem -LiteralPath $Path -Directory | Where-Object { $_.Name -match '^\{.+\}$' })
    if ($guidDirs.Count -ne 1) {
        return "expected one {GUID} subfolder, found $($guidDirs.Count)"
    }
    $problem = ''
    foreach ($f in 'Backup.xml', 'gpreport.xml') {
        if (-not (Test-Path -LiteralPath (Join-Path $guidDirs[0].FullName $f))) { $problem = "no $f in $($guidDirs[0].Name)" }
    }
    $problem
}

Function Write-Utf8File {
    <#
    .SYNOPSIS
    Writes text as UTF-8 without a byte order mark.
    #>
    [CmdletBinding()]
    param ([string]$Path, [string]$Content)

    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

Function Get-NearestExistingDirectory {
    <#
    .SYNOPSIS
    Returns the path itself when it is a directory, else its nearest existing
    parent directory, or $null when none exists: where a preflight probe file
    proves a directory that doesn't exist yet could be created.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $dir = $Path
    while ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
    if ($dir) { $dir } else { $null }
}

Function New-ZipFromDirectory {
    <#
    .SYNOPSIS
    Zips a directory's contents, entry by entry.

    .DESCRIPTION
    Entry names use forward slashes (some .NET Framework and PowerShell 5.1
    combinations write backslashes, which Linux unzip warns about and
    Ansible's unarchive treats as failure), and empty directories get explicit
    entries (GPO backups contain them; Compress-Archive drops them).
    #>
    [CmdletBinding()]
    param ([string]$Source, [string]$Destination)

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $base = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $zip = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($item in Get-ChildItem -LiteralPath $base -Recurse -Force) {
            $rel = $item.FullName.Substring($base.Length).Replace('\', '/')
            if ($item.PSIsContainer) {
                if (-not (Get-ChildItem -LiteralPath $item.FullName -Force | Select-Object -First 1)) {
                    [void]$zip.CreateEntry($rel + '/')
                }
            }
            else {
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $item.FullName, $rel)
            }
        }
    }
    finally { $zip.Dispose() }
}

Function ConvertFrom-WmiFilterParm2 {
    <#
    .SYNOPSIS
    Parses msWMI-Parm2's single-query form, "1;3;<nsLen>;<qLen>;WQL;<namespace>;<query>;",
    into @{ namespace; query }, or returns $null (a multi-query filter, or text
    that doesn't parse).
    #>
    [CmdletBinding()]
    param ([string]$Parm2)

    try {
        $i = $Parm2.IndexOf(';')
        $count = [int]$Parm2.Substring(0, $i)
        if ($count -ne 1) { return $null }
        $parts = $Parm2.Substring($i + 1).Split(';', 4)
        $nsLen = [int]$parts[1]
        $qLen = [int]$parts[2]
        $tail = $parts[3]
        $tail = $tail.Substring($tail.IndexOf(';') + 1)   # skip the language token (WQL)
        @{
            namespace = $tail.Substring(0, $nsLen)
            query = $tail.Substring($nsLen + 1, $qLen)
        }
    }
    catch { $null }
}

Function ConvertTo-WmiFilterParm2 {
    <#
    .SYNOPSIS
    Encodes a namespace and a query as msWMI-Parm2's single-query form; the
    inverse of ConvertFrom-WmiFilterParm2.
    #>
    [CmdletBinding()]
    param ([string]$Namespace, [string]$Query)

    '1;3;{0};{1};WQL;{2};{3};' -f $Namespace.Length, $Query.Length, $Namespace, $Query
}

Function ConvertTo-RelativeDn {
    <#
    .SYNOPSIS
    Returns a distinguished name relative to the domain root ('' for the root
    itself), so the manifest imports into a domain with another name. Throws
    for a DN outside the root.
    #>
    [CmdletBinding()]
    param ([string]$Dn, [string]$RootDn)

    if ($Dn -ieq $RootDn) { return '' }
    $suffix = ',' + $RootDn
    if ($Dn.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Dn.Substring(0, $Dn.Length - $suffix.Length)
    }
    throw "'$Dn' is not inside '$RootDn'"
}

Function ConvertTo-LdapFilterValue {
    <#
    .SYNOPSIS
    Escapes a value for an LDAP filter (RFC 4515; backslash first).
    #>
    [CmdletBinding()]
    param ([string]$Value)

    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29')
}

Function Get-YesNo {
    <#
    .SYNOPSIS
    Returns 'Yes' or 'No', the form GPMC's link and inheritance cmdlets take.
    #>
    [CmdletBinding()]
    param ([bool]$Value)

    if ($Value) { 'Yes' } else { 'No' }
}

Function Test-Denied {
    <#
    .SYNOPSIS
    Whether a GPMC permission is a Deny entry (typically "Deny Apply group
    policy" to exclude admins), which must never be mistaken for a grant.
    #>
    [CmdletBinding()]
    param ($Permission)

    [bool]($Permission.PSObject.Properties['Denied'] -and $Permission.Denied)
}

Function Get-RelativeTrusteeName {
    <#
    .SYNOPSIS
    Strips the domain's NetBIOS prefix from a trustee name, so the manifest
    imports into any domain with the same naming convention. Other domains'
    and built-in names are left as they are.
    #>
    [CmdletBinding()]
    param ([string]$Name, [string]$NetBiosName)

    if ($Name -and $Name.Contains('\')) {
        $parts = $Name.Split('\', 2)
        if ($parts[0] -eq $NetBiosName) { return $parts[1] }
    }
    $Name
}

Function Get-TrusteeEntry {
    <#
    .SYNOPSIS
    Returns a GPMC permission's trustee as the manifest records it:
    [ordered]@{ name (domain-relative); type (User, Computer or Group) }.
    #>
    [CmdletBinding()]
    param ($Permission, [string]$NetBiosName)

    $name = Get-RelativeTrusteeName -Name ([string]$Permission.Trustee.Name) -NetBiosName $NetBiosName
    $type = 'Group'
    $sidType = [string]$Permission.Trustee.SidType
    if ($sidType -eq 'User') { $type = 'User' }
    elseif ($sidType -eq 'Computer') { $type = 'Computer' }
    [ordered]@{ name = $name; type = $type }
}

Function Get-CarriedOverGpoState {
    <#
    .SYNOPSIS
    Returns the export state entries a run carries over unchanged: with a
    gpo_names filter, every recorded GPO it didn't select (so the next full
    export doesn't re-ship them); without one, none (so a GPO gone from the
    domain shows as deleted).

    .DESCRIPTION
    State maps a GPO name to @{ hash; dir }. Returns a new hashtable.
    #>
    [CmdletBinding()]
    param (
        [hashtable]$State,
        [string[]]$Selected = @()
    )

    $carried = @{}
    $names = @($Selected | Where-Object { $_ })
    if ($names.Count -eq 0 -or $null -eq $State) { return $carried }
    foreach ($name in $State.Keys) {
        if ($names -notcontains $name) {
            $carried[$name] = @{ hash = $State[$name].hash; dir = $State[$name].dir }
        }
    }
    $carried
}

Function Get-DeletedGpoEntry {
    <#
    .SYNOPSIS
    Returns the GPOs the export state records but the domain no longer has, as
    [ordered]@{ name; backup_dir }, sorted by name. None while filtering: an
    unselected GPO is not a deleted one.
    #>
    [CmdletBinding()]
    param (
        [hashtable]$Recorded,
        [hashtable]$Live,
        [bool]$Filtered
    )

    if ($Filtered -or $null -eq $Recorded) { return }
    foreach ($name in ($Recorded.Keys | Sort-Object)) {
        if ($null -eq $Live -or -not $Live.ContainsKey($name)) {
            [ordered]@{ name = $name; backup_dir = $Recorded[$name].dir }
        }
    }
}

Function Resolve-GpoMigrationTablePath {
    <#
    .SYNOPSIS
    Returns the migration table's path: as given when rooted, else under the
    source directory; '' when none was given.
    #>
    [CmdletBinding()]
    param ([string]$Path, [string]$SourceDir)

    if (-not $Path) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    Join-Path $SourceDir $Path
}

Function Get-GpoImportReason {
    <#
    .SYNOPSIS
    Returns why a GPO must be imported, or '' when it needn't be.

    .DESCRIPTION
    In order: force; the GPO is missing from the domain; this pipeline never
    imported it (no recorded key); its import key (the backup's content hash
    plus the migration table's) differs from the recorded one.
    #>
    [CmdletBinding()]
    param (
        [bool]$Force,
        [bool]$LiveExists,
        [bool]$Recorded,
        [string]$RecordedKey,
        [string]$ImportKey
    )

    if ($Force) { return 'forced' }
    if (-not $LiveExists) { return 'GPO missing in target' }
    if (-not $Recorded) { return 'never imported by this pipeline' }
    if ($RecordedKey -ne $ImportKey) { return 'backup content or migration table changed' }
    ''
}

Function Get-GpoLinkPlan {
    <#
    .SYNOPSIS
    Plans the link changes that make a container's ordered link list match the
    manifest's.

    .DESCRIPTION
    Current is the container's links in order, each @{ name; enforced; enabled };
    Desired is the manifest's, each with gpo, enforced and enabled. Returns the
    operations in the order to perform them, each [ordered]@{ action; name;
    order; enforced; enabled }, where action is:
      new        link the GPO at order (New-GPLink -Order)
      set        move it to order and/or set enforced/enabled (Set-GPLink -Order)
      remove     a link the manifest doesn't list, with RemoveUnmanaged
      unmanaged  the same without RemoveUnmanaged: report it, leave it
    Set-GPLink -Order renumbers the neighbours, so the plan tracks positions in
    a simulated work list instead of checking each link against a stale
    snapshot, which doesn't converge. GPO names compare case-insensitively.
    #>
    [CmdletBinding()]
    param (
        [object[]]$Current = @(),
        [object[]]$Desired = @(),
        [bool]$RemoveUnmanaged
    )

    $work = New-Object System.Collections.ArrayList
    foreach ($l in @($Current | Where-Object { $null -ne $_ })) {
        [void]$work.Add(@{ name = [string]$l.name; enforced = [bool]$l.enforced; enabled = [bool]$l.enabled })
    }
    $desiredList = @($Desired | Where-Object { $null -ne $_ })
    for ($i = 0; $i -lt $desiredList.Count; $i++) {
        $d = $desiredList[$i]
        $dName = [string]$d.gpo
        $dEnf = [bool]$d.enforced
        $dEna = [bool]$d.enabled
        $idx = -1
        for ($j = 0; $j -lt $work.Count; $j++) {
            if ([string]$work[$j].name -ieq $dName) { $idx = $j; break }
        }
        $op = [ordered]@{ action = ''; name = $dName; order = $i + 1; enforced = $dEnf; enabled = $dEna }
        if ($idx -lt 0) {
            $op.action = 'new'
            $op
            $work.Insert([Math]::Min($i, $work.Count), @{ name = $dName; enforced = $dEnf; enabled = $dEna })
        }
        else {
            $cur = $work[$idx]
            if (($idx -ne $i) -or ($cur.enforced -ne $dEnf) -or ($cur.enabled -ne $dEna)) {
                $op.action = 'set'
                $op
                $work.RemoveAt($idx)
                $work.Insert([Math]::Min($i, $work.Count), @{ name = $dName; enforced = $dEnf; enabled = $dEna })
            }
        }
    }
    $desiredNames = @($desiredList | ForEach-Object { ([string]$_.gpo).ToLowerInvariant() })
    foreach ($w in @($work)) {
        if ($desiredNames -contains ([string]$w.name).ToLowerInvariant()) { continue }
        $action = 'unmanaged'
        if ($RemoveUnmanaged) { $action = 'remove' }
        [ordered]@{ action = $action; name = [string]$w.name; order = $null; enforced = $w.enforced; enabled = $w.enabled }
    }
}

$exportFunctions = @(
    'ConvertFrom-WmiFilterParm2'
    'ConvertTo-LdapFilterValue'
    'ConvertTo-RelativeDn'
    'ConvertTo-SafeName'
    'ConvertTo-WmiFilterParm2'
    'Get-CarriedOverGpoState'
    'Get-DeletedGpoEntry'
    'Get-DirContentHash'
    'Get-GpoImportReason'
    'Get-GpoLinkPlan'
    'Get-GpoLiveContentHash'
    'Get-GpoSysvolPath'
    'Get-NearestExistingDirectory'
    'Get-RelativeTrusteeName'
    'Get-StringHash'
    'Get-TrusteeEntry'
    'Get-YesNo'
    'New-ZipFromDirectory'
    'Resolve-GpoMigrationTablePath'
    'Test-Denied'
    'Test-GpoBackupFolder'
    'Write-Utf8File'
)
Export-ModuleMember -Function $exportFunctions
