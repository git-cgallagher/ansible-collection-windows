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
    # Remove-Cluster refuses a cluster that still has groups of its own (not
    # its core groups), such as the wsfc_group target's test group.
    foreach ($group in @(Get-ClusterGroup -Cluster $env:COMPUTERNAME | Where-Object { -not $_.IsCoreGroup })) {
        Remove-ClusterGroup -Cluster $env:COMPUTERNAME -Name $group.Name -RemoveResources -Force
    }
    $cluster | Remove-Cluster -Force -CleanupAD:$false
    $Ansible.Changed = $true
}
