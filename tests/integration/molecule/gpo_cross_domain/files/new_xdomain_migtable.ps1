# new_xdomain_migtable.ps1 — on srcdc: the migration table a src -> dst move
# would use. GPMC itself fills it from the named GPOs (so it lists exactly the
# principals and UNC paths GPMC knows how to translate). Then:
#   - each src domain principal (GPMC writes them as name@src-dns) maps "by
#     relative name": to the same name in whichever domain imports it, so one
#     table serves every target domain whose groups have the same names;
#   - each UNC path naming src's server is pointed at dst's server.
# Everything else stays "same as source". UpdateDestination sets explicit
# destinations, so the relative-name mappings are written into the saved XML
# (the Migration Table Editor's "Map by relative name"). The entries, as GPMC
# listed them, are part of the result, because what GPMC finds is half of the
# cross-domain story.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Domain,
    [Parameter(Mandatory = $true)][string[]]$GpoNames,
    [Parameter(Mandatory = $true)][string]$SourceJson,
    [Parameter(Mandatory = $true)][string]$TargetJson,
    [Parameter(Mandatory = $true)][string]$Path
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy

$src = $SourceJson | ConvertFrom-Json
$dst = $TargetJson | ConvertFrom-Json
$gpm = New-Object -ComObject GPMgmt.GPM
$constants = $gpm.GetConstants()
$gpmDomain = $gpm.GetDomain($Domain, '', $constants.UseAnyDC)
$table = $gpm.CreateMigrationTable()
foreach ($name in $GpoNames) {
    $gpo = Get-GPO -Name $name -Domain $Domain
    [void]$table.Add(0, $gpmDomain.GetGPO('{' + $gpo.Id.ToString() + '}'))
}

# UNC paths: src's server and domain names to dst's. Longest first, so the DNS
# name wins over the host name inside it.
$swaps = @(
    @($src.dns, $dst.dns),
    @($src.host, $dst.host)
)
$principalSuffix = '@' + $src.dns
$entries = @()
foreach ($entry in @($table.GetEntries())) {
    $source = [string]$entry.Source
    $option = 'same_as_source'
    $destination = $null
    $refused = $null
    if ($source.EndsWith($principalSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        $option = 'by_relative_name'
    }
    elseif ($source.StartsWith('\\')) {
        $mapped = $source
        foreach ($swap in $swaps) {
            $mapped = $mapped -replace [regex]::Escape($swap[0]), $swap[1]
        }
        if ($mapped -ne $source) {
            # GPMC refusing a destination is a finding, not a failure.
            try {
                [void]$table.UpdateDestination($source, $mapped)
                $option = 'set'
                $destination = $mapped
            }
            catch {
                $refused = $_.Exception.Message
            }
        }
    }
    $entries += [ordered]@{
        type = [string]$entry.EntryType
        source = $source
        option = $option
        destination = $destination
        refused = $refused
    }
}
$folder = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
$table.Save($Path)

# "By relative name" in the saved XML: <DestinationByRelativeName /> in place
# of the mapping's <DestinationSameAsSource />.
$relative = @($entries | Where-Object { $_.option -eq 'by_relative_name' } | ForEach-Object { $_.source })
$xml = New-Object System.Xml.XmlDocument
$xml.Load($Path)
$ns = $xml.DocumentElement.NamespaceURI
foreach ($mapping in @($xml.DocumentElement.ChildNodes | Where-Object { $_.LocalName -eq 'Mapping' })) {
    $sourceNode = @($mapping.ChildNodes | Where-Object { $_.LocalName -eq 'Source' })[0]
    if ($relative -notcontains $sourceNode.InnerText) { continue }
    foreach ($old in @($mapping.ChildNodes | Where-Object { $_.LocalName -like 'Destination*' })) {
        [void]$mapping.RemoveChild($old)
    }
    [void]$mapping.AppendChild($xml.CreateElement('DestinationByRelativeName', $ns))
}
$xml.Save($Path)

$Ansible.Changed = $true
$Ansible.Result = [ordered]@{ path = $Path; entries = @($entries); xml = [System.IO.File]::ReadAllText($Path) }
