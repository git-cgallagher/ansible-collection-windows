# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the gpo_sync_export and gpo_sync_import modules: the pure logic of Group
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

    if (-not $Path -or -not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $Path)) { return '' }
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

    if (-not $Path -or -not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $Path -PathType Container)) {
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
    if (Test-Path -ErrorAction SilentlyContinue -LiteralPath $sysvol) { return $sysvol }
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
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath (Join-Path $guidDirs[0].FullName $f))) { $problem = "no $f in $($guidDirs[0].Name)" }
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
    proves a directory that doesn't exist yet could be created. A path on a
    drive that doesn't exist has no parent either: $null, not an error.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $dir = $Path
    while ($dir -and -not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $dir -PathType Container)) {
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

Function Get-GpoExportScope {
    <#
    .SYNOPSIS
    Splits an export's GPOs into what the manifest covers and what the run
    hashes and ships, and says which recorded state entries it carries over:
    @{ filtered; backup_dirs; selected; carried }.

    .DESCRIPTION
    backup_dirs maps every GPO name to its folder name, sorted by name: the
    manifest always describes the whole domain, so its hash doesn't move
    between filtered and full runs and the repo's manifest stays whole. Two
    names that map to the same folder name throw, filter or not.

    selected is the names the run hashes and ships, sorted: the gpo_names the
    domain has, or every GPO without a filter (empty names are no filter).

    carried is a new hashtable of the State entries (name -> @{ hash; dir })
    the run keeps without looking at them: with a filter, every one it doesn't
    rewrite, a GPO gone from the domain included, so that a later full run
    reports the deletion; without one, none, so a GPO gone from the domain
    shows as deleted.
    #>
    [CmdletBinding()]
    param (
        [string[]]$Names = @(),
        [string[]]$Selected = @(),
        [hashtable]$State
    )

    $dirs = Get-GpoFolderName -Names $Names
    $filter = @($Selected | Where-Object { $_ })
    $filtered = $filter.Count -gt 0
    $picked = @($dirs.Keys | Where-Object { -not $filtered -or $filter -contains $_ })

    $carried = @{}
    if ($filtered -and $null -ne $State) {
        foreach ($name in $State.Keys) {
            if ($picked -notcontains $name) {
                $carried[$name] = @{ hash = $State[$name].hash; dir = $State[$name].dir }
            }
        }
    }
    @{ filtered = $filtered; backup_dirs = $dirs; selected = $picked; carried = $carried }
}

Function Get-GpoFolderName {
    <#
    .SYNOPSIS
    Maps GPO display names to their folder names (ConvertTo-SafeName), as an
    ordered hashtable sorted by name. Two names that map to the same folder
    name (case-insensitively, as Windows compares them) throw.
    #>
    [CmdletBinding()]
    param ([string[]]$Names = @())

    $dirs = [ordered]@{}
    $seen = @{}
    foreach ($name in @($Names | Where-Object { $_ } | Sort-Object)) {
        $safe = ConvertTo-SafeName -Name $name
        $key = $safe.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            throw ("GPO display names '{0}' and '{1}' map to the same folder name '{2}'; rename one." -f
                $seen[$key], $name, $safe)
        }
        $seen[$key] = $name
        $dirs[$name] = $safe
    }
    $dirs
}

Function ConvertTo-GpoId {
    <#
    .SYNOPSIS
    Returns a GUID in one form, lower case without braces, so GUIDs from GPMC,
    AD and backup files compare as strings; '' when the value isn't a GUID.
    #>
    [CmdletBinding()]
    param ([string]$Value)

    $guid = [guid]::Empty
    if ($Value -and [guid]::TryParse($Value.Trim(), [ref]$guid)) { return $guid.ToString('D') }
    ''
}

Function Read-GpoExportRecord {
    <#
    .SYNOPSIS
    Reads the export record gpo_export writes into a GPO's folder
    (gpo-export.json): @{ name; id; content_hash }, or $null when the folder
    has none or it doesn't parse (either way the folder is exported again).
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $file = [System.IO.Path]::Combine($Path, 'gpo-export.json')
    if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $file -PathType Leaf)) { return $null }
    try {
        $raw = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        @{
            name = [string]$raw.name
            id = ConvertTo-GpoId -Value ([string]$raw.id)
            content_hash = [string]$raw.content_hash
        }
    }
    catch { $null }
}

