# Read a cluster group, and optionally one of its resources, for the
# wsfc_group target's assertions. Read-only, and independent of the module
# under test: the FailoverClusters cmdlets only. Read it with depth 5.
param([string]$Group, [string]$Resource = '')
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module -Name FailoverClusters

$conn = $env:COMPUTERNAME
$g = Get-ClusterGroup -Cluster $conn -Name $Group
$result = @{
    name = [string]$g.Name
    owner = [string]$g.OwnerNode.Name
    state = [string]$g.State
    description = [string]$g.Description
    priority = [string]$g.Priority
    auto_failback_type = [string]$g.AutoFailbackType
    # As stored: 4294967295 means no window.
    failback_window_start = [string]$g.FailbackWindowStart
    failback_window_end = [string]$g.FailbackWindowEnd
    preferred_owners = @((Get-ClusterOwnerNode -Cluster $conn -Group $Group).OwnerNodes | ForEach-Object { [string]$_.Name })
}
if ($Resource) {
    $r = Get-ClusterResource -Cluster $conn -Name $Resource
    $parameters = @{}
    foreach ($p in @(Get-ClusterParameter -InputObject $r)) { $parameters[[string]$p.Name] = [string]$p.Value }
    $result.resource = @{
        name = [string]$r.Name
        group = [string]$r.OwnerGroup.Name
        restart_threshold = [string]$r.RestartThreshold
        parameters = $parameters
    }
}
$Ansible.Result = $result
