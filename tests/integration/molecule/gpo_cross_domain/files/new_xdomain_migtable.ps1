# new_xdomain_migtable.ps1 — on srcdc: the migration table a src -> dst move
# would use. GPMC itself fills it from the named GPOs (so it lists exactly the
# principals and UNC paths GPMC knows how to translate); each entry that
# names src (its NetBIOS name, DNS name or server) is then pointed at the dst
# equivalent: same group name, dst's server. Everything else stays "same as
# source". The entries, as GPMC listed them, are part of the result, because
# what GPMC finds is half of the cross-domain story.

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

# Longest first, so the DNS name wins over the NetBIOS name it starts with.
$swaps = @(
    @($src.dns, $dst.dns),
    @("$($src.netbios)\", "$($dst.netbios)\"),
    @($src.host, $dst.host)
)
$entries = @()
foreach ($entry in @($table.GetEntries())) {
    $source = [string]$entry.Source
    $destination = $source
    foreach ($swap in $swaps) {
        $destination = $destination -replace [regex]::Escape($swap[0]), $swap[1]
    }
    $mapped = $destination -ne $source
    if ($mapped) { [void]$table.UpdateDestination($source, $destination) }
    $entries += [ordered]@{ type = [string]$entry.EntryType; source = $source; destination = $(if ($mapped) { $destination } else { $null }) }
}
$folder = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
$table.Save($Path)

$Ansible.Changed = $true
$Ansible.Result = [ordered]@{ path = $Path; entries = @($entries) }
