# Remove the cluster the local node is in, if any, so a target starts from
# nothing and leaves nothing. Runs through runas become.
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module -Name FailoverClusters
$cluster = $null
try {
    $cluster = Get-Cluster -Name $env:COMPUTERNAME -ErrorAction Stop
}
catch {
    $cluster = $null
}
if ($null -ne $cluster) {
    $cluster | Remove-Cluster -Force -CleanupAD:$false
    $Ansible.Changed = $true
}
