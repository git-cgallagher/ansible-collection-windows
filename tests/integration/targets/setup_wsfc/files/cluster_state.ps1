# Read the local node's cluster for the targets' assertions. Read-only, and
# independent of the module under test: the FailoverClusters cmdlets only.
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module -Name FailoverClusters

# Through the node: a cluster with access point None has no name to resolve.
$conn = $env:COMPUTERNAME
$cluster = $null
try {
    $cluster = Get-Cluster -Name $conn -ErrorAction Stop
}
catch {
    $cluster = $null
}

if ($null -eq $cluster) {
    $Ansible.Result = @{ exists = $false; computer = $conn }
    return
}

$clusterNodes = @(Get-ClusterNode -Cluster $conn)
$quorum = Get-ClusterQuorum -Cluster $conn
$Ansible.Result = @{
    exists = $true
    computer = $conn
    name = [string]$cluster.Name
    nodes = @($clusterNodes | ForEach-Object { [string]$_.Name })
    node_states = @($clusterNodes | ForEach-Object { [string]$_.State })
    same_subnet_threshold = [int]$cluster.SameSubnetThreshold
    cross_subnet_threshold = [int]$cluster.CrossSubnetThreshold
    networks = @(Get-ClusterNetwork -Cluster $conn | ForEach-Object {
            @{
                name = [string]$_.Name
                role = [int]$_.Role
                metric = [int]$_.Metric
                # The first IPv4 subnet in CIDR form, the way the module's
                # networks option names a network.
                subnet = '{0}/{1}' -f [string]@($_.Ipv4Addresses)[0], [int]@($_.Ipv4PrefixLengths)[0]
            }
        })
    witness = $null -ne $quorum.QuorumResource
}
