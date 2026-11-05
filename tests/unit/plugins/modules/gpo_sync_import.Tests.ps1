# Pester 5 unit tests for gpo_sync_import's logic: the pure functions it calls from
# plugins/module_utils/_GpoCommon.psm1 that decide what it imports and how it
# reorders links, its argument handling, and the module's wiring to that util.
# The module's behaviour against a domain is its integration target
# (tests/integration/targets/gpo_sync_import). Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/gpo_sync_import.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_GpoCommon.psm1') -Force

    function script:New-Link {
        param([string]$Name, [bool]$Enforced = $false, [bool]$Enabled = $true)
        @{ name = $Name; enforced = $Enforced; enabled = $Enabled }
    }

    function script:New-DesiredLink {
        param([string]$Gpo, [bool]$Enforced = $false, [bool]$Enabled = $true)
        [pscustomobject]@{ gpo = $Gpo; enforced = $Enforced; enabled = $Enabled }
    }

    # What GPMC does with each planned operation: New-GPLink -Order inserts at
    # that position, Set-GPLink -Order moves the link there (renumbering the
    # neighbours), Remove-GPLink drops it. 'unmanaged' changes nothing.
    function script:Invoke-LinkPlan {
        param([object[]]$Current, [object[]]$Plan)
        $links = New-Object System.Collections.ArrayList
        foreach ($l in $Current) { [void]$links.Add(@{ name = $l.name; enforced = $l.enforced; enabled = $l.enabled }) }
        foreach ($op in $Plan) {
            $idx = -1
            for ($j = 0; $j -lt $links.Count; $j++) { if ($links[$j].name -ieq $op.name) { $idx = $j; break } }
            switch ($op.action) {
                'new' {
                    $links.Insert([Math]::Min($op.order - 1, $links.Count), @{ name = $op.name; enforced = $op.enforced; enabled = $op.enabled })
                }
                'set' {
                    $links.RemoveAt($idx)
                    $links.Insert([Math]::Min($op.order - 1, $links.Count), @{ name = $op.name; enforced = $op.enforced; enabled = $op.enabled })
                }
                'remove' { $links.RemoveAt($idx) }
            }
        }
        , @($links)
    }

    function script:Format-Link {
        param([object[]]$Links)
        @($Links | ForEach-Object { '{0}|{1}|{2}' -f $_.name, [bool]$_.enforced, [bool]$_.enabled })
    }
}

AfterAll {
    Remove-Module _GpoCommon -ErrorAction SilentlyContinue
}

Describe 'gpo_sync_import''s wiring' {
    BeforeAll {
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
    }

    It 'loads the GPO module util' {
        Get-Content -LiteralPath $script:modulePath -Raw | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._GpoCommon\r?$'
    }

    It 'defines none of the util''s functions itself (no copy to drift)' {
        $own = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
        $util = @((Get-Module _GpoCommon).ExportedFunctions.Keys)
        @($own | Where-Object { $util -contains $_ }) | Should -BeNullOrEmpty
    }

    It 'never builds a path under a user-supplied directory with Join-Path (it resolves the drive)' {
        $roots = @('SourceDir', 'StateDir', 'gposRoot')
        $isJoin = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' }
        $joins = @($script:ast.FindAll($isJoin, $true) |
                Where-Object { $_.CommandElements.Count -gt 1 -and $roots -contains ($_.CommandElements[1].Extent.Text -replace '^[$]', '') } |
                ForEach-Object { $_.Extent.Text })
        $joins | Should -BeNullOrEmpty
    }

    It 'calls nothing but its own functions, the util, PowerShell and the GroupPolicy/ActiveDirectory cmdlets' {
        $own = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                ForEach-Object { $_.Name })
        $util = @((Get-Module _GpoCommon).ExportedFunctions.Keys)
        $called = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        @($called | Where-Object { $util -contains $_ }) | Should -Not -BeNullOrEmpty
        @($called | Where-Object {
                $own -notcontains $_ -and $util -notcontains $_ -and $_ -notmatch '^[A-Za-z]+-(GP|GPO|AD)[A-Za-z]*$' -and
                -not (Get-Command -Name $_ -ErrorAction SilentlyContinue)
            }) | Should -BeNullOrEmpty
    }

    It 'declares the documented options with their defaults' {
        $specAst = $script:ast.Find({
                param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$spec'
            }, $false)
        $spec = & ([scriptblock]::Create($specAst.Right.Extent.Text))
        @($spec.options.Keys | Sort-Object) | Should -Be @('create_wmi_filters', 'domain', 'force', 'gpo_names', 'manifest_path',
            'migration_table_path', 'remove_unmanaged_links', 'server', 'source_dir', 'state_dir')
        $spec.options.manifest_path.default | Should -BeExactly 'gpo-manifest.json'
        $spec.options.state_dir.default | Should -BeExactly 'C:\ProgramData\gpo-iac'
        $spec.options.remove_unmanaged_links.default | Should -BeFalse
        $spec.options.create_wmi_filters.default | Should -BeFalse
        $spec.supports_check_mode | Should -BeTrue
    }
}

