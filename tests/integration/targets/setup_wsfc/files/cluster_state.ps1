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

# Sites from the topology XML, a different path from the fault domain objects
# the module reads: each Site element holds its nodes.
$topology = [xml]((@(Get-ClusterFaultDomainXML) | ForEach-Object { [string]$_ }) -join "`n")
$sites = @($topology.SelectNodes('//Site') | ForEach-Object {
        @{
            name = $_.GetAttribute('Name')
            description = $_.GetAttribute('Description')
            nodes = @($_.SelectNodes('.//Node') | ForEach-Object { $_.GetAttribute('Name') })
        }
    })
# The preferred site as the cluster reports it, translated when it is a
# fault domain's ID rather than its name.
$preferredSite = [string]$cluster.PreferredSite
$preferredById = @(Get-ClusterFaultDomain | Where-Object { $_.PSObject.Properties['Id'] -and [string]$_.Id -eq $preferredSite })
if ($preferredSite -and $preferredById.Count -eq 1) { $preferredSite = [string]$preferredById[0].Name }
$Ansible.Result = @{
    exists = $true
    computer = $conn
    name = [string]$cluster.Name
    nodes = @($clusterNodes | ForEach-Object { [string]$_.Name })
    node_states = @($clusterNodes | ForEach-Object { [string]$_.State })
    node_weights = @($clusterNodes | ForEach-Object { [int]$_.NodeWeight })
    sites = $sites
    preferred_site = $preferredSite
    preferred_site_raw = [string]$cluster.PreferredSite
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
