#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._WsfcCommon

# Bring one cluster group in line with the options: its common properties
# (failback among them), its preferred owners, its resources' common and
# private properties, and its current owner (a move, always last). Runs on a
# node of the cluster with the FailoverClusters module. Get-WsfcGroupPlan
# (plugins/module_utils/_WsfcCommon.psm1) decides what to change; this file
# reads the cluster and carries the plan out.
#
# Check mode reports every action without changing anything.

$spec = @{
    options = @{
        name = @{ type = 'str'; required = $true }
        preferred_owners = @{ type = 'list'; elements = 'str' }
        owner = @{ type = 'str' }
        move_timeout = @{ type = 'int'; default = 300 }
        failback = @{
            type = 'dict'
            options = @{
                allowed = @{ type = 'bool' }
                window_start = @{ type = 'int' }
                window_end = @{ type = 'int' }
            }
        }
        properties = @{ type = 'dict' }
        resources = @{
            type = 'list'
            elements = 'dict'
            options = @{
                name = @{ type = 'str'; required = $true }
                properties = @{ type = 'dict' }
                parameters = @{ type = 'dict' }
            }
        }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# The module runs non-interactively, where a prompt fails the run.
$ConfirmPreference = 'None'

$name = $module.Params.name
$owner = [string]$module.Params.owner
$moveTimeout = [int]$module.Params.move_timeout
$checkMode = $module.CheckMode
# $null when left out: an empty list and no list mean different things.
$preferredOwners = $module.Params.preferred_owners
$failback = $module.Params.failback
$properties = @{}
if ($null -ne $module.Params.properties) {
    foreach ($k in @($module.Params.properties.Keys)) { $properties[[string]$k] = $module.Params.properties[$k] }
}
$resources = @()
if ($null -ne $module.Params.resources) { $resources = @($module.Params.resources) }

# Get-ShortName, Get-ResourceTypeName and the planner come from
# plugins/module_utils/_WsfcCommon.psm1.
$actions = New-Object System.Collections.Generic.List[string]
$script:nodesUp = @()
$script:group = $null
$script:move = $null

# Record an action; carry it out unless this is a check-mode run.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Change)
    $actions.Add($Description)
    if (-not $checkMode) { & $Change }
}

# An object's own properties by name. A property whose getter fails is left
# out, so it reads as unknown rather than failing the run.
function Get-PropertyMap {
    param($Object)
    $map = @{}
    foreach ($p in $Object.PSObject.Properties) {
        try {
            $map[$p.Name] = $p.Value
        }
        catch {
            continue
        }
    }
    $map
}

# What the planner needs: the group's owner, preferred owners and common
# properties, and every resource in it with its type; the listed resources
# also with their common and private properties.
function Get-GroupState {
    param([string]$Conn, [string]$GroupName, [string[]]$ResourceNames)
    $group = Get-ClusterGroup -Cluster $Conn -Name $GroupName
    $owners = @((Get-ClusterOwnerNode -Cluster $Conn -Group $GroupName).OwnerNodes | ForEach-Object { [string]$_.Name })
    $groupResources = @(Get-ClusterResource -Cluster $Conn | Where-Object { [string]$_.OwnerGroup.Name -eq $GroupName })
    $entries = foreach ($r in $groupResources) {
        $entry = @{ name = [string]$r.Name; type = Get-ResourceTypeName $r; state = [string]$r.State; properties = @{}; parameters = @{} }
        if ($ResourceNames -contains [string]$r.Name) {
            $entry.properties = Get-PropertyMap $r
            foreach ($parameter in @(Get-ClusterParameter -InputObject $r)) { $entry.parameters[[string]$parameter.Name] = $parameter.Value }
        }
        $entry
    }
    @{
        name = [string]$group.Name
        owner = [string]$group.OwnerNode.Name
        state = [string]$group.State
        preferred_owners = $owners
        properties = Get-PropertyMap $group
        resources = @($entries)
    }
}

# The group as the module returns it.
function ConvertTo-GroupResult {
    param($State)
    @{
        name = $State.name
        owner = $State.owner
        state = $State.state
        preferred_owners = @($State.preferred_owners)
        availability_group = @($State.resources | Where-Object { $_.type -eq 'SQL Server Availability Group' }).Count -gt 0
        # Strings, so the result reads well in a debug message.
        resources = @($State.resources | ForEach-Object { '{0} ({1}): {2}' -f $_.name, $_.type, $_.state })
    }
}

# Write a value as the type the cluster holds it in (a DWORD as UInt32, and so
# on), which assignments and Set-ClusterParameter don't always convert.
function ConvertTo-CurrentType {
    param($Value, $Current)
    if ($null -eq $Value -or $null -eq $Current) { return $Value }
    $type = $Current.GetType()
    if ($type -eq $Value.GetType() -or -not ($type.IsPrimitive -or $type -eq [string])) { return $Value }
    [System.Management.Automation.LanguagePrimitives]::ConvertTo($Value, $type)
}

# Move-ClusterGroup -Wait returns when the move ends, online or not, so wait
# for the group to settle on the target: online there, if it was online before.
function Move-Group {
    param([string]$Conn, [string]$GroupName, [string]$Target, [int]$TimeoutSeconds)
    $wasOnline = [string](Get-ClusterGroup -Cluster $Conn -Name $GroupName).State -eq 'Online'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Move-ClusterGroup -Cluster $Conn -Name $GroupName -Node $Target -Wait $TimeoutSeconds
    $settled = $false
    $group = $null
    do {
        $group = Get-ClusterGroup -Cluster $Conn -Name $GroupName
        $onTarget = (Get-ShortName ([string]$group.OwnerNode.Name)) -eq (Get-ShortName $Target)
        $settled = $onTarget -and (-not $wasOnline -or [string]$group.State -eq 'Online')
        if ($settled) { break }
        Start-Sleep -Seconds 2
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    $watch.Stop()
    $seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    if (-not $settled) {
        $expected = 'on'
        if ($wasOnline) { $expected = 'Online on' }
        throw "Group $GroupName is $($group.State) on $($group.OwnerNode.Name) after $seconds s, expected $expected $Target"
    }
    $seconds
}

function Invoke-Main {
    Import-Module -Name FailoverClusters
    # Through the node: a cluster with access point None has no name to resolve.
    $conn = $env:COMPUTERNAME
    try {
        $null = Get-Cluster -Name $conn
    }
    catch {
        throw "$conn isn't a node of a cluster: $($_.Exception.Message)"
    }
    $found = @(Get-ClusterGroup -Cluster $conn | Where-Object { [string]$_.Name -eq $name })
    if ($found.Count -eq 0) { throw "Cluster group $name doesn't exist" }
    $groupName = [string]$found[0].Name

    $resourceNames = @($resources | ForEach-Object { [string]$_['name'] })
    $state = Get-GroupState -Conn $conn -GroupName $groupName -ResourceNames $resourceNames
    $script:group = ConvertTo-GroupResult $state
    $nodes = @(Get-ClusterNode -Cluster $conn)
    $clusterNodes = @($nodes | ForEach-Object { [string]$_.Name })
    $script:nodesUp = @($nodes | Where-Object { [string]$_.State -eq 'Up' } | ForEach-Object { [string]$_.Name })

    $planParams = @{
        Group = $state
        ClusterNodes = $clusterNodes
        NodesUp = $script:nodesUp
        PreferredOwners = $preferredOwners
        Owner = $owner
        Failback = $failback
        Properties = $properties
        Resources = $resources
    }
    $plan = Get-WsfcGroupPlan @planParams
    foreach ($w in $plan.Warnings) { $module.Warn($w) }

    foreach ($step in $plan.Actions) {
        switch ($step.Kind) {
            'SetGroupProperty' {
                Invoke-Change "set group $groupName property $($step.Name) from '$($step.From)' to '$($step.To)'" {
                    $target = Get-ClusterGroup -Cluster $conn -Name $groupName
                    $target.($step.Name) = ConvertTo-CurrentType -Value $step.Value -Current $target.($step.Name)
                }
            }
            'SetPreferredOwners' {
                $fromText = @($step.From) -join ', '
                if (-not $fromText) { $fromText = 'none' }
                Invoke-Change "set group $groupName's preferred owners from $fromText to $(@($step.To) -join ', ')" {
                    $null = Set-ClusterOwnerNode -Cluster $conn -Group $groupName -Owners @($step.To)
                }
            }
            'SetResourceProperty' {
                Invoke-Change "set resource $($step.Resource) property $($step.Name) from '$($step.From)' to '$($step.To)'" {
                    $target = Get-ClusterResource -Cluster $conn -Name $step.Resource
                    $target.($step.Name) = ConvertTo-CurrentType -Value $step.Value -Current $target.($step.Name)
                }
            }
            'SetResourceParameters' {
                # One action line per property, one write for them all: the
                # resource validates its private properties as a set.
                foreach ($change in @($step.Changes)) {
                    $actions.Add("set resource $($step.Resource) private property $($change.Name) from '$($change.From)' to '$($change.To)'")
                }
                if (-not $checkMode) {
                    $target = Get-ClusterResource -Cluster $conn -Name $step.Resource
                    $values = @{}
                    foreach ($change in @($step.Changes)) {
                        $current = (Get-ClusterParameter -InputObject $target -Name $change.Name).Value
                        $values[$change.Name] = ConvertTo-CurrentType -Value $change.Value -Current $current
                    }
                    # Some changes take effect only when the resource restarts,
                    # which Set-ClusterParameter says as a warning. Never
                    # restart a resource here: pass the warning on.
                    $parameterWarnings = $null
                    $setParams = @{
                        InputObject = $target
                        Multiple = $values
                        WarningVariable = 'parameterWarnings'
                        WarningAction = 'SilentlyContinue'
                    }
                    Set-ClusterParameter @setParams
                    foreach ($pw in @($parameterWarnings)) { $module.Warn("Resource $($step.Resource): $pw") }
                }
            }
            'Move' {
                $script:move = @{ from = $step.From; to = $step.To; seconds = $null }
                Invoke-Change "move group $groupName from $($step.From) to $($step.To)" {
                    $script:move.seconds = Move-Group -Conn $conn -GroupName $groupName -Target $step.To -TimeoutSeconds $moveTimeout
                }
            }
        }
    }

    if ($actions.Count -gt 0 -and -not $checkMode) {
        $script:group = ConvertTo-GroupResult (Get-GroupState -Conn $conn -GroupName $groupName -ResourceNames @())
    }
}

function Set-ModuleResult {
    $module.Result.group = $script:group
    $module.Result.nodes_up = @($script:nodesUp)
    $module.Result.move = $script:move
    $module.Result.actions = @($actions)
    # In check mode an action that would be taken is a change, as for a real run.
    $module.Result.changed = $actions.Count -gt 0
    $module.Diff.prepared = ($actions -join "`n")
}

# FailJson exits through an exception, so it is only called outside the try
# block, from the catch.
try {
    Invoke-Main
}
catch {
    Set-ModuleResult
    # The cluster cmdlets wrap the reason ("Unable to save property changes
    # for ..." says nothing more), so report the whole chain.
    $reasons = [System.Collections.Generic.List[string]]::new()
    $exception = $_.Exception
    while ($null -ne $exception) {
        if ($exception.Message -and -not $reasons.Contains($exception.Message)) { $reasons.Add($exception.Message) }
        $exception = $exception.InnerException
    }
    $msg = '{0} (at line {1}: {2})' -f ($reasons -join ' '), $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()
    $module.FailJson($msg, $_)
}

Set-ModuleResult
$module.ExitJson()