Describe 'ConvertTo-LdapFilterValue' {
    It 'escapes <Value> as <Expected>' -TestCases @(
        @{ Value = 'IacLab Server OS'; Expected = 'IacLab Server OS' }
        @{ Value = 'a*b'; Expected = 'a\2ab' }
        @{ Value = '(x)'; Expected = '\28x\29' }
        @{ Value = 'back\slash*'; Expected = 'back\5cslash\2a' }
    ) {
        param($Value, $Expected)
        ConvertTo-LdapFilterValue -Value $Value | Should -BeExactly $Expected
    }
}

Describe 'Get-YesNo' {
    It 'returns the form GPMC''s cmdlets take' {
        Get-YesNo $true | Should -BeExactly 'Yes'
        Get-YesNo $false | Should -BeExactly 'No'
    }
}

Describe 'Test-GpoBackupFolder' {
    BeforeEach {
        $script:wrapper = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:wrapper | Out-Null
    }

    It 'passes a complete Backup-GPO folder' {
        $guid = Join-Path $script:wrapper '{11111111-2222-3333-4444-555555555555}'
        New-Item -ItemType Directory -Path $guid | Out-Null
        foreach ($f in 'Backup.xml', 'gpreport.xml') { [System.IO.File]::WriteAllText((Join-Path $guid $f), '<x/>') }
        Test-GpoBackupFolder -Path $script:wrapper | Should -BeExactly ''
    }

    It 'names the missing file' {
        $guid = Join-Path $script:wrapper '{AAAA}'
        New-Item -ItemType Directory -Path $guid | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $guid 'gpreport.xml'), '<x/>')
        Test-GpoBackupFolder -Path $script:wrapper | Should -BeExactly 'no Backup.xml in {AAAA}'
    }

    It 'wants exactly one {GUID} subfolder' {
        Test-GpoBackupFolder -Path $script:wrapper | Should -BeExactly 'expected one {GUID} subfolder, found 0'
        New-Item -ItemType Directory -Path (Join-Path $script:wrapper '{A}'), (Join-Path $script:wrapper '{B}') | Out-Null
        Test-GpoBackupFolder -Path $script:wrapper | Should -BeExactly 'expected one {GUID} subfolder, found 2'
    }
}

Describe 'Resolve-GpoMigrationTablePath' {
    It 'is empty when no table was given' {
        Resolve-GpoMigrationTablePath -Path '' -SourceDir $TestDrive | Should -BeExactly ''
        Resolve-GpoMigrationTablePath -Path $null -SourceDir $TestDrive | Should -BeExactly ''
    }

    It 'resolves a relative path under the source directory' {
        Resolve-GpoMigrationTablePath -Path 'migtables/prod.migtable' -SourceDir $TestDrive |
            Should -Be (Join-Path $TestDrive 'migtables/prod.migtable')
    }

    It 'doesn''t resolve the drive of a source directory on a drive that doesn''t exist' {
        $ErrorActionPreference = 'Stop'
        Resolve-GpoMigrationTablePath -Path 'migtables/prod.migtable' -SourceDir 'NoSuchGpoDrive:\stage' |
            Should -BeExactly ([System.IO.Path]::Combine('NoSuchGpoDrive:\stage', 'migtables/prod.migtable'))
    }

    It 'keeps a rooted path as given' {
        $rooted = Join-Path $TestDrive 'elsewhere.migtable'
        Resolve-GpoMigrationTablePath -Path $rooted -SourceDir (Join-Path $TestDrive 'stage') | Should -BeExactly $rooted
    }
}

