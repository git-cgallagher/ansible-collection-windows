# Pester 5 unit tests for wsfc_cluster's logic: the pure functions it calls
# from plugins/module_utils/_WsfcCommon.psm1 that decide which sites to
# create, which nodes to move between them and which node votes to change,
# and the module's wiring to that util. The module's behaviour against a
# cluster is its integration target (tests/integration/targets/wsfc_cluster).
# Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/wsfc_cluster.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_WsfcCommon.psm1') -Force

    function script:New-Domain {
        param([string]$Name, [string]$Type, [string]$Parent = '', [string]$Description = '')
        @{ name = $Name; type = $Type; parent = $Parent; description = $Description }
    }
}

AfterAll {
    Remove-Module _WsfcCommon -ErrorAction SilentlyContinue
}

Describe 'wsfc_cluster''s wiring' {
    BeforeAll {
        $script:text = Get-Content -LiteralPath $script:modulePath -Raw
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
        $script:defined = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
    }

    It 'loads the shared util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._WsfcCommon$'
    }

    It 'no longer defines the helpers the util provides' {
        foreach ($name in 'Get-ShortName', 'Get-Setting', 'Get-ResourceTypeName', 'Test-NetworkMatch') {
            $script:defined | Should -Not -Contain $name
        }
    }

    It 'calls both planners' {
        $script:text | Should -Match 'Get-WsfcSitePlan '
        $script:text | Should -Match 'Get-WsfcNodeWeightPlan '
    }
}

Describe 'Get-ShortName' {
    It 'returns the first label, upper-cased' {
        Get-ShortName 'node1.lab.example.com' | Should -Be 'NODE1'
        Get-ShortName 'Node2' | Should -Be 'NODE2'
    }
}

Describe 'Get-Setting' {
    It 'returns a set value' {
        Get-Setting -Object @{ a = 'x' } -Key 'a' | Should -Be 'x'
    }

    It 'treats a missing key, $null and an empty string as left out' {
        Get-Setting -Object @{} -Key 'a' -Default 'd' | Should -Be 'd'
        Get-Setting -Object @{ a = $null } -Key 'a' -Default 'd' | Should -Be 'd'
        Get-Setting -Object @{ a = '' } -Key 'a' -Default 'd' | Should -Be 'd'
    }
}

Describe 'ConvertTo-WsfcFaultDomain' {
    It 'reads the type and parent under either name' {
        $a = ConvertTo-WsfcFaultDomain -FaultDomain ([pscustomobject]@{ Name = 'NODE1'; Type = 'Node'; ParentName = 'DC1' })
        $a.name | Should -Be 'NODE1'
        $a.type | Should -Be 'Node'
        $a.parent | Should -Be 'DC1'

        $b = ConvertTo-WsfcFaultDomain -FaultDomain ([pscustomobject]@{ Name = 'DC1'; FaultDomainType = 'Site'; Description = 'Ellijay' })
        $b.type | Should -Be 'Site'
        $b.parent | Should -Be ''
        $b.description | Should -Be 'Ellijay'
    }

    It 'resolves a parent given only by ID' {
        $d = ConvertTo-WsfcFaultDomain -FaultDomain ([pscustomobject]@{ Name = 'NODE2'; Type = 'Node'; ParentId = 'id-7' }) -ById @{ 'id-7' = 'DC2' }
        $d.parent | Should -Be 'DC2'
    }
}

