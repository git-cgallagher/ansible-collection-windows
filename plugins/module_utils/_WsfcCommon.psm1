# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the failover clustering modules (wsfc_cluster today): the pure
# logic, with no Ansible.Basic or FailoverClusters calls, so Pester tests it
# without a cluster (tests/unit/plugins/modules/wsfc_cluster.Tests.ps1).
# Private to this collection, with no compatibility promise. Windows
# PowerShell 5.1 syntax only.
#
# The planners take what the cluster reports, reduced to plain hashtables, and
# return what to change; the module carries the changes out (or, in check
# mode, only lists them). They never plan a removal: a site or a node
# placement the options don't list comes back as a warning.

Function Get-ShortName {
    <#
    .SYNOPSIS
    Returns a computer name's first label, upper-cased: the way the cluster
    names its nodes and their fault domains.
    #>
    [CmdletBinding()]
    param ([string]$Computer)

    ($Computer -split '\.')[0].ToUpperInvariant()
}

Function Get-Setting {
    <#
    .SYNOPSIS
    Returns a sub-option's value, or Default when it was left out. An empty
    string counts as left out too, so a role can pass '' for "not set".
    #>
    [CmdletBinding()]
    param ($Object, [string]$Key, $Default = $null)

    if ($null -ne $Object -and $Object.ContainsKey($Key) -and $null -ne $Object[$Key] -and [string]$Object[$Key] -ne '') {
        return $Object[$Key]
    }
    $Default
}

Function Get-ResourceTypeName {
    <#
    .SYNOPSIS
    Returns a cluster resource's type name, whether ResourceType is an object
    with a Name or a plain string.
    #>
    [CmdletBinding()]
    param ($Resource)

    $type = $Resource.ResourceType
    if ($null -ne $type -and $type.PSObject.Properties['Name']) { return [string]$type.Name }
    [string]$type
}

Function Test-NetworkMatch {
    <#
    .SYNOPSIS
    Tells whether a cluster network has the subnet (address and prefix
    length), IPv4 or IPv6.
    #>
    [CmdletBinding()]
    param ($Network, [string]$Subnet, [int]$Prefix)

    $pairs = @(
        @(@($Network.Ipv4Addresses), @($Network.Ipv4PrefixLengths)),
        @(@($Network.Ipv6Addresses), @($Network.Ipv6PrefixLengths))
    )
    foreach ($pair in $pairs) {
        for ($i = 0; $i -lt $pair[0].Count; $i++) {
            if ([string]$pair[0][$i] -eq $Subnet -and [int]$pair[1][$i] -eq $Prefix) { return $true }
        }
    }
    $false
}

Function Get-FirstProperty {
    <#
    .SYNOPSIS
    Returns the value of the first of Names that the object has, as a string,
    or '' when it has none of them.
    #>
    [CmdletBinding()]
    param ($Object, [string[]]$Names)

    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if ($null -ne $p -and $null -ne $p.Value) { return [string]$p.Value }
    }
    ''
}

Function ConvertTo-WsfcFaultDomain {
    <#
    .SYNOPSIS
    Reduces a Get-ClusterFaultDomain object to @{ name; type; parent;
    description }.
    .DESCRIPTION
    The cmdlet's reference doesn't document the returned properties, so each
    one is read under the names it is known to have (the type as Type or
    FaultDomainType, the parent as ParentName, Parent or FaultDomain) and an
    absent one is ''. ById maps fault domain IDs to names, for a parent that
    is only given as ParentId.
    #>
    [CmdletBinding()]
    param ($FaultDomain, [hashtable]$ById = @{})

    $parent = Get-FirstProperty -Object $FaultDomain -Names 'ParentName', 'Parent', 'FaultDomain'
    if (-not $parent) {
        $parentId = Get-FirstProperty -Object $FaultDomain -Names 'ParentId'
        if ($parentId -and $ById.ContainsKey($parentId)) { $parent = [string]$ById[$parentId] }
    }
    @{
        name = Get-FirstProperty -Object $FaultDomain -Names 'Name'
        type = Get-FirstProperty -Object $FaultDomain -Names 'Type', 'FaultDomainType'
        parent = $parent
        description = Get-FirstProperty -Object $FaultDomain -Names 'Description'
    }
}

