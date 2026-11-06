# xdomain_fixture.ps1 — the gpo_cross_domain scenario's two domains.
#
#   -Action Source  on srcdc: the groups, a custom ADMX in the central store,
#                   a WMI filter and the content matrix, one GPO per row
#                   (molecule.yml's lab_xd_rows), each holding settings that
#                   name src's groups, SIDs, server and domain where the
#                   setting type allows it.
#   -Action Target  on dstdc: the same-named groups, which the migration
#                   table maps src's to.
#
# Wherever GPMC has a cmdlet (registry policy, preferences registry items,
# firewall rules, permissions, WMI filter linking) the fixture uses it.
# Settings GPMC can't author (security templates, scripts, folder
# redirection, preference XML) are written the way their editors write them,
# with the GPO's client-side extensions and version updated to match, and
# prepare.yml checks every row shows in the source GPO's own report before
# anything is exported, so a row that's missing on dst is the move's doing.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Source', 'Target')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Domain,
    [Parameter(Mandatory = $true)][string]$GroupsJson,
    [string]$WmiFilter = ''
)

$ErrorActionPreference = 'Stop'
Import-Module GroupPolicy, ActiveDirectory

$groupNames = $GroupsJson | ConvertFrom-Json
$adDomain = Get-ADDomain -Identity $Domain
$pdc = $adDomain.PDCEmulator
$rootDn = $adDomain.DistinguishedName
$netbios = $adDomain.NetBIOSName
$hostName = $env:COMPUTERNAME
$somContainer = "CN=SOM,CN=WMIPolicy,CN=System,$rootDn"
$done = New-Object System.Collections.ArrayList

# Client-side extension lists ([CSE}{tool]), as the editors write them.
$cse = @{
    security = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    scripts = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
    redirection = '[{25537BA6-77A8-11D2-9B6C-0000F8080861}{88E729D6-BDC1-11D1-BD2A-00C04FB9603F}]'
    drives = '[{00000000-0000-0000-0000-000000000000}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]' +
    '[{5794DAFD-BE60-433F-88A2-1A31939AC01F}{2EA1A81B-48E5-45E9-8BB7-A6E3AC170006}]'
    groups = '[{00000000-0000-0000-0000-000000000000}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]' +
    '[{17D89FEC-5C44-4972-B12D-241CAEF74509}{79F92669-4224-476C-9C5C-6EFB4D87DF4A}]'
    registry = '[{00000000-0000-0000-0000-000000000000}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]' +
    '[{B087BE9D-ED37-454F-AF9C-04291E351182}{BEE07A6A-EC9F-4659-B8C9-0B1937907C83}]'
}

function Get-GpoOrNew {
    param([string]$Name)
    $gpo = Get-GPO -All -Domain $Domain -Server $pdc | Where-Object { $_.DisplayName -eq $Name }
    if (-not $gpo) {
        $gpo = New-GPO -Name $Name -Domain $Domain -Server $pdc
        [void]$done.Add("GPO $Name")
    }
    $gpo
}

function Get-GpoDn {
    param([Guid]$Id)
    'CN={' + $Id.ToString().ToUpperInvariant() + '},CN=Policies,CN=System,' + $rootDn
}

function Get-GpoFolder {
    param([Guid]$Id)
    Join-Path $env:SystemRoot ('SYSVOL\domain\Policies\{' + $Id.ToString().ToUpperInvariant() + '}')
}

function Get-GroupSid {
    param([string]$Name)
    (Get-ADGroup -Identity $Name -Server $pdc).SID.Value
}

function New-ItemUid {
    '{' + [guid]::NewGuid().ToString().ToUpperInvariant() + '}'
}