Function ConvertTo-GpoExportRecordJson {
    <#
    .SYNOPSIS
    Returns the export record's JSON (Read-GpoExportRecord's input): the GPO's
    name and GUID and the hash of the live content the backup was taken from.
    #>
    [CmdletBinding()]
    param ([string]$Name, [string]$Id, [string]$Domain, [string]$ContentHash)

    [ordered]@{
        name = $Name
        id = ConvertTo-GpoId -Value $Id
        domain = $Domain
        content_hash = $ContentHash
        hash_basis = 'sysvol'
    } | ConvertTo-Json
}

Function Get-GpoExportReason {
    <#
    .SYNOPSIS
    Returns why gpo_export must (re-)export a GPO into its folder, or '' when
    the folder already holds a complete backup of the GPO's live content.

    .DESCRIPTION
    In order: the folder is missing; it is incomplete (Problem, from
    Test-GpoBackupFolder); it has no export record (Record, from
    Read-GpoExportRecord); the record names another GPO (a GPO deleted and
    recreated under the same name, say); the live content hash differs from
    the recorded one.
    #>
    [CmdletBinding()]
    param (
        [bool]$FolderExists,
        [string]$Problem,
        [hashtable]$Record,
        [string]$Id,
        [string]$ContentHash
    )

    if (-not $FolderExists) { return 'not exported yet' }
    if ($Problem) { return "backup folder incomplete ($Problem)" }
    if ($null -eq $Record) { return 'no export record' }
    if ($Record.id -ne (ConvertTo-GpoId -Value $Id)) { return 'the folder holds another GPO''s backup' }
    if ($Record.content_hash -ne $ContentHash) { return 'content changed' }
    ''
}

Function Test-GpoBackupInstance {
    <#
    .SYNOPSIS
    Returns why one Backup-GPO instance (a {backup-id} folder) is incomplete,
    or '' when it holds Backup.xml, bkupInfo.xml and gpreport.xml.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    foreach ($f in 'Backup.xml', 'bkupInfo.xml', 'gpreport.xml') {
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath ([System.IO.Path]::Combine($Path, $f)) -PathType Leaf)) {
            return "no $f in $([System.IO.Path]::GetFileName($Path))"
        }
    }
    ''
}

Function Get-GpoBackupIndex {
    <#
    .SYNOPSIS
    Lists the Backup-GPO instances under a directory, by the GPO display name
    each backup records: @{ backups; unreadable }.

    .DESCRIPTION
    An instance is a {backup-id} folder holding bkupInfo.xml, either directly
    under Path (Backup-GPO -All into one directory) or one level down
    (gpo_export's Path\<folder>\{backup-id}). backups is a list of
    [ordered]@{ name; gpo_id; backup_id; dir; parent }, sorted by dir: name,
    gpo_id and backup_id come from bkupInfo.xml (GPODisplayName, GPOGuid, ID),
    never from the folder names; dir is the instance's folder and parent the
    folder Import-GPO's -Path takes. unreadable lists the instance folders
    whose bkupInfo.xml doesn't parse or lacks those values.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $backups = [System.Collections.Generic.List[object]]::new()
    $unreadable = [System.Collections.Generic.List[object]]::new()
    if (-not $Path -or -not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $Path -PathType Container)) {
        return @{ backups = @(); unreadable = @() }
    }
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @(Get-ChildItem -LiteralPath $Path -Directory -Force)) {
        if ($d.Name -match '^\{.+\}$') { $candidates.Add($d); continue }
        foreach ($sub in @(Get-ChildItem -LiteralPath $d.FullName -Directory -Force | Where-Object { $_.Name -match '^\{.+\}$' })) {
            $candidates.Add($sub)
        }
    }
    foreach ($c in @($candidates | Sort-Object FullName)) {
        $info = [System.IO.Path]::Combine($c.FullName, 'bkupInfo.xml')
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $info -PathType Leaf)) { continue }
        $name = ''
        $gpoId = ''
        $backupId = ''
        try {
            $xml = New-Object System.Xml.XmlDocument
            $xml.Load($info)
            $node = $xml.SelectSingleNode("//*[local-name()='GPODisplayName']")
            if ($node) { $name = $node.InnerText.Trim() }
            $node = $xml.SelectSingleNode("//*[local-name()='GPOGuid']")
            if ($node) { $gpoId = ConvertTo-GpoId -Value $node.InnerText }
            $node = $xml.SelectSingleNode("//*[local-name()='ID']")
            if ($node) { $backupId = ConvertTo-GpoId -Value $node.InnerText }
        }
        catch {
            $name = ''
        }
        if (-not $name -or -not $backupId) {
            $unreadable.Add($c.FullName)
            continue
        }
        $backups.Add([ordered]@{
                name = $name
                gpo_id = $gpoId
                backup_id = $backupId
                dir = $c.FullName
                parent = $c.Parent.FullName
            })
    }
    @{ backups = @($backups); unreadable = @($unreadable) }
}

