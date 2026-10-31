# Read the local node's cluster for verify.yml's assertions. Read-only.
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module FailoverClusters

# Through the node: the lab's cluster has no name to resolve.
$conn = $env:COMPUTERNAME
$cluster = Get-Cluster -Name $conn
$clusterNodes = @(Get-ClusterNode -Cluster $conn)
$quorum = Get-ClusterQuorum -Cluster $conn
$networkNames = @(Get-ClusterResource -Cluster $conn | Where-Object { [string]$_.ResourceType -eq 'Network Name' })

$Ansible.Result = @{
    name = [string]$cluster.Name
    computer = $env:COMPUTERNAME
    nodes = @($clusterNodes | ForEach-Object { [string]$_.Name })
    node_states = @($clusterNodes | ForEach-Object { [string]$_.State })
    same_subnet_threshold = [int]$cluster.SameSubnetThreshold
    cross_subnet_threshold = [int]$cluster.CrossSubnetThreshold
    networks = @(Get-ClusterNetwork -Cluster $conn | ForEach-Object {
            @{ name = [string]$_.Name; role = [int]$_.Role; metric = [int]$_.Metric; address = [string]$_.Address }
        })
    witness = $null -ne $quorum.QuorumResource
    network_name_resource = $networkNames.Count -gt 0
}
