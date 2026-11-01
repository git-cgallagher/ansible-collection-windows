# Read the cluster and its file server for verify.yml's assertions. Read-only.
param([string]$FileServer)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module FailoverClusters

$conn = $env:COMPUTERNAME
$cluster = Get-Cluster -Name $conn
$clusterNodes = @(Get-ClusterNode -Cluster $conn)
$quorum = Get-ClusterQuorum -Cluster $conn
$group = Get-ClusterGroup -Cluster $conn -Name $FileServer
$owner = [string]$group.OwnerNode.Name

# Shares scoped to a clustered name are visible only on the node that owns it.
# (A script block in a variable: PSScriptAnalyzer misreads an inline one's
# parameters as variables from the calling scope.)
$readShares = {
    param([string]$Scope)
    foreach ($share in @(Get-SmbShare -ScopeName $Scope -ErrorAction SilentlyContinue)) {
        if ($share.Special) { continue }
        $access = @()
        foreach ($entry in @(Get-SmbShareAccess -ScopeName $Scope -Name $share.Name)) {
            $access += '{0}:{1}' -f $entry.AccountName, $entry.AccessRight
        }
        @{
            name = [string]$share.Name
            path = [string]$share.Path
            description = [string]$share.Description
            continuously_available = [bool]$share.ContinuouslyAvailable
            folder_enumeration_mode = [string]$share.FolderEnumerationMode
            # One string: win_powershell renders a list nested this deep as
            # its type name.
            access = (@($access | Sort-Object) -join ';')
        }
    }
}
$shares = Invoke-Command -ComputerName $owner -ScriptBlock $readShares -ArgumentList $FileServer

$Ansible.Result = @{
    name = [string]$cluster.Name
    nodes = @($clusterNodes | ForEach-Object { [string]$_.Name } | Sort-Object)
    node_states = @($clusterNodes | ForEach-Object { [string]$_.State } | Sort-Object -Unique)
    witness = [string]$quorum.QuorumResource.Name
    disks = @(Get-ClusterResource -Cluster $conn | Where-Object { [string]$_.ResourceType -eq 'Physical Disk' } |
            ForEach-Object { @{ name = [string]$_.Name; group = [string]$_.OwnerGroup.Name; state = [string]$_.State } })
    networks = @(Get-ClusterNetwork -Cluster $conn | ForEach-Object {
            @{ name = [string]$_.Name; role = [int]$_.Role; address = [string]$_.Address }
        })
    cluster_addresses = @(Get-ClusterResource -Cluster $conn | Where-Object {
            [string]$_.ResourceType -eq 'IP Address' -and [string]$_.OwnerGroup.Name -eq 'Cluster Group' } |
            ForEach-Object { [string]($_ | Get-ClusterParameter -Name Address).Value })
    fileserver = @{
        state = [string]$group.State
        owner = $owner
        type = [string]$group.GroupType
        preferred_owners = @((Get-ClusterOwnerNode -Cluster $conn -Group $FileServer).OwnerNodes | ForEach-Object { [string]$_.Name })
        addresses = @(Get-ClusterResource -Cluster $conn | Where-Object {
                [string]$_.ResourceType -eq 'IP Address' -and [string]$_.OwnerGroup.Name -eq $FileServer } |
                ForEach-Object { [string]($_ | Get-ClusterParameter -Name Address).Value })
    }
    # Top level: win_powershell renders objects nested deeper than this as
    # their type name ("System.Collections.Hashtable").
    shares = @($shares)
}
