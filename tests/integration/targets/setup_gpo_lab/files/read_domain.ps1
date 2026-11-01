# read_domain.ps1 — the GPO targets' view of the lab domain, read through
# GPMC and AD directly (never through the modules under test).
#
# Returns:
#   domain, pdc, root_dn, netbios
#   topology   what gpo_export records and gpo_import converges, free of
#              anything a re-import changes: every GPO's status, WMI filter and
#              Apply trustees (domain-relative, sorted); every WMI filter's
#              description, namespace and query; every SOM's (the root and
#              every OU, relative to the root, '' = the root) block-inheritance
#              and ordered links. No GUIDs, no versions: a GPO deleted and
#              recreated from its backup compares equal.
#   versions   each GPO's AD version number, which Import-GPO bumps: equal
#              before and after a run that must not have touched the domain.
#   settings   the fixture scenarios' settings, parsed from SYSVOL on the PDC:
#              the password GPO's minimum length and lockout threshold, the
#              servers' GPP local-Administrators members and the workstations'
#              Restricted Groups members (SIDs, sorted). $null when the GPO or
#              the file is missing.
#   group_sids the fixture groups' SIDs, for the migration-table checks.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Domain,
    [Parameter(Mandatory = $true)][string]$FixtureJson
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy, ActiveDirectory

$fx = $FixtureJson | ConvertFrom-Json
$adDomain = Get-ADDomain -Identity $Domain
$pdc = $adDomain.PDCEmulator
$rootDn = $adDomain.DistinguishedName
$netbios = $adDomain.NetBIOSName
$somContainer = "CN=SOM,CN=WMIPolicy,CN=System,$rootDn"
$policies = "\\$pdc\SYSVOL\$Domain\Policies"