Function Resolve-GpoBackupName {
    <#
    .SYNOPSIS
    Resolves GPO names to backups from Get-GpoBackupIndex:
    @{ resolved; missing; ambiguous }.

    .DESCRIPTION
    Names compare case-insensitively, as GPMC's do, and a name given twice
    counts once. resolved is an ordered hashtable, in the order the names were
    given, from each name that matches exactly one backup to that backup;
    missing lists the names no backup records; ambiguous lists, as
    "<name>: <dir>, <dir>", the names two or more backups record.
    #>
    [CmdletBinding()]
    param (
        [object[]]$Backups = @(),
        [string[]]$Names = @()
    )

    $resolved = [ordered]@{}
    $missing = [System.Collections.Generic.List[object]]::new()
    $ambiguous = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($name in @($Names | Where-Object { $_ })) {
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $hits = @($Backups | Where-Object { $null -ne $_ -and ([string]$_.name).ToLowerInvariant() -eq $key })
        if ($hits.Count -eq 0) { $missing.Add($name) }
        elseif ($hits.Count -gt 1) { $ambiguous.Add(('{0}: {1}' -f $name, (($hits | ForEach-Object { $_.dir }) -join ', '))) }
        else { $resolved[$name] = $hits[0] }
    }
    @{ resolved = $resolved; missing = @($missing); ambiguous = @($ambiguous) }
}

Function Get-GpoCpasswordFile {
    <#
    .SYNOPSIS
    Returns the XML files under the given directories that hold a non-empty
    Group Policy Preferences cpassword, sorted. GPP writes cpassword="" on
    items that set no password (renaming the built-in Administrator, say);
    only a value is a secret.
    #>
    [CmdletBinding()]
    param ([string[]]$Path = @())

    $hits = foreach ($dir in @($Path | Where-Object { $_ })) {
        if (-not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $dir -PathType Container)) { continue }
        Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.xml' -File |
            Select-String -Pattern 'cpassword="[^"]+"' -List | ForEach-Object { $_.Path }
    }
    @($hits | Sort-Object -Unique)
}

Function Get-GpoImportKey {
    <#
    .SYNOPSIS
    Returns what an import of a backup is recorded under: the hash of the
    backup's DomainSysvol subtree (the settings, without the backup's volatile
    metadata) and of the migration table, in gpo_sync_import's format.
    #>
    [CmdletBinding()]
    param ([string]$BackupDir, [string]$MigrationTableHash = '')

    $sysvol = ''
    if ($BackupDir) { $sysvol = [System.IO.Path]::Combine($BackupDir, 'DomainSysvol') }
    Get-StringHash -Text ((Get-DirContentHash -Path $sysvol) + '|' + $MigrationTableHash)
}

Function Read-GpoImportRecord {
    <#
    .SYNOPSIS
    Reads gpo_import's record of what it imported into a domain: a hashtable
    from each target GPO's GUID (ConvertTo-GpoId) to @{ name; import_key }.
    Empty when the file doesn't exist; throws when it doesn't parse.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $record = @{}
    if (-not $Path -or -not (Test-Path -ErrorAction SilentlyContinue -LiteralPath $Path -PathType Leaf)) { return $record }
    $raw = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($null -eq $raw -or -not $raw.PSObject.Properties['gpos']) { throw "$Path has no 'gpos' object" }
    foreach ($p in @($raw.gpos.PSObject.Properties)) {
        $id = ConvertTo-GpoId -Value $p.Name
        if (-not $id) { continue }
        $record[$id] = @{ name = [string]$p.Value.name; import_key = [string]$p.Value.import_key }
    }
    $record
}

