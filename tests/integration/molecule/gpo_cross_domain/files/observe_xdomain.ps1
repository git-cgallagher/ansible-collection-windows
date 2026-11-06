# observe_xdomain.ps1 — what each matrix GPO holds, read from GPMC and
# SYSVOL, never from the modules under test.
#
# For each row (molecule.yml's lab_xd_rows) on this DC: the GPO's XML report
# (Get-GPOReport) plus every file of its SYSVOL folder, by relative path and
# by content (decoded as UTF-16LE and as UTF-8, so .inf, .ini, registry.pol
# and preference XML all read). In that text it looks for
#   the row's markers          did the setting land
#   the row's report_markers   does the report show it by name
#   src's names and SID        its NetBIOS "SRC\" prefix, DNS name, DC's
#                              host name and domain SID prefix
#   dst's names and SID        the same for dst, in the files only (a
#                              migration table's work)
# and reads the GPO's WMI filter and the trustees that may apply or edit it.
#
# The result is JSON text. With -SourceObsJson (this script's output on srcdc) and -WithTableJson
# (its output on dstdc after the import through the migration table), run on
# dstdc after the import without one, it also classifies each row:
#   pass                   lands, and nothing of src's is left even without a table
#   needs-migration-table  lands; src references survive without the table, none with it
#   not-migrated           lands; src references survive even with the table
#   not-carried            the setting, WMI filter or security filtering isn't on dst
#   not-seeded             the source GPO didn't hold the row (a fixture fault)

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Domain,
    [Parameter(Mandatory = $true)][string]$RowsJson,
    [Parameter(Mandatory = $true)][string]$SourceJson,
    [Parameter(Mandatory = $true)][string]$TargetJson,
    [string]$SourceObsJson = '',
    [string]$WithTableJson = ''
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy

# Windows PowerShell 5.1's ConvertFrom-Json writes a JSON array as one object;
# ForEach-Object unrolls it into the rows.
$rows = @($RowsJson | ConvertFrom-Json | ForEach-Object { $_ })
$pdc = (Get-ADDomain -Identity $Domain).PDCEmulator

function Get-DomainTerm {
    param([string]$Json)
    $d = $Json | ConvertFrom-Json
    [ordered]@{
        netbios = "$($d.netbios)\"
        dns = $d.dns
        host = $d.host
        sid = "$($d.sid)-"
    }
}

$terms = [ordered]@{ src = (Get-DomainTerm -Json $SourceJson); dst = (Get-DomainTerm -Json $TargetJson) }

function Get-Snippet {
    param([string]$Text, [int]$At, [int]$Length)
    $start = [Math]::Max(0, $At - 40)
    $end = [Math]::Min($Text.Length, $At + $Length + 40)
    ($Text.Substring($start, $end - $start) -replace '[\x00-\x1f]', ' ' -replace '\s+', ' ').Trim()
}

function Find-Term {
    # Where each term of one domain appears: the part (report or a file's
    # relative path) and a snippet around the first hit, three parts at most.
    param([System.Collections.Specialized.OrderedDictionary]$Corpus, [System.Collections.Specialized.OrderedDictionary]$Terms)
    $found = [ordered]@{}
    foreach ($key in $Terms.Keys) {
        $term = [string]$Terms[$key]
        if (-not $term) { continue }
        $hits = @()
        foreach ($part in $Corpus.Keys) {
            $text = $Corpus[$part]
            $at = $text.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase)
            if ($at -ge 0) { $hits += [ordered]@{ in = $part; near = (Get-Snippet -Text $text -At $at -Length $term.Length) } }
            if ($hits.Count -ge 3) { break }
        }
        if ($hits.Count -gt 0) { $found[$key] = @($hits) }
    }
    $found
}

