# Pester 5 unit tests for gpo_import's logic: the pure functions it calls from
# plugins/module_utils/_GpoCommon.psm1 that decide what it imports and how it
# reorders links, its argument handling, and the module's wiring to that util.
# The module's behaviour against a domain is its integration target
# (tests/integration/targets/gpo_import). Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/gpo_import.ps1'
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

Describe 'gpo_import''s wiring' {
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
