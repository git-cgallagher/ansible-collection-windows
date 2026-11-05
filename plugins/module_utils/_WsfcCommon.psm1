# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the failover clustering modules (wsfc_cluster and wsfc_group):
# the pure logic, with no Ansible.Basic or FailoverClusters calls, so Pester
# tests it without a cluster (tests/unit/plugins/modules/wsfc_cluster.Tests.ps1
# and wsfc_group.Tests.ps1).
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
    is only given as ParentId. Type, when given, is used instead of the
    object's own type property (the module learns it from the cmdlet's
    documented -Type filter).
    #>
    [CmdletBinding()]
    param ($FaultDomain, [hashtable]$ById = @{}, [string]$Type = '')

    $parent = Get-FirstProperty -Object $FaultDomain -Names 'ParentName', 'Parent', 'FaultDomain'
    if (-not $parent) {
        $parentId = Get-FirstProperty -Object $FaultDomain -Names 'ParentId'
        if ($parentId -and $ById.ContainsKey($parentId)) { $parent = [string]$ById[$parentId] }
    }
    if (-not $Type) { $Type = Get-FirstProperty -Object $FaultDomain -Names 'Type', 'FaultDomainType' }
    @{
        name = Get-FirstProperty -Object $FaultDomain -Names 'Name'
        type = $Type
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

Function ConvertTo-WsfcHour {
    <#
    .SYNOPSIS
    Returns a failback window hour the way the options give it: 0 to 23, or
    -1 for no window, which the cluster stores as 4294967295 (0xFFFFFFFF).
    #>
    [CmdletBinding()]
    param ($Value)

    if ([string]$Value -eq '4294967295') { return -1 }
    [int][string]$Value
}

Function Get-WsfcGroupPlan {
    <#
    .SYNOPSIS
    Plans the changes the wsfc_group module's options ask for, for one
    cluster group.
    .DESCRIPTION
    Group: what the cluster reports, as @{ name; owner; preferred_owners;
    properties; resources }, where properties are the group's common
    properties by name and each resource is @{ name; type; properties;
    parameters } (common and private properties by name). ClusterNodes and
    NodesUp: node names. Then the options: PreferredOwners ($null when left
    out), Owner ('' when left out), Failback (@{ allowed; window_start;
    window_end }, $null when left out), Properties, and Resources (each
    @{ name; properties; parameters }). Names compare without case.

    A group that holds an availability group (a resource of type 'SQL Server
    Availability Group') belongs to SQL Server: its owners, failback,
    properties and moves are refused, and so is any change to the
    availability group resource. Other resources in that group, such as the
    listener's network name, stay settable.
    .OUTPUTS
    @{ Actions; Warnings }. Actions come in the order the module carries them
    out, the move last: @{ Kind = 'SetGroupProperty'; Name; From; To; Value },
    @{ Kind = 'SetPreferredOwners'; From; To },
    @{ Kind = 'SetResourceProperty'; Resource; Name; From; To; Value },
    @{ Kind = 'SetResourceParameters'; Resource; Changes } (one per resource,
    each change @{ Name; From; To; Value }, set together) and
    @{ Kind = 'Move'; From; To }. Value is what to write; From and To are
    for display (failback window hours as -1 to 23).
    #>
    [CmdletBinding()]
    param (
        [hashtable]$Group = @{},
        [AllowEmptyCollection()][string[]]$ClusterNodes = @(),
        [AllowEmptyCollection()][string[]]$NodesUp = @(),
        $PreferredOwners = $null,
        [string]$Owner = '',
        $Failback = $null,
        [hashtable]$Properties = @{},
        [AllowEmptyCollection()][object[]]$Resources = @()
    )

    $agType = 'SQL Server Availability Group'
    $hourProperties = 'FailbackWindowStart', 'FailbackWindowEnd'
    $groupName = [string]$Group.name
    $groupProperties = @{}
    if ($null -ne $Group.properties) {
        foreach ($k in @($Group.properties.Keys)) { $groupProperties[[string]$k] = $Group.properties[$k] }
    }
    $groupResources = @($Group.resources | Where-Object { $null -ne $_ })
    $actions = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $isAvailabilityGroup = @($groupResources | Where-Object { [string]$_.type -eq $agType }).Count -gt 0
    if ($isAvailabilityGroup -and ($null -ne $PreferredOwners -or $Owner -or $null -ne $Failback -or $Properties.Count -gt 0)) {
        throw ("Group $groupName holds an availability group: SQL Server manages its owners, failback, properties " +
            'and moves, so change them through SQL Server (fail it over with T-SQL), not wsfc_group')
    }

    $nodeByKey = @{}
    foreach ($n in @($ClusterNodes)) { $nodeByKey[(Get-ShortName $n)] = [string]$n }
    $upKeys = @{}
    foreach ($n in @($NodesUp)) { $upKeys[(Get-ShortName $n)] = $true }

    # --- group properties, failback among them ----------------------------------
    $wanted = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($Properties.Keys)) { $wanted.Add(@{ Name = [string]$k; Value = $Properties[$k] }) }
    $failbackAllowed = $null
    if ($null -ne $Failback) {
        foreach ($k in 'AutoFailbackType', 'FailbackWindowStart', 'FailbackWindowEnd') {
            if (@($wanted | Where-Object { $_.Name -eq $k }).Count -gt 0) {
                throw "Set failback with failback or with properties.$k, not both"
            }
        }
        $failbackAllowed = Get-Setting -Object $Failback -Key 'allowed'
        $start = Get-Setting -Object $Failback -Key 'window_start'
        $end = Get-Setting -Object $Failback -Key 'window_end'
        if (($null -eq $start) -ne ($null -eq $end)) {
            throw 'failback needs both window_start and window_end (-1 for no window), or neither'
        }
        if ($null -ne $failbackAllowed) {
            $type = 0
            if ([bool]$failbackAllowed) { $type = 1 }
            $wanted.Add(@{ Name = 'AutoFailbackType'; Value = $type })
        }
        if ($null -ne $start) {
            $wanted.Add(@{ Name = 'FailbackWindowStart'; Value = $start })
            $wanted.Add(@{ Name = 'FailbackWindowEnd'; Value = $end })
        }
    }
    foreach ($w in $wanted) {
        if (-not $groupProperties.ContainsKey($w.Name)) { throw "Group $groupName has no common property '$($w.Name)'" }
        $current = $groupProperties[$w.Name]
        if ($hourProperties -contains $w.Name) {
            $hour = [int][string]$w.Value
            if ($hour -lt -1 -or $hour -gt 23) {
                throw "$($w.Name) must be -1 (no failback window) or an hour from 0 to 23, not $($w.Value)"
            }
            $currentHour = ConvertTo-WsfcHour $current
            if ($currentHour -ne $hour) {
                $value = [uint32]4294967295
                if ($hour -ge 0) { $value = [uint32]$hour }
                $actions.Add(@{ Kind = 'SetGroupProperty'; Name = $w.Name; From = $currentHour; To = $hour; Value = $value })
            }
        }
        elseif ([string]$current -ne [string]$w.Value) {
            $actions.Add(@{ Kind = 'SetGroupProperty'; Name = $w.Name; From = [string]$current; To = [string]$w.Value; Value = $w.Value })
        }
    }

    # --- preferred owners: an exact, ordered list -----------------------------------
    $finalOwners = @($Group.preferred_owners | Where-Object { $_ })
    if ($null -ne $PreferredOwners) {
        $resolved = [System.Collections.Generic.List[string]]::new()
        $seen = @{}
        foreach ($n in @($PreferredOwners)) {
            $key = Get-ShortName ([string]$n)
            if (-not $nodeByKey.ContainsKey($key)) { throw "Node $n in preferred_owners isn't in the cluster" }
            if ($seen.ContainsKey($key)) { throw "Node $n is listed twice in preferred_owners" }
            $seen[$key] = $true
            $resolved.Add($nodeByKey[$key])
        }
        if ($resolved.Count -eq 0) {
            throw "preferred_owners must name at least one node; leave it out to keep group $groupName's list"
        }
        $currentKeys = @($finalOwners | ForEach-Object { Get-ShortName ([string]$_) }) -join ','
        $wantedKeys = @($resolved | ForEach-Object { Get-ShortName $_ }) -join ','
        if ($currentKeys -ne $wantedKeys) {
            $actions.Add(@{ Kind = 'SetPreferredOwners'; From = @($finalOwners); To = @($resolved) })
        }
        $finalOwners = @($resolved)
    }
    if ($null -ne $failbackAllowed -and [bool]$failbackAllowed -and $finalOwners.Count -eq 0) {
        $warnings.Add("Failback has no effect on group $groupName until it has preferred owners")
    }

    # --- resources: common properties, then private ones --------------------------------
    $resourceByName = @{}
    foreach ($r in $groupResources) { $resourceByName[[string]$r.name] = $r }
    $seenResources = @{}
    foreach ($spec in @($Resources)) {
        $resName = [string](Get-Setting -Object $spec -Key 'name' -Default '')
        if (-not $resName) { throw 'Every resource needs a name' }
        if ($seenResources.ContainsKey($resName)) { throw "Resource $resName is listed twice" }
        $seenResources[$resName] = $true
        if (-not $resourceByName.ContainsKey($resName)) { throw "Resource $resName isn't in group $groupName" }
        $res = $resourceByName[$resName]
        $wantedProperties = Get-Setting -Object $spec -Key 'properties' -Default @{}
        $wantedParameters = Get-Setting -Object $spec -Key 'parameters' -Default @{}
        if ([string]$res.type -eq $agType -and (@($wantedProperties.Keys).Count + @($wantedParameters.Keys).Count) -gt 0) {
            throw "Resource $resName is an availability group, which SQL Server manages; wsfc_group leaves it alone"
        }
        foreach ($set in @(
                @{ Kind = 'SetResourceProperty'; Wanted = $wantedProperties; Current = $res.properties; Label = 'common' },
                @{ Kind = 'SetResourceParameters'; Wanted = $wantedParameters; Current = $res.parameters; Label = 'private' }
            )) {
            $currentByName = @{}
            if ($null -ne $set.Current) {
                foreach ($k in @($set.Current.Keys)) { $currentByName[[string]$k] = $set.Current[$k] }
            }
            $changes = [System.Collections.Generic.List[object]]::new()
            foreach ($k in @($set.Wanted.Keys)) {
                $propName = [string]$k
                if (-not $currentByName.ContainsKey($propName)) {
                    throw "Resource $resName has no $($set.Label) property '$propName'"
                }
                $current = [string]$currentByName[$propName]
                if ($current -ne [string]$set.Wanted[$k]) {
                    $changes.Add(@{ Name = $propName; From = $current; To = [string]$set.Wanted[$k]; Value = $set.Wanted[$k] })
                }
            }
            if ($set.Kind -eq 'SetResourceProperty') {
                foreach ($c in $changes) {
                    $actions.Add(@{ Kind = $set.Kind; Resource = $resName; Name = $c.Name; From = $c.From; To = $c.To; Value = $c.Value })
                }
            }
            elseif ($changes.Count -gt 0) {
                # One action for all of a resource's private properties: the
                # resource validates them as a set (a Generic Application
                # refuses a CommandLine while its CurrentDirectory is empty).
                $actions.Add(@{ Kind = $set.Kind; Resource = $resName; Changes = @($changes) })
            }
        }
    }

    # --- the move, last ---------------------------------------------------------------
    if ($Owner) {
        $key = Get-ShortName $Owner
        if (-not $nodeByKey.ContainsKey($key)) { throw "Node $Owner isn't in the cluster" }
        if ((Get-ShortName ([string]$Group.owner)) -ne $key) {
            if (-not $upKeys.ContainsKey($key)) { throw "Node $Owner isn't up, so group $groupName can't move to it" }
            $actions.Add(@{ Kind = 'Move'; From = [string]$Group.owner; To = $nodeByKey[$key] })
        }
    }

    @{ Actions = @($actions); Warnings = @($warnings) }
}

$exportFunctions = @(
    'ConvertTo-WsfcFaultDomain'
    'ConvertTo-WsfcHour'
    'Get-FirstProperty'
    'Get-ResourceTypeName'
    'Get-Setting'
    'Get-ShortName'
    'Get-WsfcGroupPlan'
    'Get-WsfcNodeWeightPlan'
    'Get-WsfcSitePlan'
    'Test-NetworkMatch'
)
Export-ModuleMember -Function $exportFunctions