Describe 'Get-GpoImportReason' {
    It 'returns <Expected> for force=<Force>, live=<Live>, recorded=<Recorded>, keys <RecordedKey>/<ImportKey>' -TestCases @(
        @{ Force = $true; Live = $true; Recorded = $true; RecordedKey = 'K'; ImportKey = 'K'; Expected = 'forced' }
        @{ Force = $true; Live = $false; Recorded = $false; RecordedKey = ''; ImportKey = 'K'; Expected = 'forced' }
        @{ Force = $false; Live = $false; Recorded = $true; RecordedKey = 'K'; ImportKey = 'K'; Expected = 'GPO missing in target' }
        @{ Force = $false; Live = $true; Recorded = $false; RecordedKey = ''; ImportKey = 'K'; Expected = 'never imported by this pipeline' }
        @{ Force = $false; Live = $true; Recorded = $true; RecordedKey = 'OLD'; ImportKey = 'K'; Expected = 'backup content or migration table changed' }
        @{ Force = $false; Live = $true; Recorded = $true; RecordedKey = 'K'; ImportKey = 'K'; Expected = '' }
    ) {
        param($Force, $Live, $Recorded, $RecordedKey, $ImportKey, $Expected)
        Get-GpoImportReason -Force $Force -LiveExists $Live -Recorded $Recorded -RecordedKey $RecordedKey -ImportKey $ImportKey |
            Should -BeExactly $Expected
    }

    It 'treats a migration table change as a change of the import key' {
        $backup = Get-StringHash -Text 'content'
        $without = Get-StringHash -Text ($backup + '|')
        $with = Get-StringHash -Text ($backup + '|' + (Get-StringHash -Text 'table'))
        Get-GpoImportReason -Force $false -LiveExists $true -Recorded $true -RecordedKey $without -ImportKey $with |
            Should -BeExactly 'backup content or migration table changed'
    }
}

