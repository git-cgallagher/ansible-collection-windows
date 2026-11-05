# Read, on dc01, what wsfc did outside the cluster: the file share witness's
# share and folder permissions, and the cluster name object's right to create
# computer objects, with the domain's machine account quota and how the file
# server's computer object was created. For verify.yml's assertions.
# Read-only.
param([string]$Cluster, [string]$FileServer, [string]$Share, [string]$Path)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module ActiveDirectory

$cno = Get-ADComputer -Identity $Cluster
$cnoAccount = $cno.SID.Translate([System.Security.Principal.NTAccount]).Value
$domain = (Get-ADDomain).DistinguishedName
$container = ($cno.DistinguishedName -split ',', 2)[1]
$computerClass = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
$createRules = @((Get-Acl -Path "AD:$container").GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
        Where-Object {
            [string]$_.IdentityReference -eq $cno.SID.Value -and [string]$_.AccessControlType -eq 'Allow' -and
            ([int64]$_.ActiveDirectoryRights -band 1) -and $_.ObjectType -eq $computerClass
        })
# The quota path stamps ms-DS-CreatorSID on the computer object it creates; a
# creator with the right to create computer objects leaves it empty.
$fileServer = Get-ADComputer -Identity $FileServer -Properties 'ms-DS-CreatorSID'
$folderRules = @((Get-Acl -LiteralPath $Path).Access | Where-Object {
        [string]$_.IdentityReference -eq $cnoAccount -and [string]$_.AccessControlType -eq 'Allow'
    })

$Ansible.Result = @{
    cno_account = $cnoAccount
    cno_container = $container
    cno_create_rules = $createRules.Count
    machine_account_quota = [int](Get-ADObject -Identity $domain -Properties 'ms-DS-MachineAccountQuota').'ms-DS-MachineAccountQuota'
    fileserver_container = ($fileServer.DistinguishedName -split ',', 2)[1]
    fileserver_creator_sid = [string]$fileServer.'ms-DS-CreatorSID'
    share_path = [string](Get-SmbShare -Name $Share).Path
    # One string each: win_powershell renders a nested list as its type name.
    share_access = (@(Get-SmbShareAccess -Name $Share | ForEach-Object {
                '{0}:{1}:{2}' -f $_.AccountName, $_.AccessControlType, $_.AccessRight
            } | Sort-Object) -join ';')
    folder_rights = (@($folderRules | ForEach-Object { [string]$_.FileSystemRights } | Sort-Object -Unique) -join ';')
}
