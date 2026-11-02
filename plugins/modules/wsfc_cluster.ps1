#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic

# Create a Windows Server Failover Cluster, or bring an existing one in line
# with the options. Runs on one of the cluster's nodes (the managing node)
# with the FailoverClusters module.
#
# Order of operations:
#   1. find the cluster through any node; refuse a node that belongs to a
#      different cluster
#   2. Test-Cluster (optional) whenever nodes are about to join, then
#      New-Cluster, or Add-ClusterNode for the nodes it is missing; extra
#      nodes are reported, never evicted
#   3. cluster networks: name, role and metric, matched by subnet; then
#      remove cluster name addresses on ignored networks (never the last)
#   4. cluster common properties
#   5. named shared disks: optional first-time format of RAW disks,
#      Add-ClusterDisk, rename, optional Cluster Shared Volume
#   6. quorum witness (after the disks, so a disk witness can be one of them)
#
# Check mode reports every action without changing anything; on a cluster
# that doesn't exist yet it stops after step 2.
#
# The argument spec and Create come first: ansible-test's validate-modules
# runs this file under pwsh on Linux up to Create to read the spec.
$spec = @{
    options = @{
        name = @{ type = 'str'; required = $true }
        nodes = @{ type = 'list'; elements = 'str'; required = $true }
        administrative_access_point = @{
            type = 'str'
            default = 'ActiveDirectoryAndDns'
            choices = 'ActiveDirectoryAndDns', 'Dns', 'None'
        }
        static_addresses = @{ type = 'list'; elements = 'str' }
        ignore_networks = @{ type = 'list'; elements = 'str' }
        validate = @{ type = 'bool'; default = $true }
        validate_ignore = @{ type = 'list'; elements = 'str' }
        report_dir = @{ type = 'str'; default = 'C:\ProgramData\wsfc-iac' }
        quorum = @{
            type = 'dict'
            options = @{
                type = @{ type = 'str'; choices = 'node_majority', 'disk_witness', 'file_share_witness', 'cloud_witness' }
                disk = @{ type = 'str' }
                path = @{ type = 'str' }
                account_name = @{ type = 'str' }
                access_key = @{ type = 'str'; no_log = $true }
                endpoint = @{ type = 'str' }
            }
            required_if = @(
                @('type', 'disk_witness', @('disk')),
                @('type', 'file_share_witness', @('path')),
                @('type', 'cloud_witness', @('account_name'))
            )
        }
        networks = @{
            type = 'list'
            elements = 'dict'
            options = @{
                subnet = @{ type = 'str'; required = $true }
                name = @{ type = 'str' }
                role = @{ type = 'str'; choices = 'none', 'cluster', 'cluster_and_client' }
                metric = @{ type = 'int' }
            }
        }
        properties = @{ type = 'dict' }
        disks = @{
            type = 'list'
            elements = 'dict'
            options = @{
                name = @{ type = 'str'; required = $true }
                unique_id = @{ type = 'str'; required = $true }
                csv = @{ type = 'bool'; default = $false }
                initialize = @{ type = 'bool'; default = $false }
                file_system = @{ type = 'str'; default = 'NTFS'; choices = 'NTFS', 'ReFS' }
                allocation_unit_size = @{ type = 'int'; default = 65536 }
                label = @{ type = 'str' }
                drive_letter = @{ type = 'str' }
            }
        }
    }
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# The module runs non-interactively, where a prompt fails the run
# ("PowerShell is in NonInteractive mode", seen from New-Cluster in the lab).
# The clustering cmdlets have no -Confirm; New-Cluster gets -Force (below).
$ConfirmPreference = 'None'

$name = $module.Params.name
$nodes = @($module.Params.nodes)
$accessPoint = $module.Params.administrative_access_point
$validate = $module.Params.validate
$reportDir = $module.Params.report_dir
$checkMode = $module.CheckMode

# A list option left out arrives as $null, and @($null).Count is 1.
function Get-ListParam {
    param([string]$Key)
    $value = $module.Params[$Key]
    if ($null -eq $value) { return @() }
    @($value)
}

$staticAddresses = Get-ListParam 'static_addresses'
$ignoreNetworks = Get-ListParam 'ignore_networks'
$validateIgnore = Get-ListParam 'validate_ignore'
$networks = Get-ListParam 'networks'
$disks = Get-ListParam 'disks'
$quorum = $module.Params.quorum
if ($null -eq $quorum) { $quorum = @{} }
$properties = $module.Params.properties
if ($null -eq $properties) { $properties = @{} }

$actions = New-Object System.Collections.Generic.List[string]
$script:validationReport = ''
$script:created = $false

# Record an action; carry it out unless this is a check-mode run.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Change)
    $actions.Add($Description)
    if (-not $checkMode) { & $Change }
}