function Get-Stamp {
    (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
}

function Write-TextFile {
    # The files' encodings as their editors write them: Unicode (UTF-16LE with
    # a BOM) for .inf/.ini, UTF-8 without a BOM for preference XML.
    param([string]$Path, [string]$Text, [ValidateSet('Unicode', 'Utf8')][string]$Encoding)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Encoding -eq 'Unicode') { $enc = [System.Text.Encoding]::Unicode } else { $enc = New-Object System.Text.UTF8Encoding $false }
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Update-GpoVersion {
    # After writing a GPO's SYSVOL files directly: register the extensions
    # that process them and bump the half's version in AD and GPT.INI, as the
    # editors do. AD's versionNumber is user << 16 | computer. LDAP, not AD
    # Web Services, which refuses writes to a GPO's AD object (AGENTS.md).
    param([Guid]$GpoId, [ValidateSet('Machine', 'User')][string]$Half, [string]$ExtensionNames)
    $dn = Get-GpoDn -Id $GpoId
    $entry = New-Object -TypeName System.DirectoryServices.DirectoryEntry -ArgumentList "LDAP://$pdc/$dn"
    try {
        $version = [int]$entry.Properties['versionNumber'].Value
        if ($Half -eq 'Machine') {
            $version += 1
            $entry.Properties['gPCMachineExtensionNames'].Value = $ExtensionNames
        }
        else {
            $version += 65536
            $entry.Properties['gPCUserExtensionNames'].Value = $ExtensionNames
        }
        $entry.Properties['versionNumber'].Value = $version
        $entry.CommitChanges()
    }
    finally { $entry.Dispose() }
    [System.IO.File]::WriteAllText((Join-Path (Get-GpoFolder -Id $GpoId) 'GPT.INI'), "[General]`r`nVersion=$version`r`n",
        [System.Text.Encoding]::ASCII)
}

function Set-SecurityTemplate {
    param([Guid]$GpoId, [string[]]$Body)
    $path = Join-Path (Get-GpoFolder -Id $GpoId) 'Machine\Microsoft\Windows NT\SecEdit\GptTmpl.inf'
    $inf = (@('[Unicode]', 'Unicode=yes') + $Body + @('[Version]', 'signature="$CHICAGO$"', 'Revision=1', '')) -join "`r`n"
    Write-TextFile -Path $path -Text $inf -Encoding Unicode
    Update-GpoVersion -GpoId $GpoId -Half Machine -ExtensionNames $cse.security
}

function New-Group {
    param([string]$Name)
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -Server $pdc)) {
        New-ADGroup -Name $Name -GroupScope Global -GroupCategory Security -Path "CN=Users,$rootDn" -Server $pdc
        [void]$done.Add("group $Name")
    }
}

function Set-CentralStore {
    # A central store makes GPMC read every ADMX from it, so it starts as a
    # copy of the local store; then the lab's own ADMX, which dst never gets.
    $store = Join-Path $env:SystemRoot 'SYSVOL\domain\Policies\PolicyDefinitions'
    if (-not (Test-Path -LiteralPath (Join-Path $store 'windows.admx'))) {
        Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'PolicyDefinitions') -Destination $store -Recurse -Force
        [void]$done.Add('central store')
    }
    $ns = 'http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions'
    $admx = @"
<?xml version="1.0" encoding="utf-8"?>
<policyDefinitions revision="1.0" schemaVersion="1.0" xmlns="$ns">
  <policyNamespaces>
    <target prefix="xdlab" namespace="GitCgallagher.Policies.XdLab" />
    <using prefix="windows" namespace="Microsoft.Policies.Windows" />
  </policyNamespaces>
  <resources minRequiredRevision="1.0" />
  <categories>
    <category name="XdLab" displayName="`$(string.XdLab)" />
  </categories>
  <policies>
    <policy name="XdCustomSetting" class="Machine" displayName="`$(string.XdCustomSetting)"
        explainText="`$(string.XdCustomSetting_Help)" key="Software\Policies\XdLab" valueName="XdCustomSetting">
      <parentCategory ref="XdLab" />
      <supportedOn ref="windows:SUPPORTED_WindowsVista" />
      <enabledValue><decimal value="1" /></enabledValue>
      <disabledValue><decimal value="0" /></disabledValue>
    </policy>
  </policies>
</policyDefinitions>
"@
    $adml = @"
<?xml version="1.0" encoding="utf-8"?>
<policyDefinitionResources revision="1.0" schemaVersion="1.0" xmlns="$ns">
  <displayName>XD lab</displayName>
  <description>The gpo_cross_domain scenario's custom ADMX.</description>
  <resources>
    <stringTable>
      <string id="XdLab">XD lab</string>
      <string id="XdCustomSetting">XD custom ADMX setting</string>
      <string id="XdCustomSetting_Help">A lab-only policy that only src's central store defines.</string>
    </stringTable>
  </resources>
</policyDefinitionResources>
"@
    Write-TextFile -Path (Join-Path $store 'XdLab.admx') -Text $admx -Encoding Utf8
    Write-TextFile -Path (Join-Path $store 'en-US\XdLab.adml') -Text $adml -Encoding Utf8
}

