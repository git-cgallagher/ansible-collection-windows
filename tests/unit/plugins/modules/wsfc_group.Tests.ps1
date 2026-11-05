# Pester 5 unit tests for wsfc_group's logic: Get-WsfcGroupPlan and
# ConvertTo-WsfcHour from plugins/module_utils/_WsfcCommon.psm1, which decide
# what to change on a cluster group, and the module's wiring to that util. The
# module's behaviour against a cluster is its integration target
# (tests/integration/targets/wsfc_group). Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/wsfc_group.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_WsfcCommon.psm1') -Force

    # A group as the module reads it: no preferred owners, failback prevented,
    # no window, and one resource with a common and a private property.
    function script:New-Group {
        param([string]$Owner = 'NODE1', [string[]]$PreferredOwners = @(), [object[]]$Resources = $null)
        if ($null -eq $Resources) {
            $Resources = @(@{
                    name = 'App'; type = 'Generic Application'
                    properties = @{ RestartThreshold = [uint32]1; Description = '' }
                    parameters = @{ CommandLine = 'app.exe'; UseNetworkName = [uint32]0 }
                })
        }
        @{
            name = 'Test Group'
            owner = $Owner
            preferred_owners = $PreferredOwners
            properties = @{
                Description = ''
                Priority = [uint32]2000
                AutoFailbackType = [uint32]0
                FailbackWindowStart = [uint32]4294967295
                FailbackWindowEnd = [uint32]4294967295
            }
            resources = $Resources
        }
    }

    function script:Invoke-Plan {
        param([hashtable]$Options = @{}, [hashtable]$Group = (New-Group))
        $plan = @{ Group = $Group; ClusterNodes = @('NODE1', 'NODE2'); NodesUp = @('NODE1', 'NODE2') }
        foreach ($k in $Options.Keys) { $plan[$k] = $Options[$k] }
        Get-WsfcGroupPlan @plan
    }

    $script:agGroup = New-Group -Resources @(
        @{ name = 'AG1'; type = 'SQL Server Availability Group'; properties = @{ RestartThreshold = [uint32]3 }; parameters = @{} },
        @{ name = 'AG1_LISTENER'; type = 'Network Name'; properties = @{}; parameters = @{ HostRecordTTL = [uint32]1200 } }
    )
}

AfterAll {
    Remove-Module _WsfcCommon -ErrorAction SilentlyContinue
}

Describe 'wsfc_group''s wiring' {
    BeforeAll {
        $script:text = Get-Content -LiteralPath $script:modulePath -Raw
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
        $script:defined = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
    }

    It 'loads the shared util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._WsfcCommon$'
    }

    It 'defines none of the util''s functions itself' {
        foreach ($name in 'Get-ShortName', 'Get-Setting', 'Get-ResourceTypeName', 'Get-WsfcGroupPlan', 'ConvertTo-WsfcHour') {
            $script:defined | Should -Not -Contain $name
        }
    }

    It 'plans with Get-WsfcGroupPlan' {
        $script:text | Should -Match 'Get-WsfcGroupPlan @planParams'
    }
}

Describe 'ConvertTo-WsfcHour' {
    It 'reads the stored "no window" as -1 and an hour as itself' {
        ConvertTo-WsfcHour ([uint32]4294967295) | Should -Be -1
        ConvertTo-WsfcHour ([uint32]3) | Should -Be 3
        ConvertTo-WsfcHour '0' | Should -Be 0
    }
}