function Get-ShortName {
    param([string]$Computer)
    ($Computer -split '\.')[0].ToUpperInvariant()
}

# A sub-option that was left out is $null; an empty string counts as left out
# too, so a role can pass '' for "not set".
function Get-Setting {
    param($Object, [string]$Key, $Default = $null)
    if ($null -ne $Object -and $Object.ContainsKey($Key) -and $null -ne $Object[$Key] -and [string]$Object[$Key] -ne '') {
        return $Object[$Key]
    }
    $Default
}

function Get-ResourceTypeName {
    param($Resource)
    $type = $Resource.ResourceType
    if ($null -ne $type -and $type.PSObject.Properties['Name']) { return [string]$type.Name }
    [string]$type
}

function Test-NetworkMatch {
    param($Network, [string]$Subnet, [int]$Prefix)
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

# Test-Cluster doesn't throw when a test fails; it ends with a warning that
# names the result. ClusterNotApproved means at least one test failed.
function Invoke-Validation {
    param([string[]]$TestNodes)
    if (-not $validate) { return }
    if ($checkMode) {
        $actions.Add("validate nodes $($TestNodes -join ', ') with Test-Cluster")
        return
    }
    if (-not (Test-Path -LiteralPath $reportDir)) {
        $null = New-Item -ItemType Directory -Path $reportDir -Force
    }
    $reportName = Join-Path -Path $reportDir -ChildPath ('validate-{0}-{1}' -f $name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $testParams = @{
        Node = $TestNodes
        ReportName = $reportName
        WarningVariable = 'testWarnings'
        WarningAction = 'SilentlyContinue'
    }
    if ($validateIgnore.Count -gt 0) { $testParams.Ignore = $validateIgnore }
    $testWarnings = $null
    $report = Test-Cluster @testParams
    if ($null -ne $report) { $script:validationReport = [string]@($report)[0].FullName }
    $text = (@($testWarnings) | ForEach-Object { [string]$_ }) -join ' '
    foreach ($w in @($testWarnings)) { $module.Warn("Test-Cluster: $w") }
    if ($text -match 'ClusterNotApproved') {
        throw "Test-Cluster failed for $($TestNodes -join ', '); see $($script:validationReport)"
    }
}

# New-Cluster -Force also wipes stale cluster configuration from the nodes.
# A node whose cluster database exists but that no cluster answered for may
# be a member of a cluster that is down: refuse rather than wipe it.
function Assert-NoClusterDatabase {
    param([string[]]$TestNodes)
    foreach ($node in $TestNodes) {
        if ((Get-ShortName $node) -eq (Get-ShortName $env:COMPUTERNAME)) {
            $db = Join-Path -Path $env:windir -ChildPath 'Cluster\CLUSDB'
        }
        else {
            $db = "\\$node\ADMIN$\Cluster\CLUSDB"
        }
        if (Test-Path -LiteralPath $db) {
            throw ("Node $node has a cluster database ($db) but no cluster answered through it. It may belong to " +
                'a cluster that is down. If it is stale, run Clear-ClusterNode on it, then re-run.')
        }
    }
}

function Invoke-Main {
    try {
        Import-Module -Name FailoverClusters
    }
    catch {
        if ($checkMode) {
            # A check-mode run before the feature is installed.
            $actions.Add("create cluster $name with nodes $($nodes -join ', ') (Failover Clustering isn't installed yet)")
            return
        }
        throw "The FailoverClusters PowerShell module is required (feature RSAT-Clustering-PowerShell): $($_.Exception.Message)"
    }

    $wanted = @($nodes | ForEach-Object { Get-ShortName $_ })
    $local = Get-ShortName $env:COMPUTERNAME

    # --- 1. find the cluster ---------------------------------------------------
    # Through each node rather than by the cluster's name: a cluster without an
    # administrative access point has no name to resolve.
    $cluster = $null
    $via = ''
    foreach ($node in $nodes) {
        $found = $null
        try {
            $found = Get-Cluster -Name $node -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($found.Name -ne $name) {
            throw "Node $node already belongs to cluster $($found.Name), not $name"
        }
        if ($null -eq $cluster) {
            $cluster = $found
            $via = $node
        }
    }

    # --- 2. create, or join missing nodes ------------------------------------
    if ($null -eq $cluster) {
        Invoke-Validation -TestNodes $nodes
        $newParams = @{
            Name = $name
            Node = $nodes
            NoStorage = $true
            AdministrativeAccessPoint = $accessPoint
        }
        if ($accessPoint -ne 'None') {
            if ($staticAddresses.Count -gt 0) { $newParams.StaticAddress = $staticAddresses }
            if ($ignoreNetworks.Count -gt 0) { $newParams.IgnoreNetwork = $ignoreNetworks }
        }
        elseif ($staticAddresses.Count -gt 0) {
            $module.Warn('Static addresses are ignored: an administrative access point of None has no IP address')
        }
        Invoke-Change "create cluster $name with nodes $($nodes -join ', ') (access point $accessPoint)" {
            Assert-NoClusterDatabase -TestNodes $nodes
            $null = New-Cluster @newParams -Force
            $script:created = $true
        }
        if ($checkMode) {
            if ($networks.Count -or $disks.Count -or $properties.Count -or (Get-Setting -Object $quorum -Key 'type')) {
                $module.Warn('Networks, properties, disks and quorum are planned once the cluster exists')
            }
            return
        }
    }
    else {
        $members = @(Get-ClusterNode -Cluster $via | ForEach-Object { Get-ShortName $_.Name })
        $missing = @($nodes | Where-Object { $members -notcontains (Get-ShortName $_) })
        if ($missing.Count -gt 0) {
            Invoke-Validation -TestNodes $nodes
            foreach ($node in $missing) {
                Invoke-Change "add node $node to cluster $name" {
                    $null = Add-ClusterNode -Cluster $via -Name $node -NoStorage
                }
            }
        }
        foreach ($extra in @($members | Where-Object { $wanted -notcontains $_ })) {
            $module.Warn("Node $extra is in cluster $name but not in nodes; it was left in place")
        }
    }

    # Connect through this node from here on: it is a member now, and a node
    # works whether or not the cluster has a name. In a check-mode run it may
    # not be a member yet, so use the node the cluster was found through.
    $conn = $local
    if ($checkMode -and $via) { $conn = $via }

    # --- 3. networks -----------------------------------------------------------
    $roleValues = @{ none = 0; cluster = 1; cluster_and_client = 3 }
    $clusterNetworks = @(Get-ClusterNetwork -Cluster $conn)
    foreach ($netSpec in $networks) {
        $subnetText = [string]$netSpec.subnet
        if ($subnetText -notmatch '^(.+)/(\d+)$') {
            throw "Network subnet '$subnetText' must be in CIDR form, for example 10.10.10.0/24"
        }
        $subnet = $Matches[1]
        $prefix = [int]$Matches[2]
        $net = $clusterNetworks | Where-Object { Test-NetworkMatch -Network $_ -Subnet $subnet -Prefix $prefix } |
            Select-Object -First 1
        if ($null -eq $net) {
            $module.Warn("No cluster network matches $subnetText; is a node NIC on that subnet?")
            continue
        }
        $label = $net.Name
        $role = Get-Setting -Object $netSpec -Key 'role'
        if ($null -ne $role) {
            $want = $roleValues[[string]$role]
            if ([int]$net.Role -ne $want) {
                Invoke-Change "set network $label ($subnetText) role from $([int]$net.Role) to $want ($role)" {
                    $net.Role = $want
                }
            }
        }
        $metric = Get-Setting -Object $netSpec -Key 'metric'
        if ($null -ne $metric -and [int]$net.Metric -ne [int]$metric) {
            Invoke-Change "set network $label ($subnetText) metric from $($net.Metric) to $metric" {
                $net.Metric = [uint32]$metric
            }
        }
        $newName = [string](Get-Setting -Object $netSpec -Key 'name' -Default '')
        if ($newName -and $net.Name -ne $newName) {
            Invoke-Change "rename network $label ($subnetText) to $newName" {
                $net.Name = $newName
            }
        }
    }

    # --- 3b. cluster name addresses on ignored networks -------------------------
    # New-Cluster -IgnoreNetwork still gave the cluster name a DHCP address on
    # an ignored network in the lab (2026-11-01), which the name then
    # registers in DNS. Remove such addresses; the name keeps its others.
    if ($ignoreNetworks.Count -gt 0 -and $accessPoint -ne 'None') {
        $nameAddresses = @(Get-ClusterResource -Cluster $conn | Where-Object {
                (Get-ResourceTypeName $_) -eq 'IP Address' -and [string]$_.OwnerGroup.Name -eq 'Cluster Group' })
        $remaining = $nameAddresses.Count
        foreach ($ip in $nameAddresses) {
            $netName = [string]($ip | Get-ClusterParameter -Name Network).Value
            $ipNet = Get-ClusterNetwork -Cluster $conn | Where-Object { $_.Name -eq $netName } | Select-Object -First 1
            if ($null -eq $ipNet) { continue }
            $ignored = $false
            foreach ($cidr in $ignoreNetworks) {
                if ($cidr -match '^(.+)/(\d+)$' -and (Test-NetworkMatch -Network $ipNet -Subnet $Matches[1] -Prefix ([int]$Matches[2]))) {
                    $ignored = $true
                }
            }
            if (-not $ignored) { continue }
            if ($remaining -le 1) {
                $module.Warn("The cluster name's only address, $($ip.Name), is on ignored network $netName; it was left")
                continue
            }
            $address = [string]($ip | Get-ClusterParameter -Name Address).Value
            $remaining--
            Invoke-Change "remove cluster name address $address ($($ip.Name)) on ignored network $netName" {
                $nameResource = Get-ClusterResource -Cluster $conn | Where-Object {
                    (Get-ResourceTypeName $_) -eq 'Network Name' -and [string]$_.OwnerGroup.Name -eq 'Cluster Group' } |
                    Select-Object -First 1
                $null = Stop-ClusterResource -Cluster $conn -Name $ip.Name
                if ($null -ne $nameResource) {
                    $null = Remove-ClusterResourceDependency -Cluster $conn -Resource $nameResource.Name -Provider $ip.Name
                }
                Remove-ClusterResource -Cluster $conn -Name $ip.Name -Force
            }
        }
    }

    # --- 4. common properties --------------------------------------------------
    $clusterObject = Get-Cluster -Name $conn
    foreach ($propName in @($properties.Keys)) {
        if (-not $clusterObject.PSObject.Properties[$propName]) {
            throw "Cluster $name has no common property '$propName'"
        }
        $current = [string]$clusterObject.$propName
        $desired = [string]$properties[$propName]
        if ($current -ne $desired) {
            Invoke-Change "set cluster property $propName from '$current' to '$desired'" {
                $clusterObject.$propName = $properties[$propName]
            }
        }
    }

    # --- 5. disks --------------------------------------------------------------
    if ($disks.Count -gt 0) {
        $resources = @(Get-ClusterResource -Cluster $conn)
        $sharedVolumes = @(Get-ClusterSharedVolume -Cluster $conn)
        foreach ($diskSpec in $disks) {
            $diskName = [string]$diskSpec.name
            $uniqueId = [string]$diskSpec.unique_id
            $csv = [bool]$diskSpec.csv
            if (-not $diskName -or -not $uniqueId) { throw 'Every disk needs a name and a unique_id' }

            # A disk added to CSV leaves Get-ClusterResource for Get-ClusterSharedVolume.
            if ($sharedVolumes | Where-Object { $_.Name -eq $diskName }) {
                if (-not $csv) {
                    $module.Warn("Disk $diskName is a Cluster Shared Volume but csv is false; it was left as a CSV")
                }
                continue
            }
            $existing = $resources | Where-Object { $_.Name -eq $diskName } | Select-Object -First 1
            if ($null -ne $existing) {
                $typeName = Get-ResourceTypeName $existing
                if ($typeName -ne 'Physical Disk') {
                    throw "Cluster resource $diskName is a '$typeName', not a Physical Disk"
                }
                if ($csv) {
                    Invoke-Change "add disk $diskName to Cluster Shared Volumes" {
                        $null = Add-ClusterSharedVolume -Cluster $conn -Name $diskName
                    }
                }
                continue
            }

            $disk = Get-Disk | Where-Object { $_.UniqueId -eq $uniqueId } | Select-Object -First 1
            if ($null -eq $disk) {
                throw "Disk $diskName : no disk on $local has UniqueId $uniqueId (Get-Disk | Select-Object Number, UniqueId)"
            }
            if ([string]$disk.PartitionStyle -eq 'RAW') {
                if ([bool]$diskSpec.initialize) {
                    $fileSystem = [string]$diskSpec.file_system
                    $unitSize = [int]$diskSpec.allocation_unit_size
                    $volumeLabel = [string](Get-Setting -Object $diskSpec -Key 'label' -Default '')
                    if (-not $volumeLabel) { $volumeLabel = $diskName }
                    $driveLetter = [string](Get-Setting -Object $diskSpec -Key 'drive_letter' -Default '')
                    $partitionParams = @{ DiskNumber = $disk.Number; UseMaximumSize = $true }
                    if ($driveLetter) { $partitionParams.DriveLetter = $driveLetter.TrimEnd(':').ToUpperInvariant() }
                    Invoke-Change "initialize disk $($disk.Number) ($diskName) as GPT and format it $fileSystem ($unitSize-byte units)" {
                        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
                        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
                        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
                        $partition = New-Partition @partitionParams
                        $null = Format-Volume -Partition $partition -FileSystem $fileSystem -AllocationUnitSize $unitSize `
                            -NewFileSystemLabel $volumeLabel
                    }
                }
                else {
                    $module.Warn("Disk $diskName (disk $($disk.Number)) is RAW; set initialize to format it")
                }
            }
            $available = $null
            if (-not $checkMode) {
                $available = Get-ClusterAvailableDisk -Cluster $conn | Where-Object { $_.Number -eq $disk.Number } |
                    Select-Object -First 1
                if ($null -eq $available) {
                    throw ("Disk $diskName (disk $($disk.Number) on $local) isn't available to cluster $name. " +
                        'It must be visible to every node and not already be a cluster disk under another name.')
                }
            }
            Invoke-Change "add disk $($disk.Number) to cluster $name as $diskName$(if ($csv) { ' (CSV)' })" {
                $resource = $available | Add-ClusterDisk
                $resource.Name = $diskName
                if ($csv) { $null = Add-ClusterSharedVolume -Cluster $conn -Name $diskName }
            }
        }
    }

    # --- 6. quorum ----------------------------------------------------------------
    $quorumType = [string](Get-Setting -Object $quorum -Key 'type' -Default '')
    if ($quorumType) {
        $current = Get-ClusterQuorum -Cluster $conn
        $witness = $current.QuorumResource
        $witnessType = ''
        if ($null -ne $witness) { $witnessType = Get-ResourceTypeName $witness }
        switch ($quorumType) {
            'node_majority' {
                if ($null -ne $witness) {
                    Invoke-Change "remove the $witnessType witness (node majority)" {
                        $null = Set-ClusterQuorum -Cluster $conn -NoWitness
                    }
                }
            }
            'disk_witness' {
                $witnessDisk = [string](Get-Setting -Object $quorum -Key 'disk' -Default '')
                if (-not $witnessDisk) { throw 'A disk_witness quorum needs disk (a cluster disk resource name)' }
                if ($witnessType -ne 'Physical Disk' -or $witness.Name -ne $witnessDisk) {
                    Invoke-Change "set the quorum witness to disk $witnessDisk" {
                        $null = Set-ClusterQuorum -Cluster $conn -DiskWitness $witnessDisk
                    }
                }
            }
            'file_share_witness' {
                $sharePath = [string](Get-Setting -Object $quorum -Key 'path' -Default '')
                if (-not $sharePath) { throw 'A file_share_witness quorum needs path (a UNC path)' }
                $currentPath = ''
                if ($witnessType -eq 'File Share Witness') {
                    $currentPath = [string]($witness | Get-ClusterParameter -Name SharePath).Value
                }
                if ($currentPath -ne $sharePath) {
                    Invoke-Change "set the quorum witness to file share $sharePath" {
                        $null = Set-ClusterQuorum -Cluster $conn -FileShareWitness $sharePath
                    }
                }
            }
            'cloud_witness' {
                $account = [string](Get-Setting -Object $quorum -Key 'account_name' -Default '')
                $endpoint = [string](Get-Setting -Object $quorum -Key 'endpoint' -Default '')
                if (-not $account) { throw 'A cloud_witness quorum needs account_name' }
                $currentAccount = ''
                $currentEndpoint = ''
                if ($witnessType -eq 'Cloud Witness') {
                    $currentAccount = [string]($witness | Get-ClusterParameter -Name AccountName).Value
                    $currentEndpoint = [string]($witness | Get-ClusterParameter -Name EndpointInfo).Value
                }
                $endpointDiffers = $endpoint -and ($currentEndpoint -ne $endpoint)
                if ($currentAccount -ne $account -or $endpointDiffers) {
                    $accessKey = [string](Get-Setting -Object $quorum -Key 'access_key' -Default '')
                    if (-not $accessKey) { throw 'A cloud_witness quorum needs access_key to create or change the witness' }
                    Invoke-Change "set the quorum witness to Azure storage account $account" {
                        $witnessParams = @{ Cluster = $conn; CloudWitness = $true; AccountName = $account; AccessKey = $accessKey }
                        if ($endpoint) { $witnessParams.Endpoint = $endpoint }
                        $null = Set-ClusterQuorum @witnessParams
                    }
                }
            }
            default { throw "Unknown quorum type '$quorumType'" }
        }
    }
}

# The result is filled in before a failure is reported, so a run that stopped
# halfway still says what it did (changed, actions) and what it planned.
function Set-ModuleResult {
    $module.Result.cluster = $name
    $module.Result.created = $script:created
    $module.Result.actions = @($actions)
    $module.Result.validation_report = $script:validationReport
    # Diagnostic only (the double hop); never worth failing the run for.
    try {
        $module.Result.identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    catch {
        $module.Result.identity = ''
    }
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
    $msg = '{0} (at line {1}: {2})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()
    $module.FailJson($msg, $_)
}

Set-ModuleResult
$module.ExitJson()