Function ConvertTo-GpoImportRecordJson {
    <#
    .SYNOPSIS
    Returns Read-GpoImportRecord's input for a record, its GPOs sorted by GUID
    so an unchanged record writes the same bytes.
    #>
    [CmdletBinding()]
    param ([hashtable]$Record = @{})

    $out = [ordered]@{ gpos = [ordered]@{} }
    foreach ($id in @($Record.Keys | Sort-Object)) {
        $out.gpos[$id] = [ordered]@{ name = [string]$Record[$id].name; import_key = [string]$Record[$id].import_key }
    }
    $out | ConvertTo-Json -Depth 5
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
    source directory; '' when none was given. Never resolves a drive (unlike
    Join-Path in Windows PowerShell), so a source directory on a drive that
    doesn't exist reaches the preflight's "not found".
    #>
    [CmdletBinding()]
    param ([string]$Path, [string]$SourceDir)

    if (-not $Path) { return '' }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    [System.IO.Path]::Combine($SourceDir, $Path)
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

Function Get-GpoImportDecision {
    <#
    .SYNOPSIS
    Returns why gpo_import must import a backup into a domain, or '' when
    it needn't: Get-GpoImportReason over its record.

    .DESCRIPTION
    TargetId is the target GPO's GUID ('' or $null when the domain lacks it);
    Record is Read-GpoImportRecord's hashtable, empty when the record is
    missing or didn't parse. Only the target GPO's own entry counts: a GPO
    the record doesn't name, or names under another GUID, is imported.
    #>
    [CmdletBinding()]
    param (
        [bool]$Force,
        [string]$TargetId,
        [hashtable]$Record = @{},
        [string]$ImportKey
    )

    $id = ConvertTo-GpoId -Value $TargetId
    $recorded = [bool]$id -and $null -ne $Record -and $Record.ContainsKey($id)
    $recordedKey = ''
    if ($recorded) { $recordedKey = [string]$Record[$id].import_key }
    Get-GpoImportReason -Force $Force -LiveExists ([bool]$id) -Recorded $recorded -RecordedKey $recordedKey -ImportKey $ImportKey
}

Function Get-GpoImportScope {
    <#
    .SYNOPSIS
    Says which of a manifest's GPOs and WMI filters an import covers:
    @{ filtered; gpos; wmi_filters }.

    .DESCRIPTION
    Gpos maps each manifest GPO name to its entry (manifest.gpos, whose
    wmi_filter names the filter it links); WmiFilters is the manifest's WMI
    filter names. With no Selected names the import covers every GPO and every
    filter. With Selected (gpo_sync_import's gpo_names), gpos is the selected names
    the manifest has, spelt as the manifest spells them (a name it doesn't have
    selects nothing), and wmi_filters only the manifest's filters a selected
    GPO links: a subset moved into another domain neither creates nor warns
    about the other GPOs' filters. Both lists are sorted; names compare
    case-insensitively, as GPMC's do.
    #>
    [CmdletBinding()]
    param (
        [hashtable]$Gpos = @{},
        [string[]]$WmiFilters = @(),
        [string[]]$Selected = @()
    )

    $filter = @($Selected | Where-Object { $_ })
    $filtered = $filter.Count -gt 0
    $names = @($Gpos.Keys | Where-Object { -not $filtered -or $filter -contains $_ } | Sort-Object)
    $filters = @($WmiFilters | Where-Object { $_ } | Sort-Object)
    if ($filtered) {
        $linked = @($names | ForEach-Object { [string]$Gpos[$_].wmi_filter } | Where-Object { $_ })
        $filters = @($filters | Where-Object { $linked -contains $_ })
    }
    @{ filtered = $filtered; gpos = $names; wmi_filters = $filters }
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

Function Get-GpoSubsetLinkPlan {
    <#
    .SYNOPSIS
    Plans the link changes on one container for an import limited to some GPOs
    (gpo_sync_import's gpo_names): the selected GPOs' links match the manifest's,
    and no other link is touched.

    .DESCRIPTION
    Current, Desired and the operations returned are Get-GpoLinkPlan's; Desired
    is the container's whole manifest list. Only links of Selected GPOs get an
    operation. Every other link keeps its enforced and enabled, its place
    relative to the others, and gets no operation or report, whatever
    RemoveUnmanaged says.

    The orders are absolute positions on the container, which also holds links
    the plan leaves alone, so each selected GPO the manifest links here is
    placed right after the link that precedes it in the manifest: after the
    previous selected one, or after the nearest earlier manifest link the
    container has (first when it has none). A GPO the target domain lacks, or
    one that isn't selected and isn't linked here, is skipped over. Placing
    them in manifest order converges in one pass: each placement only moves
    the selected link itself, and one placed earlier stays next to its
    predecessor. A selected GPO linked here that the manifest doesn't link
    here is 'remove' with RemoveUnmanaged, 'unmanaged' without, after the
    placements. GPO names compare case-insensitively.
    #>
    [CmdletBinding()]
    param (
        [object[]]$Current = @(),
        [object[]]$Desired = @(),
        [string[]]$Selected = @(),
        [bool]$RemoveUnmanaged
    )

    $picked = @($Selected | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    $desiredList = @($Desired | Where-Object { $null -ne $_ })
    $desiredKeys = @($desiredList | ForEach-Object { ([string]$_.gpo).ToLowerInvariant() })
    $work = New-Object System.Collections.ArrayList
    foreach ($l in @($Current | Where-Object { $null -ne $_ })) {
        [void]$work.Add(@{ name = [string]$l.name; enforced = [bool]$l.enforced; enabled = [bool]$l.enabled })
    }
    # The links the plan doesn't place, in their current order. Each selected
    # GPO lands after one of them (the latest the manifest puts before it) or
    # after the selected GPO placed before it.
    $fixed = @($work | ForEach-Object { $_.name.ToLowerInvariant() } |
            Where-Object { ($picked -notcontains $_) -or ($desiredKeys -notcontains $_) })

    $anchor = -1
    $previous = $null
    for ($i = 0; $i -lt $desiredList.Count; $i++) {
        if ($picked -notcontains $desiredKeys[$i]) { continue }
        $d = $desiredList[$i]
        $dName = [string]$d.gpo
        $dEnf = [bool]$d.enforced
        $dEna = [bool]$d.enabled
        $a = -1
        for ($k = 0; $k -lt $i; $k++) {
            $f = [array]::IndexOf($fixed, $desiredKeys[$k])
            if ($f -gt $a) { $a = $f }
        }
        # A later GPO's manifest predecessors include an earlier one's, so $a
        # never drops below $anchor: the same anchor means right after the
        # selected GPO placed before it.
        $after = $null
        if ($previous -and $a -eq $anchor) { $after = $previous }
        elseif ($a -ge 0) { $after = $fixed[$a] }
        $anchor = $a
        $previous = $desiredKeys[$i]

        $idx = -1
        $p = -1
        for ($j = 0; $j -lt $work.Count; $j++) {
            $key = ([string]$work[$j].name).ToLowerInvariant()
            if ($key -eq $desiredKeys[$i]) { $idx = $j }
            if ($after -and $key -eq $after) { $p = $j }
        }
        # Right after the link at $p; removing a link above it first shifts it up by one.
        $target = 0
        if ($after) {
            $target = $p + 1
            if ($idx -ge 0 -and $idx -lt $p) { $target = $p }
        }
        $op = [ordered]@{ action = ''; name = $dName; order = $target + 1; enforced = $dEnf; enabled = $dEna }
        if ($idx -lt 0) {
            $op.action = 'new'
            $op
            $work.Insert($target, @{ name = $dName; enforced = $dEnf; enabled = $dEna })
        }
        else {
            $cur = $work[$idx]
            if (($idx -ne $target) -or ($cur.enforced -ne $dEnf) -or ($cur.enabled -ne $dEna)) {
                $op.action = 'set'
                $op
                $work.RemoveAt($idx)
                $work.Insert($target, @{ name = $dName; enforced = $dEnf; enabled = $dEna })
            }
        }
    }
    foreach ($w in @($work)) {
        $key = ([string]$w.name).ToLowerInvariant()
        if (($picked -notcontains $key) -or ($desiredKeys -contains $key)) { continue }
        $action = 'unmanaged'
        if ($RemoveUnmanaged) { $action = 'remove' }
        [ordered]@{ action = $action; name = [string]$w.name; order = $null; enforced = $w.enforced; enabled = $w.enabled }
    }
}

$exportFunctions = @(
    'ConvertFrom-WmiFilterParm2'
    'ConvertTo-GpoExportRecordJson'
    'ConvertTo-GpoId'
    'ConvertTo-GpoImportRecordJson'
    'ConvertTo-LdapFilterValue'
    'ConvertTo-RelativeDn'
    'ConvertTo-SafeName'
    'ConvertTo-WmiFilterParm2'
    'Get-DeletedGpoEntry'
    'Get-DirContentHash'
    'Get-GpoBackupIndex'
    'Get-GpoCpasswordFile'
    'Get-GpoExportReason'
    'Get-GpoExportScope'
    'Get-GpoFolderName'
    'Get-GpoImportDecision'
    'Get-GpoImportKey'
    'Get-GpoImportReason'
    'Get-GpoImportScope'
    'Get-GpoLinkPlan'
    'Get-GpoLiveContentHash'
    'Get-GpoSubsetLinkPlan'
    'Get-GpoSysvolPath'
    'Get-NearestExistingDirectory'
    'Get-RelativeTrusteeName'
    'Get-StringHash'
    'Get-TrusteeEntry'
    'Get-YesNo'
    'New-ZipFromDirectory'
    'Read-GpoExportRecord'
    'Read-GpoImportRecord'
    'Resolve-GpoBackupName'
    'Resolve-GpoMigrationTablePath'
    'Test-Denied'
    'Test-GpoBackupFolder'
    'Test-GpoBackupInstance'
    'Write-Utf8File'
)
Export-ModuleMember -Function $exportFunctions