Function Get-WsfcSitePlan {
    <#
    .SYNOPSIS
    Plans the site fault domains and node placements the sites option asks for.
    .DESCRIPTION
    Sites: the wanted sites, each @{ name; nodes; description } (nodes and
    description may be left out). FaultDomains: the cluster's fault domains,
    each @{ name; type; parent; description } (ConvertTo-WsfcFaultDomain).
    ClusterNodes: the cluster's node names. Names compare without case.

    Throws on a site without a name, a site listed twice, a site named like a
    node, a node listed in two sites, a node that isn't in the cluster, and a
    fault domain of another type that has a wanted site's name.
    .OUTPUTS
    @{ Actions; Warnings }. Actions are hashtables, creations first:
    @{ Kind = 'CreateSite'; Name; Description }, @{ Kind = 'SetDescription';
    Name; From; To } and @{ Kind = 'SetParent'; Node; FaultDomain; From; To },
    where FaultDomain is the node's fault domain name as the cluster has it.
    Warnings name the sites the option doesn't list, which are left in place.
    #>
    [CmdletBinding()]
    param (
        [AllowEmptyCollection()][object[]]$Sites = @(),
        [AllowEmptyCollection()][object[]]$FaultDomains = @(),
        [AllowEmptyCollection()][string[]]$ClusterNodes = @()
    )

    $creates = [System.Collections.Generic.List[object]]::new()
    $descriptions = [System.Collections.Generic.List[object]]::new()
    $parents = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $nodeSet = @{}
    foreach ($n in @($ClusterNodes)) { $nodeSet[(Get-ShortName $n)] = $true }
    # A node's fault domain is also found by its short name: Microsoft's
    # examples name node fault domains both ways (server01, server01.contoso.com).
    $domains = @{}
    $nodeDomains = @{}
    foreach ($d in @($FaultDomains)) {
        $domains[([string]$d.name).ToUpperInvariant()] = $d
        if ([string]$d.type -eq 'Node') { $nodeDomains[(Get-ShortName ([string]$d.name))] = $d }
    }

    $seenSites = @{}
    $nodeSite = @{}
    foreach ($site in @($Sites)) {
        $siteName = [string](Get-Setting -Object $site -Key 'name' -Default '')
        if (-not $siteName) { throw 'Every site needs a name' }
        $siteKey = $siteName.ToUpperInvariant()
        if ($seenSites.ContainsKey($siteKey)) { throw "Site $siteName is listed twice" }
        $seenSites[$siteKey] = $siteName
        if ($nodeSet.ContainsKey($siteKey)) { throw "Site $siteName has the name of a node; fault domain names are shared" }

        $wantedDescription = [string](Get-Setting -Object $site -Key 'description' -Default '')
        $existing = $null
        if ($domains.ContainsKey($siteKey)) { $existing = $domains[$siteKey] }
        if ($null -eq $existing) {
            $creates.Add(@{ Kind = 'CreateSite'; Name = $siteName; Description = $wantedDescription })
        }
        else {
            if ([string]$existing.type -and [string]$existing.type -ne 'Site') {
                throw "Fault domain $siteName exists as a $($existing.type), not a site"
            }
            if ($wantedDescription -and [string]$existing.description -ne $wantedDescription) {
                $descriptions.Add(@{ Kind = 'SetDescription'; Name = $siteName; From = [string]$existing.description; To = $wantedDescription })
            }
        }

        $siteNodes = Get-Setting -Object $site -Key 'nodes' -Default @()
        foreach ($node in @($siteNodes)) {
            $nodeKey = Get-ShortName ([string]$node)
            if (-not $nodeSet.ContainsKey($nodeKey)) { throw "Node $node in site $siteName isn't in the cluster" }
            if ($nodeSite.ContainsKey($nodeKey)) {
                throw "Node $node is listed in sites $($nodeSite[$nodeKey]) and $siteName; a node belongs to one site"
            }
            $nodeSite[$nodeKey] = $siteName
            $record = $null
            if ($nodeDomains.ContainsKey($nodeKey)) { $record = $nodeDomains[$nodeKey] }
            elseif ($domains.ContainsKey($nodeKey)) { $record = $domains[$nodeKey] }
            $current = ''
            $faultDomainName = $nodeKey
            if ($null -ne $record) {
                $current = [string]$record.parent
                $faultDomainName = [string]$record.name
            }
            if ($current.ToUpperInvariant() -ne $siteKey) {
                $parents.Add(@{ Kind = 'SetParent'; Node = $nodeKey; FaultDomain = $faultDomainName; From = $current; To = $siteName })
            }
        }
    }

    foreach ($d in @($FaultDomains)) {
        if ([string]$d.type -eq 'Site' -and -not $seenSites.ContainsKey(([string]$d.name).ToUpperInvariant())) {
            $warnings.Add("Site $($d.name) isn't in sites; it was left in place")
        }
    }

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($list in $creates, $descriptions, $parents) {
        foreach ($a in $list) { $actions.Add($a) }
    }
    @{ Actions = @($actions); Warnings = @($warnings) }
}

Function Get-WsfcNodeWeightPlan {
    <#
    .SYNOPSIS
    Plans the node votes (NodeWeight) the node_weights option asks for.
    .DESCRIPTION
    Weights: the wanted weights by node name. Current: each cluster node's
    weight by name. Names compare without case. Throws on a node that isn't in
    the cluster and on a weight other than 0 or 1.
    .OUTPUTS
    Hashtables @{ Node; From; To }, one per node whose weight differs.
    #>
    [CmdletBinding()]
    param ([hashtable]$Weights = @{}, [hashtable]$Current = @{})

    $byNode = @{}
    foreach ($k in @($Current.Keys)) { $byNode[(Get-ShortName ([string]$k))] = [int]$Current[$k] }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($Weights.Keys | Sort-Object)) {
        $nodeKey = Get-ShortName ([string]$k)
        if (-not $byNode.ContainsKey($nodeKey)) { throw "Node $k in node_weights isn't in the cluster" }
        $raw = [string]$Weights[$k]
        if ($raw -ne '0' -and $raw -ne '1') { throw "Node $k's weight must be 0 or 1, not '$raw'" }
        $wanted = [int]$raw
        if ($byNode[$nodeKey] -ne $wanted) {
            $plan.Add(@{ Node = $nodeKey; From = $byNode[$nodeKey]; To = $wanted })
        }
    }
    @($plan)
}

$exportFunctions = @(
    'ConvertTo-WsfcFaultDomain'
    'Get-FirstProperty'
    'Get-ResourceTypeName'
    'Get-Setting'
    'Get-ShortName'
    'Get-WsfcNodeWeightPlan'
    'Get-WsfcSitePlan'
    'Test-NetworkMatch'
)
Export-ModuleMember -Function $exportFunctions