Describe 'Get-WsfcGroupPlan' {
    It 'plans nothing when the group already matches' {
        $options = @{
            Properties = @{ Priority = 2000; description = '' }
            Failback = @{ allowed = $false; window_start = -1; window_end = -1 }
            Resources = @(@{ name = 'app'; properties = @{ RestartThreshold = 1 }; parameters = @{ CommandLine = 'app.exe' } })
            Owner = 'node1.lab.example.com'
        }
        $plan = Invoke-Plan -Options $options
        @($plan.Actions).Count | Should -Be 0
        @($plan.Warnings).Count | Should -Be 0
    }

    It 'sets the properties that differ, comparing as strings' {
        $plan = Invoke-Plan -Options @{ Properties = @{ Priority = '3000'; Description = 'Test' } }
        @($plan.Actions | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('Description', 'Priority')
        ($plan.Actions | Where-Object { $_.Name -eq 'Priority' }).From | Should -Be '2000'
        ($plan.Actions | Where-Object { $_.Name -eq 'Priority' }).Value | Should -Be '3000'
    }

    It 'turns failback into its three properties, with -1 stored as 4294967295' {
        $plan = Invoke-Plan -Options @{ Failback = @{ allowed = $true; window_start = 1; window_end = 4 } } -Group (New-Group -PreferredOwners @('NODE1'))
        @($plan.Actions | ForEach-Object { $_.Name }) | Should -Be @('AutoFailbackType', 'FailbackWindowStart', 'FailbackWindowEnd')
        $plan.Actions[0].Value | Should -Be 1
        $plan.Actions[1].From | Should -Be -1
        $plan.Actions[1].To | Should -Be 1
        $plan.Actions[1].Value | Should -BeOfType [uint32]

        $group = New-Group
        $group.properties.FailbackWindowStart = [uint32]1
        $group.properties.FailbackWindowEnd = [uint32]4
        $back = Invoke-Plan -Options @{ Failback = @{ window_start = -1; window_end = -1 } } -Group $group
        $back.Actions[0].Value | Should -Be ([uint32]4294967295)
        $back.Actions[0].To | Should -Be -1
    }

    It 'leaves the failback setting alone when the option leaves it out' {
        $plan = Invoke-Plan -Options @{ Failback = @{ allowed = $null; window_start = $null; window_end = $null } }
        @($plan.Actions).Count | Should -Be 0
    }

    It 'warns that failback needs preferred owners' {
        $plan = Invoke-Plan -Options @{ Failback = @{ allowed = $true } }
        $plan.Warnings | Should -Be @('Failback has no effect on group Test Group until it has preferred owners')
        $withOwners = Invoke-Plan -Options @{ Failback = @{ allowed = $true }; PreferredOwners = @('NODE2') }
        @($withOwners.Warnings).Count | Should -Be 0
    }

    It 'converges the preferred owners as an ordered list' {
        $plan = Invoke-Plan -Options @{ PreferredOwners = @('node2', 'NODE1') } -Group (New-Group -PreferredOwners @('NODE1', 'NODE2'))
        $plan.Actions[0].Kind | Should -Be 'SetPreferredOwners'
        $plan.Actions[0].To | Should -Be @('NODE2', 'NODE1')
        $same = Invoke-Plan -Options @{ PreferredOwners = @('node1', 'node2.lab.example.com') } -Group (New-Group -PreferredOwners @('NODE1', 'NODE2'))
        @($same.Actions).Count | Should -Be 0
    }

    It 'sets resource properties and private properties that differ' {
        $app = @{ name = 'App'; properties = @{ RestartThreshold = 2 }; parameters = @{ CommandLine = 'other.exe'; UseNetworkName = 0 } }
        $plan = Invoke-Plan -Options @{ Resources = @($app) }
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('SetResourceProperty', 'SetResourceParameters')
        @($plan.Actions[1].Changes).Count | Should -Be 1
        $plan.Actions[1].Changes[0].Name | Should -Be 'CommandLine'
        $plan.Actions[1].Changes[0].From | Should -Be 'app.exe'
    }

    It 'sets a resource''s private properties together, in one action' {
        $app = @{ name = 'App'; parameters = @{ CommandLine = 'other.exe'; UseNetworkName = 1 } }
        $plan = Invoke-Plan -Options @{ Resources = @($app) }
        @($plan.Actions).Count | Should -Be 1
        $plan.Actions[0].Resource | Should -Be 'App'
        @($plan.Actions[0].Changes | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('CommandLine', 'UseNetworkName')
    }

    It 'moves the group last, to the node''s own name' {
        $options = @{ Owner = 'node2.lab.example.com'; Properties = @{ Priority = 1000 }; PreferredOwners = @('NODE2') }
        $plan = Invoke-Plan -Options $options
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('SetGroupProperty', 'SetPreferredOwners', 'Move')
        $plan.Actions[2].From | Should -Be 'NODE1'
        $plan.Actions[2].To | Should -Be 'NODE2'
    }

    It 'still lets other resources in an availability group''s group be set' {
        $options = @{ Resources = @(@{ name = 'AG1_LISTENER'; parameters = @{ HostRecordTTL = 300 } }) }
        $plan = Invoke-Plan -Options $options -Group $script:agGroup
        $plan.Actions[0].Kind | Should -Be 'SetResourceParameters'
        $plan.Actions[0].Resource | Should -Be 'AG1_LISTENER'
    }

    It 'refuses <Case>' -ForEach @(
        @{
            Case = 'an unknown group property'; Options = @{ Properties = @{ NoSuch = 1 } }
            Message = "Group Test Group has no common property 'NoSuch'"
        }
        @{
            Case = 'failback set two ways'; Options = @{ Failback = @{ allowed = $true }; Properties = @{ AutoFailbackType = 1 } }
            Message = 'Set failback with failback or with properties.AutoFailbackType, not both'
        }
        @{
            Case = 'half a failback window'; Options = @{ Failback = @{ window_start = 1 } }
            Message = 'failback needs both window_start and window_end*'
        }
        @{
            Case = 'a window hour out of range'; Options = @{ Failback = @{ window_start = 1; window_end = 24 } }
            Message = 'FailbackWindowEnd must be -1*not 24'
        }
        @{
            Case = 'a preferred owner outside the cluster'; Options = @{ PreferredOwners = @('NODE9') }
            Message = "Node NODE9 in preferred_owners isn't in the cluster"
        }
        @{
            Case = 'a preferred owner listed twice'; Options = @{ PreferredOwners = @('NODE1', 'node1') }
            Message = 'Node node1 is listed twice in preferred_owners'
        }
        @{
            Case = 'an empty preferred owners list'; Options = @{ PreferredOwners = @() }
            Message = 'preferred_owners must name at least one node*'
        }
        @{
            Case = 'an unknown resource'; Options = @{ Resources = @(@{ name = 'Nope' }) }
            Message = "Resource Nope isn't in group Test Group"
        }
        @{
            Case = 'a resource listed twice'; Options = @{ Resources = @(@{ name = 'App' }, @{ name = 'app' }) }
            Message = 'Resource app is listed twice'
        }
        @{
            Case = 'an unknown resource property'; Options = @{ Resources = @(@{ name = 'App'; properties = @{ NoSuch = 1 } }) }
            Message = "Resource App has no common property 'NoSuch'"
        }
        @{
            Case = 'an unknown private property'; Options = @{ Resources = @(@{ name = 'App'; parameters = @{ NoSuch = 1 } }) }
            Message = "Resource App has no private property 'NoSuch'"
        }
        @{
            Case = 'an owner outside the cluster'; Options = @{ Owner = 'NODE9' }
            Message = "Node NODE9 isn't in the cluster"
        }
    ) {
        { Invoke-Plan -Options $Options } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses to move the group to a node that is down' {
        $plan = @{ Group = (New-Group); ClusterNodes = @('NODE1', 'NODE2'); NodesUp = @('NODE1'); Owner = 'NODE2' }
        { Get-WsfcGroupPlan @plan } | Should -Throw -ExpectedMessage "Node NODE2 isn't up, so group Test Group can't move to it"
    }

    It 'refuses <Case> on an availability group''s group' -ForEach @(
        @{ Case = 'preferred owners'; Options = @{ PreferredOwners = @('NODE1') } }
        @{ Case = 'a move'; Options = @{ Owner = 'NODE2' } }
        @{ Case = 'failback'; Options = @{ Failback = @{ allowed = $false } } }
        @{ Case = 'a property'; Options = @{ Properties = @{ Priority = 1 } } }
    ) {
        { Invoke-Plan -Options $Options -Group $script:agGroup } | Should -Throw -ExpectedMessage 'Group Test Group holds an availability group*'
    }

    It 'refuses any change to the availability group resource' {
        $options = @{ Resources = @(@{ name = 'AG1'; properties = @{ RestartThreshold = 1 } }) }
        { Invoke-Plan -Options $options -Group $script:agGroup } | Should -Throw -ExpectedMessage 'Resource AG1 is an availability group*'
    }
}
