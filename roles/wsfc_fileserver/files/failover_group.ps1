#Requires -Version 5.1
# Moves a clustered file server's group to another node and waits for it to
# come online there (a planned failover). Run on a cluster node by the
# failover entry point; with -ReportOnly it only reports the move.
#
# -Mode state reads the group without moving it (the validate entry point,
# and the failover entry point before it writes its markers).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    [ValidateSet('state', 'move')]
    [string]$Mode = 'state',

    [string]$TargetNode = '',

    [int]$TimeoutSeconds = 300,

    [bool]$ReportOnly = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$inAnsible = $null -ne (Get-Variable -Name Ansible -ErrorAction SilentlyContinue)

function Get-GroupState {
    param([string]$Conn)
    $group = Get-ClusterGroup -Cluster $Conn -Name $Name
    [ordered]@{
        state = [string]$group.State
        owner = [string]$group.OwnerNode.Name
        # Strings: win_powershell renders objects nested this deep as their type name.
        resources = @(Get-ClusterResource -Cluster $Conn | Where-Object { $_.OwnerGroup.Name -eq $Name } |
                ForEach-Object { '{0} ({1}): {2}' -f $_.Name, $_.ResourceType.Name, $_.State })
    }
}

$moved = $false
$failed = $false
$errorText = ''
$result = [ordered]@{ name = $Name; mode = $Mode; report_only = [bool]$ReportOnly }
try {
    Import-Module FailoverClusters
    $conn = $env:COMPUTERNAME
    $before = Get-GroupState -Conn $conn
    $result.before = $before
    $result.nodes_up = @(Get-ClusterNode -Cluster $conn | Where-Object { [string]$_.State -eq 'Up' } |
            ForEach-Object { $_.Name })

    if ($Mode -eq 'move') {
        $target = $TargetNode
        if (-not $target) {
            # Another node that is up, the group's preferred owners first.
            $preferred = @(Get-ClusterOwnerNode -Cluster $conn -Group $Name).OwnerNodes | ForEach-Object { $_.Name }
            $candidates = @($preferred) + @($result.nodes_up) | Where-Object { $_ -and $_ -ne $before.owner -and $result.nodes_up -contains $_ }
            $target = @($candidates)[0]
            if (-not $target) { throw "No other node is up to move $Name to (nodes up: $($result.nodes_up -join ', '))" }
        }
        elseif ($result.nodes_up -notcontains $target) {
            throw "Node $target is not an up node of this cluster (nodes up: $($result.nodes_up -join ', '))"
        }
        if ($target -eq $before.owner) { throw "$Name is already owned by $target" }
        $result.from = $before.owner
        $result.to = $target

        if (-not $ReportOnly) {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Move-ClusterGroup -Cluster $conn -Name $Name -Node $target -Wait $TimeoutSeconds
            $moved = $true
            # -Wait returns once the move ends, online or not; give the group
            # the rest of the timeout to settle.
            do {
                $after = Get-GroupState -Conn $conn
                if ($after.state -eq 'Online' -and $after.owner -eq $target) { break }
                Start-Sleep -Seconds 2
            } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
            $watch.Stop()
            $result.seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
            $result.after = $after
            if ($after.state -ne 'Online' -or $after.owner -ne $target) {
                throw "$Name is $($after.state) on $($after.owner) after $($result.seconds) s, expected Online on $target"
            }
        }
    }
}
catch {
    $failed = $true
    $errorText = '{0} (at line {1}: {2})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber,
    $_.InvocationInfo.Line.Trim()
    if (-not $inAnsible) { throw }
}

$result.moved = $moved
if ($inAnsible) {
    $Ansible.Changed = $moved
    if ($failed) {
        $result.error = $errorText
        $Ansible.Failed = $true
    }
    $Ansible.Result = $result
}
else {
    [pscustomobject]$result
}