Describe 'Get-GpoLinkPlan' {
    It 'plans nothing when the links already match' {
        $current = @((New-Link 'A' $true), (New-Link 'B'))
        $desired = @((New-DesiredLink 'A' $true), (New-DesiredLink 'B'))
        @(Get-GpoLinkPlan -Current $current -Desired $desired -RemoveUnmanaged $true) | Should -BeNullOrEmpty
    }

    It 'compares GPO names case-insensitively' {
        @(Get-GpoLinkPlan -Current @(New-Link 'Server Baseline') -Desired @(New-DesiredLink 'server baseline')) |
            Should -BeNullOrEmpty
    }

    It 'links a missing GPO at its position' {
        $plan = @(Get-GpoLinkPlan -Current @(New-Link 'B') -Desired @((New-DesiredLink 'A' $false $false), (New-DesiredLink 'B')))
        $plan.Count | Should -Be 1
        $plan[0].action | Should -BeExactly 'new'
        $plan[0].name | Should -BeExactly 'A'
        $plan[0].order | Should -Be 1
        $plan[0].enabled | Should -BeFalse
    }

    It 'sets enforced or enabled on a link already in place, without moving it' {
        $plan = @(Get-GpoLinkPlan -Current @((New-Link 'A'), (New-Link 'B')) -Desired @((New-DesiredLink 'A' $true), (New-DesiredLink 'B')))
        $plan.Count | Should -Be 1
        $plan[0].action | Should -BeExactly 'set'
        $plan[0].name | Should -BeExactly 'A'
        $plan[0].order | Should -Be 1
        $plan[0].enforced | Should -BeTrue
    }

    It 'reports an unmanaged link without remove_unmanaged_links, and removes it with' {
        $current = @((New-Link 'Unmanaged'), (New-Link 'A'))
        $desired = @(New-DesiredLink 'A')
        $keep = @(Get-GpoLinkPlan -Current $current -Desired $desired -RemoveUnmanaged $false)
        $keep | Where-Object { $_.action -eq 'unmanaged' } | ForEach-Object { $_.name } | Should -BeExactly 'Unmanaged'
        @($keep | Where-Object { $_.action -eq 'remove' }) | Should -BeNullOrEmpty
        $remove = @(Get-GpoLinkPlan -Current $current -Desired $desired -RemoveUnmanaged $true)
        $remove | Where-Object { $_.action -eq 'remove' } | ForEach-Object { $_.name } | Should -BeExactly 'Unmanaged'
    }

    It 'plans the lab drift''s fixes: the domain root''s order back, the servers'' enforced link and unmanaged link' {
        # The fixture's drift: Default Domain Policy moved above the password policy.
        $root = @(Get-GpoLinkPlan -Current @((New-Link 'Default Domain Policy'), (New-Link 'Password')) `
                -Desired @((New-DesiredLink 'Password'), (New-DesiredLink 'Default Domain Policy')))
        $root.Count | Should -Be 1
        $root[0].action | Should -BeExactly 'set'
        $root[0].name | Should -BeExactly 'Password'
        $root[0].order | Should -Be 1
        # An unmanaged link on top, the baseline no longer enforced, the RDP GPO's link gone with its GPO.
        $servers = @(Get-GpoLinkPlan -Current @((New-Link 'Password'), (New-Link 'Baseline'), (New-Link 'Admins')) `
                -Desired @((New-DesiredLink 'Baseline' $true), (New-DesiredLink 'RDP'), (New-DesiredLink 'Admins')) -RemoveUnmanaged $true)
        Format-Link (Invoke-LinkPlan -Current @((New-Link 'Password'), (New-Link 'Baseline'), (New-Link 'Admins')) -Plan $servers) |
            Should -Be @('Baseline|True|True', 'RDP|False|True', 'Admins|False|True')
        ($servers | ForEach-Object { '{0} {1} {2}' -f $_.action, $_.name, $_.order }) |
            Should -Be @('set Baseline 1', 'new RDP 2', 'set Admins 3', 'remove Password ')
    }

    It 'converges <Name> in one pass, and a re-plan is empty' -TestCases @(
        @{ Name = 'a reversal'; Current = 'A,B,C,D'; Desired = 'D,C,B,A' }
        @{ Name = 'a rotation'; Current = 'A,B,C,D'; Desired = 'B,C,D,A' }
        @{ Name = 'new links between'; Current = 'A,C'; Desired = 'A,B,C,D' }
        @{ Name = 'new links first'; Current = 'C'; Desired = 'A,B,C' }
        @{ Name = 'unmanaged in the middle'; Current = 'A,X,B,Y'; Desired = 'B,A' }
        @{ Name = 'an empty container'; Current = ''; Desired = 'A,B' }
        @{ Name = 'everything unmanaged'; Current = 'X,Y'; Desired = '' }
        @{ Name = 'mixed case'; Current = 'b,A'; Desired = 'A,B' }
    ) {
        param($Current, $Desired)
        $currentLinks = @($Current -split ',' | Where-Object { $_ } | ForEach-Object { New-Link $_ })
        $desiredLinks = @($Desired -split ',' | Where-Object { $_ } | ForEach-Object { New-DesiredLink $_ })
        $plan = @(Get-GpoLinkPlan -Current $currentLinks -Desired $desiredLinks -RemoveUnmanaged $true)
        $after = Invoke-LinkPlan -Current $currentLinks -Plan $plan
        @($after | ForEach-Object { $_.name.ToLowerInvariant() }) | Should -Be @($desiredLinks | ForEach-Object { $_.gpo.ToLowerInvariant() })
        @(Get-GpoLinkPlan -Current $after -Desired $desiredLinks -RemoveUnmanaged $true) | Should -BeNullOrEmpty
    }

    It 'copes with no current links and no desired links' {
        @(Get-GpoLinkPlan -Current @() -Desired @()) | Should -BeNullOrEmpty
        @(Get-GpoLinkPlan -Current @($null) -Desired @($null)) | Should -BeNullOrEmpty
    }
}

