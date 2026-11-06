# Reads the cluster name object's own Create Computer objects rules on the
# container that holds it, and with -Remove deletes them first. For
# wsfc_cluster_cno's checks, run on a domain controller (ActiveDirectory
# module), never through the module under test. Inherited rules are left out.
param([string]$Cluster, [switch]$Remove)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module ActiveDirectory

$cno = Get-ADComputer -Identity $Cluster
$container = ($cno.DistinguishedName -split ',', 2)[1]
$path = "AD:$container"
$computerClass = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2'
$acl = Get-Acl -Path $path
$rules = @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
        [string]$_.IdentityReference -eq $cno.SID.Value -and [string]$_.AccessControlType -eq 'Allow' -and
        ([int64]$_.ActiveDirectoryRights -band 1) -and $_.ObjectType -eq $computerClass
    })
if ($Remove -and $rules.Count -gt 0) {
    foreach ($rule in $rules) { $acl.RemoveAccessRuleSpecific($rule) }
    Set-Acl -Path $path -AclObject $acl
    $Ansible.Changed = $true
    $rules = @()
}

$Ansible.Result = @{
    container = $container
    sid = $cno.SID.Value
    rules = $rules.Count
    inheritance = @($rules | ForEach-Object { [string]$_.InheritanceType })
}