Describe 'Get-WsfcSitePlan' {
    BeforeAll {
        $script:nodes = @('NODE1', 'NODE2')
        $script:bare = @((New-Domain 'NODE1' 'Node'), (New-Domain 'NODE2' 'Node'))
    }

    It 'creates the sites, then moves the nodes into them' {
        $sites = @(
            @{ name = 'DC1'; nodes = @('node1'); description = 'First datacenter' },
            @{ name = 'DC2'; nodes = @('node2.lab.example.com') }
        )
        $plan = Get-WsfcSitePlan -Sites $sites -FaultDomains $script:bare -ClusterNodes $script:nodes
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('CreateSite', 'CreateSite', 'SetParent', 'SetParent')
        $plan.Actions[0].Name | Should -Be 'DC1'
        $plan.Actions[0].Description | Should -Be 'First datacenter'
        $plan.Actions[2].Node | Should -Be 'NODE1'
        $plan.Actions[2].FaultDomain | Should -Be 'NODE1'
        $plan.Actions[2].From | Should -Be ''
        $plan.Actions[2].To | Should -Be 'DC1'
        $plan.Actions[3].Node | Should -Be 'NODE2'
        @($plan.Warnings).Count | Should -Be 0
    }

    It 'plans nothing when the cluster already matches, whatever the case' {
        $domains = @((New-Domain 'DC1' 'Site' -Description 'First'), (New-Domain 'NODE1' 'Node' 'dc1'), (New-Domain 'NODE2' 'Node'))
        $plan = Get-WsfcSitePlan -Sites @(@{ name = 'dc1'; nodes = @('NODE1'); description = 'First' }) -FaultDomains $domains -ClusterNodes $script:nodes
        @($plan.Actions).Count | Should -Be 0
    }

    It 'moves a node between sites and fixes a description' {
        $domains = @(
            (New-Domain 'DC1' 'Site' -Description 'old'), (New-Domain 'DC2' 'Site'),
            (New-Domain 'NODE1' 'Node' 'DC2'), (New-Domain 'NODE2' 'Node' 'DC2')
        )
        $sites = @(@{ name = 'DC1'; nodes = @('NODE1'); description = 'new' }, @{ name = 'DC2'; nodes = @('NODE2') })
        $plan = Get-WsfcSitePlan -Sites $sites -FaultDomains $domains -ClusterNodes $script:nodes
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('SetDescription', 'SetParent')
        $plan.Actions[0].From | Should -Be 'old'
        $plan.Actions[0].To | Should -Be 'new'
        $plan.Actions[1].Node | Should -Be 'NODE1'
        $plan.Actions[1].From | Should -Be 'DC2'
        $plan.Actions[1].To | Should -Be 'DC1'
    }

    It 'finds a node whose fault domain has its full name, and moves it by that name' {
        $domains = @((New-Domain 'DC1' 'Site'), (New-Domain 'node1.lab.example.com' 'Node' 'DC1'), (New-Domain 'node2.lab.example.com' 'Node'))
        $sites = @(@{ name = 'DC1'; nodes = @('NODE1') }, @{ name = 'DC2'; nodes = @('NODE2') })
        $plan = Get-WsfcSitePlan -Sites $sites -FaultDomains $domains -ClusterNodes $script:nodes
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('CreateSite', 'SetParent')
        $plan.Actions[1].Node | Should -Be 'NODE2'
        $plan.Actions[1].FaultDomain | Should -Be 'node2.lab.example.com'
    }

    It 'leaves a description alone when the option gives none' {
        $domains = @((New-Domain 'DC1' 'Site' -Description 'kept'), (New-Domain 'NODE1' 'Node' 'DC1'), (New-Domain 'NODE2' 'Node'))
        $plan = Get-WsfcSitePlan -Sites @(@{ name = 'DC1'; nodes = @('NODE1') }) -FaultDomains $domains -ClusterNodes $script:nodes
        @($plan.Actions).Count | Should -Be 0
    }

    It 'warns about a site it doesn''t list, and never removes it' {
        $domains = @((New-Domain 'OLD' 'Site'), (New-Domain 'NODE1' 'Node' 'OLD'), (New-Domain 'NODE2' 'Node'))
        $plan = Get-WsfcSitePlan -Sites @(@{ name = 'DC1' }) -FaultDomains $domains -ClusterNodes $script:nodes
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('CreateSite')
        $plan.Warnings | Should -Be @('Site OLD isn''t in sites; it was left in place')
    }

    It 'creates a site without nodes' {
        $plan = Get-WsfcSitePlan -Sites @(@{ name = 'DC3'; nodes = @() }) -FaultDomains $script:bare -ClusterNodes $script:nodes
        @($plan.Actions | ForEach-Object { $_.Kind }) | Should -Be @('CreateSite')
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a site without a name'; Sites = @(@{ name = '' }); Message = 'Every site needs a name' }
        @{ Case = 'a site listed twice'; Sites = @(@{ name = 'DC1' }, @{ name = 'dc1' }); Message = 'Site dc1 is listed twice' }
        @{ Case = 'a site named like a node'; Sites = @(@{ name = 'node1' }); Message = 'Site node1 has the name of a node*' }
        @{
            Case = 'a node in two sites'
            Sites = @(@{ name = 'DC1'; nodes = @('NODE1') }, @{ name = 'DC2'; nodes = @('node1') })
            Message = 'Node node1 is listed in sites DC1 and DC2*'
        }
        @{ Case = 'a node outside the cluster'; Sites = @(@{ name = 'DC1'; nodes = @('NODE9') }); Message = 'Node NODE9 in site DC1 isn''t in the cluster' }
    ) {
        { Get-WsfcSitePlan -Sites $Sites -FaultDomains $script:bare -ClusterNodes $script:nodes } | Should -Throw -ExpectedMessage $Message
    }

    It 'refuses a site name a fault domain of another type has' {
        $domains = @((New-Domain 'RACK1' 'Rack'), (New-Domain 'NODE1' 'Node'))
        { Get-WsfcSitePlan -Sites @(@{ name = 'RACK1' }) -FaultDomains $domains -ClusterNodes @('NODE1') } |
            Should -Throw -ExpectedMessage 'Fault domain RACK1 exists as a Rack, not a site'
    }
}

Describe 'Get-WsfcNodeWeightPlan' {
    It 'plans only the votes that differ' {
        $plan = @(Get-WsfcNodeWeightPlan -Weights @{ node1 = 1; NODE2 = 0 } -Current @{ NODE1 = 1; NODE2 = 1 })
        $plan.Count | Should -Be 1
        $plan[0].Node | Should -Be 'NODE2'
        $plan[0].From | Should -Be 1
        $plan[0].To | Should -Be 0
    }

    It 'accepts the weight as a string' {
        $plan = @(Get-WsfcNodeWeightPlan -Weights @{ NODE1 = '0' } -Current @{ NODE1 = 1 })
        $plan[0].To | Should -Be 0
    }

    It 'plans nothing when every vote matches' {
        @(Get-WsfcNodeWeightPlan -Weights @{ NODE1 = 1 } -Current @{ NODE1 = 1 }).Count | Should -Be 0
    }

    It 'refuses a node outside the cluster' {
        { Get-WsfcNodeWeightPlan -Weights @{ NODE9 = 0 } -Current @{ NODE1 = 1 } } |
            Should -Throw -ExpectedMessage 'Node NODE9 in node_weights isn''t in the cluster'
    }

    It 'refuses a weight other than 0 or 1' {
        { Get-WsfcNodeWeightPlan -Weights @{ NODE1 = 2 } -Current @{ NODE1 = 1 } } |
            Should -Throw -ExpectedMessage 'Node NODE1''s weight must be 0 or 1, not ''2'''
    }
}