function Get-WmiFilterObject {
    param([string]$Name)
    Get-ADObject -SearchBase $somContainer -SearchScope OneLevel -Server $pdc `
        -LDAPFilter "(&(objectClass=msWMI-Som)(msWMI-Name=$Name))"
}

function Set-WmiFilterLink {
    # The filter, encoded the way GPMC writes msWMI-Parm2, linked through GPMC.
    param([Guid]$GpoId, [string]$Name)
    if (-not (Get-WmiFilterObject -Name $Name)) {
        $namespace = 'root\CIMv2'
        $query = 'SELECT * FROM Win32_OperatingSystem WHERE ProductType > 1'
        $id = New-ItemUid
        $now = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff-000')
        New-ADObject -Type 'msWMI-Som' -Name $id -Path $somContainer -Server $pdc -OtherAttributes @{
            'msWMI-Name' = $Name
            'msWMI-Parm1' = 'Servers and domain controllers'
            'msWMI-Parm2' = ('1;3;{0};{1};WQL;{2};{3};' -f $namespace.Length, $query.Length, $namespace, $query)
            'msWMI-ID' = $id
            'msWMI-Author' = 'gpo_cross_domain fixture'
            'msWMI-ChangeDate' = $now
            'msWMI-CreationDate' = $now
        }
        [void]$done.Add("WMI filter $Name")
    }
    $gpDomain = New-Object -TypeName Microsoft.GroupPolicy.GPDomain -ArgumentList $Domain, $pdc
    $criteria = New-Object -TypeName Microsoft.GroupPolicy.GPSearchCriteria
    $filter = $gpDomain.SearchWmiFilters($criteria) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $filter) { throw "GPMC cannot see WMI filter '$Name'" }
    $gpo = Get-GPO -Guid $GpoId -Domain $Domain -Server $pdc
    $gpo.WmiFilter = $filter
}

function Invoke-Source {
    foreach ($name in $groupNames.PSObject.Properties.Value) { New-Group -Name $name }
    $admins = $groupNames.admins
    $adminsSid = Get-GroupSid -Name $admins
    $staffSid = Get-GroupSid -Name $groupNames.staff
    $fqdnHost = "$hostName.$Domain"
    Set-CentralStore

    # Admin Templates (registry.pol, a policy the local and central stores define).
    $gpo = Get-GpoOrNew -Name 'XD - Admin Templates'
    Set-GPRegistryValue -Guid $gpo.Id -Domain $Domain -Server $pdc -Key 'HKLM\Software\Policies\Microsoft\Windows NT\Terminal Services' `
        -ValueName 'fDenyTSConnections' -Type DWord -Value 0 | Out-Null

    # Security settings without a principal: password, audit, security options.
    $gpo = Get-GpoOrNew -Name 'XD - Security Settings'
    Set-SecurityTemplate -GpoId $gpo.Id -Body @(
        '[System Access]', 'MinimumPasswordLength = 14', 'PasswordComplexity = 1'
        '[Event Audit]', 'AuditLogonEvents = 3', 'AuditAccountLogon = 3'
        '[Registry Values]', 'MACHINE\System\CurrentControlSet\Control\Lsa\LimitBlankPasswordUse=4,1'
    )

    # Security settings with src principals (by SID, as the editor stores them).
    $gpo = Get-GpoOrNew -Name 'XD - User Rights'
    Set-SecurityTemplate -GpoId $gpo.Id -Body @(
        '[Privilege Rights]', "SeRemoteInteractiveLogonRight = *S-1-5-32-544,*$adminsSid"
    )
    $gpo = Get-GpoOrNew -Name 'XD - Restricted Groups'
    Set-SecurityTemplate -GpoId $gpo.Id -Body @(
        '[Group Membership]', '*S-1-5-32-544__Memberof =', "*S-1-5-32-544__Members = *$adminsSid"
    )
    $gpo = Get-GpoOrNew -Name 'XD - File ACL'
    Set-SecurityTemplate -GpoId $gpo.Id -Body @(
        '[File Security]', ('"%SystemDrive%\XdLabFiles",0,"D:PAR(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;{0})"' -f $adminsSid)
    )
    $gpo = Get-GpoOrNew -Name 'XD - Registry ACL'
    Set-SecurityTemplate -GpoId $gpo.Id -Body @(
        '[Registry Keys]', ('"MACHINE\SOFTWARE\XdLabKey",0,"D:PAR(A;CI;KA;;;BA)(A;CI;KR;;;{0})"' -f $staffSid)
    )

    # Startup scripts: one stored in the GPO, one on a src UNC path.
    $gpo = Get-GpoOrNew -Name 'XD - Startup Scripts'
    $scripts = Join-Path (Get-GpoFolder -Id $gpo.Id) 'Machine\Scripts'
    Write-TextFile -Path (Join-Path $scripts 'Startup\startup-local.cmd') -Text "@echo off`r`nrem gpo_cross_domain`r`n" -Encoding Utf8
    Write-TextFile -Path (Join-Path $scripts 'scripts.ini') -Encoding Unicode -Text (@(
            '', '[Startup]', '0CmdLine=startup-local.cmd', '0Parameters=',
            "1CmdLine=\\$hostName\XdScripts\startup-unc.cmd", '1Parameters=', ''
        ) -join "`r`n")
    Update-GpoVersion -GpoId $gpo.Id -Half Machine -ExtensionNames $cse.scripts

    # Folder redirection: Documents to a src UNC path, for everyone (S-1-1-0).
    $gpo = Get-GpoOrNew -Name 'XD - Folder Redirection'
    Write-TextFile -Path (Join-Path (Get-GpoFolder -Id $gpo.Id) 'User\Documents & Settings\fdeploy.ini') -Encoding Unicode -Text (@(
            '[FolderStatus]', 'My Documents=11', '[My Documents]', "s-1-1-0=\\$hostName\XdRedirect\%USERNAME%\My Documents", ''
        ) -join "`r`n")
    Update-GpoVersion -GpoId $gpo.Id -Half User -ExtensionNames $cse.redirection

    # Group Policy Preferences.
    $gpo = Get-GpoOrNew -Name 'XD - GPP Registry'
    Set-GPPrefRegistryValue -Guid $gpo.Id -Domain $Domain -Server $pdc -Context Computer -Action Update `
        -Key 'HKLM\Software\XdLab' -ValueName 'XdGppRegistry' -Type String -Value 'gpp' | Out-Null

    $gpo = Get-GpoOrNew -Name 'XD - GPP Drive Map'
    Write-TextFile -Path (Join-Path (Get-GpoFolder -Id $gpo.Id) 'User\Preferences\Drives\Drives.xml') -Encoding Utf8 -Text @"
<?xml version="1.0" encoding="utf-8"?>
<Drives clsid="{8FDDCC1A-0C3C-43cd-A6B4-71A6DF20DA8C}">
  <Drive clsid="{935D1B74-9CB8-4e3c-9914-7DD559B7A417}" name="X:" status="X:" image="2" changed="$(Get-Stamp)" uid="$(New-ItemUid)">
    <Properties action="U" thisDrive="NOCHANGE" allDrives="NOCHANGE" userName="" path="\\$fqdnHost\XdDrive" label="XdDrive"
      persistent="1" useLetter="1" letter="X"/>
  </Drive>
</Drives>
"@
    Update-GpoVersion -GpoId $gpo.Id -Half User -ExtensionNames $cse.drives

    $gpo = Get-GpoOrNew -Name 'XD - GPP Local Group'
    Write-TextFile -Path (Join-Path (Get-GpoFolder -Id $gpo.Id) 'Machine\Preferences\Groups\Groups.xml') -Encoding Utf8 -Text @"
<?xml version="1.0" encoding="utf-8"?>
<Groups clsid="{3125E937-EB16-4b4c-9934-544FC6D24D26}">
  <Group clsid="{6D4A79E4-529C-4481-ABD0-F5BD7EA93BA7}" name="Administrators (built-in)" image="2" changed="$(Get-Stamp)"
    uid="$(New-ItemUid)">
    <Properties action="U" newName="" description="" deleteAllUsers="0" deleteAllGroups="0" removeAccounts="0"
      groupSid="S-1-5-32-544" groupName="Administrators (built-in)">
      <Members><Member name="$netbios\$admins" action="ADD" sid="$adminsSid"/></Members>
    </Properties>
  </Group>
</Groups>
"@
    Update-GpoVersion -GpoId $gpo.Id -Half Machine -ExtensionNames $cse.groups

    $gpo = Get-GpoOrNew -Name 'XD - GPP Targeting'
    Write-TextFile -Path (Join-Path (Get-GpoFolder -Id $gpo.Id) 'Machine\Preferences\Registry\Registry.xml') -Encoding Utf8 -Text @"
<?xml version="1.0" encoding="utf-8"?>
<RegistrySettings clsid="{A3CCFC41-DFDB-43a5-8D26-0FE8B954DA51}">
  <Registry clsid="{9CD4B2F4-923D-47f5-A062-E897DD1DAD50}" name="XdTargeted" status="XdTargeted" image="12" changed="$(Get-Stamp)"
    uid="$(New-ItemUid)" bypassErrors="1">
    <Properties action="U" displayDecimal="1" default="0" hive="HKEY_LOCAL_MACHINE" key="SOFTWARE\XdLab" name="XdTargeted"
      type="REG_DWORD" value="00000001"/>
    <Filters>
      <FilterGroup bool="AND" not="0" name="$netbios\$($groupNames.staff)" sid="$staffSid" userContext="0" primaryGroup="0"
        localGroup="0"/>
    </Filters>
  </Registry>
</RegistrySettings>
"@
    Update-GpoVersion -GpoId $gpo.Id -Half Machine -ExtensionNames $cse.registry

    # A policy from the custom ADMX (registry.pol; the ADMX is src's only).
    $gpo = Get-GpoOrNew -Name 'XD - Custom ADMX'
    Set-GPRegistryValue -Guid $gpo.Id -Domain $Domain -Server $pdc -Key 'HKLM\Software\Policies\XdLab' `
        -ValueName 'XdCustomSetting' -Type DWord -Value 1 | Out-Null

    # Windows Firewall with Advanced Security: a rule, which the firewall
    # cmdlets store in the GPO's registry.pol (not an AD-stored extension).
    $gpo = Get-GpoOrNew -Name 'XD - Firewall Rule'
    $store = "$Domain\XD - Firewall Rule"
    if (-not (Get-NetFirewallRule -PolicyStore $store -DisplayName 'XdFirewallRule' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -PolicyStore $store -DisplayName 'XdFirewallRule' -Direction Inbound -Protocol TCP `
            -LocalPort 8443 -Action Allow | Out-Null
        [void]$done.Add('firewall rule')
    }

    # A src server's name hard-coded in a policy value.
    $gpo = Get-GpoOrNew -Name 'XD - Hardcoded Server'
    Set-GPRegistryValue -Guid $gpo.Id -Domain $Domain -Server $pdc -Key 'HKLM\Software\Policies\XdLab' `
        -ValueName 'XdAppServer' -Type String -Value "\\$fqdnHost\Apps" | Out-Null

    # A WMI filter linked to the GPO.
    $gpo = Get-GpoOrNew -Name 'XD - WMI Filtered'
    Set-GPRegistryValue -Guid $gpo.Id -Domain $Domain -Server $pdc -Key 'HKLM\Software\Policies\XdLab' `
        -ValueName 'XdWmiFiltered' -Type DWord -Value 1 | Out-Null
    Set-WmiFilterLink -GpoId $gpo.Id -Name $WmiFilter

    # Security filtering to a src group (Authenticated Users kept at Read,
    # MS16-072) and editing delegated to another.
    $gpo = Get-GpoOrNew -Name 'XD - Security Filtered'
    Set-GPRegistryValue -Guid $gpo.Id -Domain $Domain -Server $pdc -Key 'HKLM\Software\Policies\XdLab' `
        -ValueName 'XdFiltered' -Type DWord -Value 1 | Out-Null
    Set-GPPermission -Guid $gpo.Id -Domain $Domain -Server $pdc -TargetName $groupNames.servers -TargetType Group `
        -PermissionLevel GpoApply | Out-Null
    Set-GPPermission -Guid $gpo.Id -Domain $Domain -Server $pdc -TargetName 'Authenticated Users' -TargetType Group `
        -PermissionLevel GpoRead -Replace | Out-Null
    Set-GPPermission -Guid $gpo.Id -Domain $Domain -Server $pdc -TargetName $admins -TargetType Group `
        -PermissionLevel GpoEdit | Out-Null
    [void]$done.Add('content matrix')
}

function Invoke-Target {
    foreach ($name in $groupNames.PSObject.Properties.Value) { New-Group -Name $name }
}

if ($Action -eq 'Source') { Invoke-Source } else { Invoke-Target }

$Ansible.Changed = $done.Count -gt 0
$Ansible.Result = [ordered]@{
    done = @($done)
    domain = [ordered]@{
        dns = $adDomain.DNSRoot
        netbios = $netbios
        sid = $adDomain.DomainSID.Value
        host = $hostName
    }
    group_sids = [ordered]@{}
}
foreach ($p in $groupNames.PSObject.Properties) { $Ansible.Result.group_sids[$p.Value] = Get-GroupSid -Name $p.Value }