Describe 'Get-GpoImportScope' {
    BeforeAll {
        $script:gpos = @{
            'Server Baseline' = [pscustomobject]@{ backup_dir = 'Server Baseline'; wmi_filter = 'Server OS' }
            'RDP Settings' = [pscustomobject]@{ backup_dir = 'RDP Settings'; wmi_filter = 'Client OS' }
            'Password Policy' = [pscustomobject]@{ backup_dir = 'Password Policy' }
        }
        $script:filters = @('Server OS', 'Client OS', 'Unlinked')
    }

    It 'covers every GPO and every WMI filter without gpo_names' {
        $scope = Get-GpoImportScope -Gpos $script:gpos -WmiFilters $script:filters
        $scope.filtered | Should -BeFalse
        $scope.gpos | Should -Be @('Password Policy', 'RDP Settings', 'Server Baseline')
        $scope.wmi_filters | Should -Be @('Client OS', 'Server OS', 'Unlinked')
    }

    It 'covers the selected GPOs the manifest has, spelt as the manifest spells them' {
        $scope = Get-GpoImportScope -Gpos $script:gpos -WmiFilters $script:filters -Selected @('server baseline', 'Not In The Manifest', '')
        $scope.filtered | Should -BeTrue
        $scope.gpos | Should -BeExactly @('Server Baseline')
    }

    It 'covers only the WMI filters the selected GPOs link' {
        (Get-GpoImportScope -Gpos $script:gpos -WmiFilters $script:filters -Selected @('Server Baseline')).wmi_filters |
            Should -BeExactly @('Server OS')
        @((Get-GpoImportScope -Gpos $script:gpos -WmiFilters $script:filters -Selected @('Password Policy')).wmi_filters) |
            Should -BeNullOrEmpty
    }

    It 'doesn''t list a filter a selected GPO links but the manifest doesn''t define (the GPO''s step reports it)' {
        @((Get-GpoImportScope -Gpos $script:gpos -WmiFilters @('Server OS') -Selected @('RDP Settings')).wmi_filters) |
            Should -BeNullOrEmpty
    }

    It 'covers nothing when gpo_names names no GPO in the manifest' {
        $scope = Get-GpoImportScope -Gpos $script:gpos -WmiFilters $script:filters -Selected @('Elsewhere')
        $scope.filtered | Should -BeTrue
        @($scope.gpos) | Should -BeNullOrEmpty
        @($scope.wmi_filters) | Should -BeNullOrEmpty
    }

    It 'copes with an empty manifest' {
        $scope = Get-GpoImportScope -Gpos @{} -WmiFilters @() -Selected @('A')
        @($scope.gpos) | Should -BeNullOrEmpty
        @($scope.wmi_filters) | Should -BeNullOrEmpty
    }
}