function Get-RowObservation {
    param($Row)
    $obs = [ordered]@{
        name = $Row.name
        exists = $false
        lands = $false
        missing = @($Row.markers)
        renders = $null
        src_refs = [ordered]@{}
        dst_refs = [ordered]@{}
        wmi_filter = $null
        apply = @()
        edit = @()
        files = @()
    }
    $gpo = Get-GPO -All -Domain $Domain -Server $pdc | Where-Object { $_.DisplayName -eq $Row.name }
    if (-not $gpo) { return $obs }
    $obs.exists = $true

    $report = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Domain $Domain -Server $pdc
    $corpus = [ordered]@{ report = [string]$report }
    $folder = Join-Path $env:SystemRoot ('SYSVOL\domain\Policies\{' + $gpo.Id.ToString().ToUpperInvariant() + '}')
    foreach ($file in @(Get-ChildItem -LiteralPath $folder -Recurse -File | Sort-Object -Property FullName)) {
        $relative = $file.FullName.Substring($folder.Length + 1)
        $obs.files += $relative
        $text = $relative
        if ($file.Length -le 1MB) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $text += "`n" + [System.Text.Encoding]::Unicode.GetString($bytes) + "`n" + [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        $corpus[$relative] = $text
    }
    $all = ($corpus.Values -join "`n")
    $obs.missing = @($Row.markers | Where-Object { $all.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 })
    $obs.lands = $obs.missing.Count -eq 0
    if ($Row.PSObject.Properties['report_markers']) {
        $unnamed = @($Row.report_markers | Where-Object {
                $corpus.report.IndexOf([string]$_, [System.StringComparison]::OrdinalIgnoreCase) -lt 0
            })
        $obs.renders = $unnamed.Count -eq 0
    }
    $obs.src_refs = Find-Term -Corpus $corpus -Terms $terms.src
    # dst's own report names dst (its domain, its trustees), so dst references
    # count only in the GPO's files: what the migration table wrote.
    $files = [ordered]@{}
    foreach ($part in $corpus.Keys) { if ($part -ne 'report') { $files[$part] = $corpus[$part] } }
    $obs.dst_refs = Find-Term -Corpus $files -Terms $terms.dst

    if ($gpo.WmiFilter) { $obs.wmi_filter = $gpo.WmiFilter.Name }
    foreach ($perm in @(Get-GPPermission -Guid $gpo.Id -All -Domain $Domain -Server $pdc)) {
        # Domain-relative, so src's and dst's trustees compare by name.
        $level = [string]$perm.Permission
        $trustee = ([string]$perm.Trustee.Name).Split('\')[-1]
        if ($level -eq 'GpoApply') { $obs.apply += $trustee }
        if ($level -like 'GpoEdit*') { $obs.edit += $trustee }
    }
    $obs.apply = @($obs.apply | Sort-Object)
    $obs.edit = @($obs.edit | Sort-Object)
    $obs
}

function Get-RowClass {
    param($Row, $Source, $WithTable, $Without)
    if (-not $Source.lands) { return 'not-seeded' }
    if ($Row.kind -eq 'wmi') {
        if ($WithTable.wmi_filter -or $Without.wmi_filter) { return 'carried' }
        return 'not-carried'
    }
    if ($Row.kind -eq 'filtering') {
        if ((@($WithTable.apply) -join ',') -eq (@($Source.apply) -join ',')) { return 'carried' }
        return 'not-carried'
    }
    if (-not ($WithTable.lands -and $Without.lands)) { return 'not-carried' }
    if (@($Without.src_refs.PSObject.Properties).Count -eq 0) { return 'pass' }
    if (@($WithTable.src_refs.PSObject.Properties).Count -eq 0) { return 'needs-migration-table' }
    'not-migrated'
}

$observed = [ordered]@{}
foreach ($row in $rows) { $observed[[string]$row.name] = Get-RowObservation -Row $row }

$result = [ordered]@{ domain = $Domain; rows = $observed }
if ($SourceObsJson -and $WithTableJson) {
    # Round-tripped through JSON like the other two, so all three compare alike.
    $without = ($result | ConvertTo-Json -Depth 8 | ConvertFrom-Json).rows
    $source = ($SourceObsJson | ConvertFrom-Json).rows
    $withTable = ($WithTableJson | ConvertFrom-Json).rows
    $matrix = [ordered]@{}
    foreach ($row in $rows) {
        $name = [string]$row.name
        $matrix[$name] = Get-RowClass -Row $row -Source $source.$name -WithTable $withTable.$name -Without $without.$name
    }
    $result.matrix = $matrix
}

# As JSON text, which callers from_json: the readings are nested deeper than
# Ansible's own serialization keeps.
$Ansible.Changed = $false
$Ansible.Result = $result | ConvertTo-Json -Depth 10 -Compress
