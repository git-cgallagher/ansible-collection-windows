# converge_cluster.ps1 — create a Windows Server Failover Cluster, or bring
# an existing one in line with the role's variables.
#
# Runs on one of the cluster's nodes (the managing node) with the
# FailoverClusters module. Invoked by roles/wsfc_cluster via
# ansible.windows.win_powershell; also runnable standalone for debugging.
#
# Order of operations:
#   1. find the cluster through any node; refuse a node that belongs to a
#      different cluster
#   2. Test-Cluster (optional) whenever nodes are about to join, then
#      New-Cluster, or Add-ClusterNode for the nodes it is missing; extra
#      nodes are reported, never evicted
#   3. cluster networks: name, role and metric, matched by subnet
#   4. cluster common properties
#   5. named shared disks: optional first-time format of RAW disks,
#      Add-ClusterDisk, rename, optional Cluster Shared Volume
#   6. quorum witness (after the disks, so a disk witness can be one of them)
#
# -ReportOnly (and Ansible check mode) reports every action without changing
# anything; on a cluster that doesn't exist yet it stops after step 2.
#
# Windows PowerShell 5.1-compatible.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string[]]$Nodes,
    [string]$AdministrativeAccessPoint = 'ActiveDirectoryAndDns',
    [string[]]$StaticAddresses = @(),
    [string[]]$IgnoreNetworks = @(),
    [bool]$Validate = $true,
    [string[]]$ValidateIgnore = @(),
    [string]$ReportDir = 'C:\ProgramData\wsfc-iac',
    # Structured settings arrive as JSON: the shape is the role's argument
    # spec, and ConvertFrom-Json is the same on every PowerShell version.
    [string]$QuorumJson = '{}',
    [string]$NetworksJson = '[]',
    [string]$PropertiesJson = '{}',
    [string]$DisksJson = '[]',
    [bool]$ReportOnly = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$inAnsible = $null -ne (Get-Variable -Name Ansible -ErrorAction SilentlyContinue)
if ($inAnsible -and $Ansible.CheckMode) { $ReportOnly = $true }

$actions = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$script:validationReport = ''
$script:created = $false

# Record an action; carry it out unless this is a report-only run.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Change)
    $actions.Add($Description)
    if (-not $ReportOnly) { & $Change }
}

function Get-ShortName {
    param([string]$Computer)
    ($Computer -split '\.')[0].ToUpperInvariant()
}

function Get-Setting {
    param($Object, [string]$Key, $Default = $null)
    if ($null -ne $Object -and $Object.PSObject.Properties[$Key] -and $null -ne $Object.$Key) {
        return $Object.$Key
    }
    $Default
}

# Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object,
# so @($json | ConvertFrom-Json) of '[]' is an array holding an empty array.
# Enumerate it instead.
function ConvertFrom-JsonArray {
    param([string]$Json)
    foreach ($item in ($Json | ConvertFrom-Json)) { $item }
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
    if (-not $Validate) { return }
    if ($ReportOnly) {
        $actions.Add("validate nodes $($TestNodes -join ', ') with Test-Cluster")
        return
    }
    if (-not (Test-Path -LiteralPath $ReportDir)) {
        $null = New-Item -ItemType Directory -Path $ReportDir -Force
    }
    $reportName = Join-Path $ReportDir ('validate-{0}-{1}' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $testParams = @{
        Node = $TestNodes
        ReportName = $reportName
        WarningVariable = 'testWarnings'
        WarningAction = 'SilentlyContinue'
    }
    if ($ValidateIgnore.Count -gt 0) { $testParams.Ignore = $ValidateIgnore }
    $testWarnings = $null
    $report = Test-Cluster @testParams
    if ($null -ne $report) { $script:validationReport = [string]@($report)[0].FullName }
    $text = (@($testWarnings) | ForEach-Object { [string]$_ }) -join ' '
    foreach ($w in @($testWarnings)) { $warnings.Add("Test-Cluster: $w") }
    if ($text -match 'ClusterNotApproved') {
        throw "Test-Cluster failed for $($TestNodes -join ', '); see $($script:validationReport)"
    }
}

function Invoke-Main {
    try {
        Import-Module FailoverClusters
    }
    catch {
        if ($ReportOnly) {
            # A check-mode run before the feature is installed.
            $actions.Add("create cluster $Name with nodes $($Nodes -join ', ') (Failover Clustering isn't installed yet)")
            return
        }
        throw "The FailoverClusters PowerShell module is required (feature RSAT-Clustering-PowerShell): $_"
    }

    $quorum = $QuorumJson | ConvertFrom-Json
    $networks = @(ConvertFrom-JsonArray $NetworksJson)
    $properties = $PropertiesJson | ConvertFrom-Json
    $disks = @(ConvertFrom-JsonArray $DisksJson)
    $wanted = @($Nodes | ForEach-Object { Get-ShortName $_ })
    $local = Get-ShortName $env:COMPUTERNAME

    # --- 1. find the cluster ---------------------------------------------------
    # Through each node rather than by the cluster's name: a cluster without an
    # administrative access point has no name to resolve.
    $cluster = $null
    $via = ''
    foreach ($node in $Nodes) {
        $found = $null
        try {
            $found = Get-Cluster -Name $node -ErrorAction Stop
        }
        catch {
            continue
        }
        if ($found.Name -ne $Name) {
            throw "Node $node already belongs to cluster $($found.Name), not $Name"
        }
        if ($null -eq $cluster) {
            $cluster = $found
            $via = $node
        }
    }

    # --- 2. create, or join missing nodes ------------------------------------
    if ($null -eq $cluster) {
        Invoke-Validation -TestNodes $Nodes
        $newParams = @{
            Name = $Name
            Node = $Nodes
            NoStorage = $true
            AdministrativeAccessPoint = $AdministrativeAccessPoint
        }
        if ($AdministrativeAccessPoint -ne 'None') {
            if ($StaticAddresses.Count -gt 0) { $newParams.StaticAddress = $StaticAddresses }
            if ($IgnoreNetworks.Count -gt 0) { $newParams.IgnoreNetwork = $IgnoreNetworks }
        }
        elseif ($StaticAddresses.Count -gt 0) {
            $warnings.Add('Static addresses are ignored: an administrative access point of None has no IP address')
        }
        Invoke-Change "create cluster $Name with nodes $($Nodes -join ', ') (access point $AdministrativeAccessPoint)" {
            $script:created = $true
            $null = New-Cluster @newParams
        }
        if ($ReportOnly) {
            if ($networks.Count -or $disks.Count -or $properties.PSObject.Properties.Name -or
                $quorum.PSObject.Properties.Name) {
                $warnings.Add('Networks, properties, disks and quorum are planned once the cluster exists')
            }
            return
        }
    }
    else {
        $members = @(Get-ClusterNode -Cluster $via | ForEach-Object { Get-ShortName $_.Name })
        $missing = @($Nodes | Where-Object { $members -notcontains (Get-ShortName $_) })
        if ($missing.Count -gt 0) {
            Invoke-Validation -TestNodes $Nodes
            foreach ($node in $missing) {
                Invoke-Change "add node $node to cluster $Name" {
                    $null = Add-ClusterNode -Cluster $via -Name $node -NoStorage
                }
            }
        }
        foreach ($extra in @($members | Where-Object { $wanted -notcontains $_ })) {
            $warnings.Add("Node $extra is in cluster $Name but not in wsfc_cluster_nodes; it was left in place")
        }
    }

    # Connect through this node from here on: it is a member now, and a node
    # works whether or not the cluster has a name. In a report-only run it may
    # not be a member yet, so use the node the cluster was found through.
    $conn = $local
    if ($ReportOnly -and $via) { $conn = $via }

    # --- 3. networks -----------------------------------------------------------
    $roleValues = @{ none = 0; cluster = 1; cluster_and_client = 3 }
    $clusterNetworks = @(Get-ClusterNetwork -Cluster $conn)
    foreach ($spec in $networks) {
        $subnetText = [string](Get-Setting -Object $spec -Key 'subnet' -Default '')
        if ($subnetText -notmatch '^(.+)/(\d+)$') {
            throw "Network subnet '$subnetText' must be in CIDR form, for example 10.10.10.0/24"
        }
        $subnet = $Matches[1]
        $prefix = [int]$Matches[2]
        $net = $clusterNetworks | Where-Object { Test-NetworkMatch -Network $_ -Subnet $subnet -Prefix $prefix } |
            Select-Object -First 1
        if ($null -eq $net) {
            $warnings.Add("No cluster network matches $subnetText; is a node NIC on that subnet?")
            continue
        }
        $label = $net.Name
        $role = Get-Setting -Object $spec -Key 'role'
        if ($null -ne $role) {
            if (-not $roleValues.ContainsKey([string]$role)) { throw "Network $subnetText has an unknown role '$role'" }
            $want = $roleValues[[string]$role]
            if ([int]$net.Role -ne $want) {
                Invoke-Change "set network $label ($subnetText) role from $([int]$net.Role) to $want ($role)" {
                    $net.Role = $want
                }
            }
        }
        $metric = Get-Setting -Object $spec -Key 'metric'
        if ($null -ne $metric -and [int]$net.Metric -ne [int]$metric) {
            Invoke-Change "set network $label ($subnetText) metric from $($net.Metric) to $metric" {
                $net.Metric = [uint32]$metric
            }
        }
        $newName = [string](Get-Setting -Object $spec -Key 'name' -Default '')
        if ($newName -and $net.Name -ne $newName) {
            Invoke-Change "rename network $label ($subnetText) to $newName" {
                $net.Name = $newName
            }
        }
    }

    # --- 4. common properties --------------------------------------------------
    $clusterObject = Get-Cluster -Name $conn
    foreach ($prop in @($properties.PSObject.Properties)) {
        if (-not $clusterObject.PSObject.Properties[$prop.Name]) {
            throw "Cluster $Name has no common property '$($prop.Name)'"
        }
        $current = [string]$clusterObject.($prop.Name)
        $desired = [string]$prop.Value
        if ($current -ne $desired) {
            Invoke-Change "set cluster property $($prop.Name) from '$current' to '$desired'" {
                $clusterObject.($prop.Name) = $prop.Value
            }
        }
    }

    # --- 5. disks --------------------------------------------------------------
    if ($disks.Count -gt 0) {
        $resources = @(Get-ClusterResource -Cluster $conn)
        $sharedVolumes = @(Get-ClusterSharedVolume -Cluster $conn)
        foreach ($spec in $disks) {
            $diskName = [string](Get-Setting -Object $spec -Key 'name' -Default '')
            $uniqueId = [string](Get-Setting -Object $spec -Key 'unique_id' -Default '')
            $csv = [bool](Get-Setting -Object $spec -Key 'csv' -Default $false)
            if (-not $diskName -or -not $uniqueId) { throw 'Every disk needs a name and a unique_id' }

            # A disk added to CSV leaves Get-ClusterResource for Get-ClusterSharedVolume.
            if ($sharedVolumes | Where-Object { $_.Name -eq $diskName }) {
                if (-not $csv) {
                    $warnings.Add("Disk $diskName is a Cluster Shared Volume but csv is false; it was left as a CSV")
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
                if ([bool](Get-Setting -Object $spec -Key 'initialize' -Default $false)) {
                    $fileSystem = [string](Get-Setting -Object $spec -Key 'file_system' -Default 'NTFS')
                    $unitSize = [int](Get-Setting -Object $spec -Key 'allocation_unit_size' -Default 65536)
                    $volumeLabel = [string](Get-Setting -Object $spec -Key 'label' -Default '')
                    if (-not $volumeLabel) { $volumeLabel = $diskName }
                    Invoke-Change "initialize disk $($disk.Number) ($diskName) as GPT and format it $fileSystem ($unitSize-byte units)" {
                        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
                        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
                        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
                        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize
                        $null = Format-Volume -Partition $partition -FileSystem $fileSystem -AllocationUnitSize $unitSize `
                            -NewFileSystemLabel $volumeLabel -Confirm:$false
                    }
                }
                else {
                    $warnings.Add("Disk $diskName (disk $($disk.Number)) is RAW; set initialize to format it")
                }
            }
            $available = $null
            if (-not $ReportOnly) {
                $available = Get-ClusterAvailableDisk -Cluster $conn | Where-Object { $_.Number -eq $disk.Number } |
                    Select-Object -First 1
                if ($null -eq $available) {
                    throw ("Disk $diskName (disk $($disk.Number) on $local) isn't available to cluster $Name. " +
                        'It must be visible to every node and not already be a cluster disk under another name.')
                }
            }
            Invoke-Change "add disk $($disk.Number) to cluster $Name as $diskName$(if ($csv) { ' (CSV)' })" {
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

$failed = $false
$errorText = ''
try {
    Invoke-Main
}
catch {
    $failed = $true
    $errorText = $_.Exception.Message
    if (-not $inAnsible) { throw }
}

$result = @{
    cluster = $Name
    report_only = $ReportOnly
    created = $script:created
    actions = @($actions)
    warnings = @($warnings)
    validation_report = $script:validationReport
}
if ($inAnsible) {
    # A report-only run that found work reports "changed", like check mode.
    $Ansible.Changed = $actions.Count -gt 0
    $Ansible.Result = $result
    if ($failed) {
        $Ansible.Failed = $true
        $result.error = $errorText
    }
}
else {
    [pscustomobject]$result
}