Describe 'Get-GpoSubsetLinkPlan' {
    BeforeAll {
        function script:ConvertTo-LinkList {
            param([string]$Spec, [switch]$Desired)
            # 'A,B!,c-': '!' enforced, '-' disabled.
            @($Spec -split ',' | Where-Object { $_ } | ForEach-Object {
                    $name = $_.TrimEnd('!', '-')
                    if ($Desired) { New-DesiredLink $name $_.Contains('!') (-not $_.Contains('-')) }
                    else { New-Link $name $_.Contains('!') (-not $_.Contains('-')) }
                })
        }
    }

    It 'plans the lab''s subset fixes: <Name>' -TestCases @(
        # The lab drift's servers OU: an unmanaged password link on top, the
        # baseline no longer enforced, the RDP GPO deleted. Only the baseline
        # is selected: it goes back on top, enforced; the rest stays.
        @{ Name = 'the baseline on the servers OU'; Current = 'Password,Baseline,Admins'; Desired = 'Baseline!,RDP,Admins'
            Selected = 'Baseline'; Ops = 'set Baseline 1'; After = 'Baseline!,Password,Admins'
        }
        # The workstations OU, the RDP GPO deleted and the admins GPO unlinked.
        @{ Name = 'the admins on the workstations OU'; Current = ''; Desired = 'RDP-,Admins'
            Selected = 'Admins'; Ops = 'new Admins 1'; After = 'Admins'
        }
        # The domain root: the password policy belongs above Default Domain
        # Policy, which the subset doesn't select. A new link goes first, not last.
        @{ Name = 'the password policy above Default Domain Policy'; Current = 'Default Domain Policy'; Desired = 'Password,Default Domain Policy'
            Selected = 'Password'; Ops = 'new Password 1'; After = 'Password,Default Domain Policy'
        }
    ) {
        param($Current, $Desired, $Selected, $Ops, $After)
        $currentLinks = ConvertTo-LinkList $Current
        $plan = @(Get-GpoSubsetLinkPlan -Current $currentLinks -Desired (ConvertTo-LinkList $Desired -Desired) `
                -Selected ($Selected -split ',') -RemoveUnmanaged $true)
        @($plan | ForEach-Object { '{0} {1} {2}' -f $_.action, $_.name, $_.order }) -join ';' | Should -BeExactly $Ops
        Format-Link (Invoke-LinkPlan -Current $currentLinks -Plan $plan) | Should -Be (Format-Link (ConvertTo-LinkList $After))
    }

    It 'places <Name>' -TestCases @(
        @{ Name = 'a GPO after its manifest predecessor'; Current = 'X,Y'; Desired = 'X,A,Y'; Selected = 'A'; After = 'X,A,Y' }
        @{ Name = 'a GPO back after its manifest predecessor'; Current = 'A,X,Y'; Desired = 'X,A,Y'; Selected = 'A'; After = 'X,A,Y' }
        @{ Name = 'a GPO whose predecessors the target lacks, first'; Current = 'Y'; Desired = 'P,Q,A,Y'; Selected = 'A'; After = 'A,Y' }
        @{ Name = 'a GPO past a missing predecessor, after the one before it'; Current = 'X,Y'; Desired = 'X,P,A,Y'; Selected = 'A'; After = 'X,A,Y' }
        @{ Name = 'two selected GPOs swapped around another link'; Current = 'B,X,A'; Desired = 'A,X,B'; Selected = 'A,B'; After = 'A,X,B' }
        @{ Name = 'two selected GPOs both after another link'; Current = 'B,X,A'; Desired = 'X,A,B'; Selected = 'A,B'; After = 'X,A,B' }
        @{ Name = 'GPOs where the container orders the other links differently'; Current = 'Y,X'; Desired = 'X,A,Y,B'; Selected = 'A,B'; After = 'Y,X,A,B' }
        @{ Name = 'a link a selected GPO no longer has here, removed'; Current = 'A,X'; Desired = 'X'; Selected = 'A'; After = 'X' }
        @{ Name = 'an unselected link the manifest doesn''t list, left'; Current = 'X,A'; Desired = 'A'; Selected = 'A'; After = 'A,X' }
        @{ Name = 'GPOs named in another case'; Current = 'x,a'; Desired = 'A,X'; Selected = 'a'; After = 'a,x' }
    ) {
        param($Current, $Desired, $Selected, $After)
        $currentLinks = ConvertTo-LinkList $Current
        $desiredLinks = ConvertTo-LinkList $Desired -Desired
        $plan = @(Get-GpoSubsetLinkPlan -Current $currentLinks -Desired $desiredLinks -Selected ($Selected -split ',') -RemoveUnmanaged $true)
        $result = Invoke-LinkPlan -Current $currentLinks -Plan $plan
        @($result | ForEach-Object { $_.name.ToLowerInvariant() }) | Should -Be @($After.ToLowerInvariant() -split ',')
        @(Get-GpoSubsetLinkPlan -Current $result -Desired $desiredLinks -Selected ($Selected -split ',') -RemoveUnmanaged $true) | Should -BeNullOrEmpty
    }

    It 'sets enforced or enabled on a selected link in place, and never on another' {
        $plan = @(Get-GpoSubsetLinkPlan -Current (ConvertTo-LinkList 'X!,A,Y-') -Desired (ConvertTo-LinkList 'X,A!-,Y' -Desired) -Selected @('A'))
        @($plan | ForEach-Object { '{0} {1} {2} {3} {4}' -f $_.action, $_.name, $_.order, $_.enforced, $_.enabled }) |
            Should -BeExactly @('set A 2 True False')
    }

    It 'reports a selected GPO''s unmanaged link without remove_unmanaged_links, and nothing about other GPOs'' links' {
        $plan = @(Get-GpoSubsetLinkPlan -Current (ConvertTo-LinkList 'X,A,Y') -Desired (ConvertTo-LinkList 'B' -Desired) `
                -Selected @('A', 'B') -RemoveUnmanaged $false)
        @($plan | ForEach-Object { '{0} {1}' -f $_.action, $_.name }) | Should -BeExactly @('new B', 'unmanaged A')
    }

    It 'plans nothing when no selected GPO is linked here or wanted here' {
        @(Get-GpoSubsetLinkPlan -Current (ConvertTo-LinkList 'X,Y') -Desired (ConvertTo-LinkList 'Y,Z,X' -Desired) -Selected @('A') -RemoveUnmanaged $true) |
            Should -BeNullOrEmpty
        @(Get-GpoSubsetLinkPlan -Current @() -Desired @() -Selected @('A')) | Should -BeNullOrEmpty
        @(Get-GpoSubsetLinkPlan -Current @($null) -Desired @($null) -Selected @('A')) | Should -BeNullOrEmpty
    }

    It 'converges in one pass, touches only selected links and keeps the others in order: 300 random containers' {
        $rng = New-Object System.Random 57
        $pool = @('A', 'B', 'C', 'D', 'E', 'F', 'G')
        for ($n = 0; $n -lt 300; $n++) {
            $current = @($pool | Where-Object { $rng.Next(2) } | Sort-Object { $rng.Next() } |
                    ForEach-Object { New-Link $_ ([bool]$rng.Next(2)) ([bool]$rng.Next(2)) })
            $desired = @($pool | Where-Object { $rng.Next(2) } | Sort-Object { $rng.Next() } |
                    ForEach-Object { New-DesiredLink $_ ([bool]$rng.Next(2)) ([bool]$rng.Next(2)) })
            $selected = @($pool | Where-Object { $rng.Next(2) })
            $case = 'current {0} / desired {1} / selected {2}' -f ((Format-Link $current) -join ','),
            ((@($desired | ForEach-Object { $_.gpo })) -join ','), ($selected -join ',')

            $plan = @(Get-GpoSubsetLinkPlan -Current $current -Desired $desired -Selected $selected -RemoveUnmanaged $true)
            @($plan | Where-Object { $selected -notcontains $_.name }) | Should -BeNullOrEmpty -Because $case
            $result = Invoke-LinkPlan -Current $current -Plan $plan
            @(Get-GpoSubsetLinkPlan -Current $result -Desired $desired -Selected $selected -RemoveUnmanaged $true) |
                Should -BeNullOrEmpty -Because $case

            # The other GPOs' links: same links, same order, same flags.
            $others = { param($links) Format-Link @($links | Where-Object { $selected -notcontains $_.name }) }
            (& $others $result) -join ',' | Should -BeExactly ((& $others $current) -join ',') -Because $case
            # The selected GPOs' links: exactly the manifest's, in its order, with its flags.
            $wanted = @($desired | Where-Object { $selected -contains $_.gpo } | ForEach-Object { New-Link $_.gpo $_.enforced $_.enabled })
            (Format-Link @($result | Where-Object { $selected -contains $_.name })) -join ',' |
                Should -BeExactly ((Format-Link $wanted) -join ',') -Because $case
        }
    }
}