function Get-RelativeName {
    param([string]$Name)
    if ($Name -and $Name.Contains('\')) {
        $parts = $Name.Split('\', 2)
        if ($parts[0] -eq $netbios) { return $parts[1] }
    }
    $Name
}

function ConvertTo-RelativeDn {
    param([string]$Dn)
    if ($Dn -ieq $rootDn) { return '' }
    $Dn.Substring(0, $Dn.Length - $rootDn.Length - 1)
}

function ConvertFrom-Parm2 {
    # msWMI-Parm2 single-query form: "1;3;<nsLen>;<qLen>;WQL;<namespace>;<query>;"
    param([string]$Parm2)
    try {
        $i = $Parm2.IndexOf(';')
        if ([int]$Parm2.Substring(0, $i) -ne 1) { return $null }
        $parts = $Parm2.Substring($i + 1).Split(';', 4)
        $nsLen = [int]$parts[1]
        $qLen = [int]$parts[2]
        $tail = $parts[3]
        $tail = $tail.Substring($tail.IndexOf(';') + 1)
        @{ namespace = $tail.Substring(0, $nsLen); query = $tail.Substring($nsLen + 1, $qLen) }
    }
    catch { $null }
}

function Get-GpoFileText {
    param($Gpo, [string]$RelativePath)
    $file = Join-Path $policies ('{' + $Gpo.Id.ToString().ToUpperInvariant() + '}\' + $RelativePath)
    if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw } else { $null }
}

function Get-InfValue {
    param([string]$Text, [string]$Key)
    if ($Text -and $Text -match ('(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*(\S+)')) { [int]$Matches[1] } else { $null }
}

# --- GPOs ---------------------------------------------------------------------------
$gpos = [ordered]@{}
$versions = [ordered]@{}
$byName = @{}
foreach ($gpo in @(Get-GPO -All -Domain $Domain -Server $pdc | Sort-Object DisplayName)) {
    $byName[$gpo.DisplayName] = $gpo
    $apply = @(
        Get-GPPermission -Guid $gpo.Id -All -Domain $Domain -Server $pdc |
            Where-Object { [string]$_.Permission -eq 'GpoApply' -and -not ($_.PSObject.Properties['Denied'] -and $_.Denied) } |
            ForEach-Object { Get-RelativeName -Name ([string]$_.Trustee.Name) } | Sort-Object
    )
    $wmi = $null
    if ($gpo.WmiFilter) { $wmi = $gpo.WmiFilter.Name }
    $gpos[$gpo.DisplayName] = [ordered]@{
        status = $gpo.GpoStatus.ToString()
        wmi_filter = $wmi
        apply_to = $apply
    }
    $versions[$gpo.DisplayName] = [int](Get-ADObject -Identity ('CN={' + $gpo.Id.ToString().ToUpperInvariant() + "},CN=Policies,CN=System,$rootDn") `
            -Properties versionNumber -Server $pdc).versionNumber
}

# --- WMI filters ---------------------------------------------------------------------
$filters = [ordered]@{}
foreach ($f in @(Get-ADObject -SearchBase $somContainer -SearchScope OneLevel -Server $pdc `
            -LDAPFilter '(objectClass=msWMI-Som)' -Properties msWMI-Name, msWMI-Parm1, msWMI-Parm2 |
            Sort-Object { [string]$_.'msWMI-Name' })) {
    $parsed = ConvertFrom-Parm2 -Parm2 ([string]$f.'msWMI-Parm2')
    $entry = [ordered]@{ description = [string]$f.'msWMI-Parm1'; namespace = $null; query = $null }
    if ($parsed) {
        $entry.namespace = $parsed.namespace
        $entry.query = $parsed.query
    }
    $filters[[string]$f.'msWMI-Name'] = $entry
}

# --- SOMs: the root and every OU --------------------------------------------------------
$soms = [ordered]@{}
$somDns = @($rootDn) + @(
    Get-ADOrganizationalUnit -Filter * -SearchBase $rootDn -Server $pdc |
        Select-Object -ExpandProperty DistinguishedName | Sort-Object
)
foreach ($dn in $somDns) {
    $inh = Get-GPInheritance -Target $dn -Domain $Domain -Server $pdc
    $soms[(ConvertTo-RelativeDn -Dn $dn)] = [ordered]@{
        block_inheritance = [bool]$inh.GpoInheritanceBlocked
        links = @($inh.GpoLinks | Sort-Object Order | ForEach-Object {
                [ordered]@{ gpo = $_.DisplayName; enforced = [bool]$_.Enforced; enabled = [bool]$_.Enabled }
            })
    }
}

# --- the fixture scenarios' settings -----------------------------------------------------
$secEditInf = 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
$settings = [ordered]@{
    password_min_length = $null
    password_lockout_threshold = $null
    server_admins_members = $null
    ws_admins_members = $null
}
if ($byName.ContainsKey($fx.gpo_password)) {
    $text = Get-GpoFileText -Gpo $byName[$fx.gpo_password] -RelativePath $secEditInf
    $settings.password_min_length = Get-InfValue -Text $text -Key 'MinimumPasswordLength'
    $settings.password_lockout_threshold = Get-InfValue -Text $text -Key 'LockoutBadCount'
}
if ($byName.ContainsKey($fx.gpo_server_admins)) {
    $text = Get-GpoFileText -Gpo $byName[$fx.gpo_server_admins] -RelativePath 'Machine\Preferences\Groups\Groups.xml'
    if ($text) {
        $settings.server_admins_members = @(([xml]$text).Groups.Group.Properties.Members.Member |
                ForEach-Object { '{0} {1} {2}' -f $_.action, $_.name, $_.sid } | Sort-Object)
    }
}
if ($byName.ContainsKey($fx.gpo_ws_admins)) {
    $text = Get-GpoFileText -Gpo $byName[$fx.gpo_ws_admins] -RelativePath $secEditInf
    if ($text) {
        $line = @($text -split "`r?`n" | Where-Object { $_.StartsWith('*S-1-5-32-544__Members') }) -join ''
        $settings.ws_admins_members = @(($line -split '=', 2)[-1] -split ',' |
                ForEach-Object { $_.Trim().TrimStart('*') } | Where-Object { $_ } | Sort-Object)
    }
}

$groupSids = [ordered]@{}
foreach ($g in @($fx.group, $fx.server_admins_group, $fx.ws_admins_group, $fx.helpdesk_group)) {
    try {
        $groupSids[$g] = (Get-ADGroup -Identity $g -Server $pdc).SID.Value
    }
    catch {
        $groupSids[$g] = $null
    }
}

$Ansible.Changed = $false
$Ansible.Result = [ordered]@{
    domain = $Domain
    pdc = $pdc
    root_dn = $rootDn
    netbios = $netbios
    topology = [ordered]@{ gpos = $gpos; wmi_filters = $filters; soms = $soms }
    versions = $versions
    settings = $settings
    group_sids = $groupSids
}
