# Pester 5 unit tests for gpo_export's logic: the pure functions it calls from
# plugins/module_utils/_GpoCommon.psm1 that decide what it ships and what its
# manifest records, and the module's wiring to that util. The module's
# behaviour against a domain is its integration target
# (tests/integration/targets/gpo_export). Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/gpo_export.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_GpoCommon.psm1') -Force
    $script:nl = [Environment]::NewLine
    # Get-GpoLiveContentHash of the flat tree below (a.txt, empty/, gpt.ini),
    # gpt.ini left out; CRLF is what the module records on Windows.
    $script:pinnedLive = @{
        "`r`n" = '9B2B8887D4560937465D7B588BE9B1ED55E0F94EC18124A311DB40A89380AFA5'
        "`n" = 'F5CE6FDA367419C6371C1375E78DA00177A0039A6D71AC62DEA9F0D49F4A3A47'
    }

    function script:New-Gpt {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Root 'a.txt'), 'x')
        New-Item -ItemType Directory -Path (Join-Path $Root 'empty') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Root 'gpt.ini'), '[General]')
        $Root
    }

    function script:New-Permission {
        param([string]$Name, [string]$SidType)
        [pscustomobject]@{ Trustee = [pscustomobject]@{ Name = $Name; SidType = $SidType } }
    }
}

AfterAll {
    Remove-Module _GpoCommon -ErrorAction SilentlyContinue
}

Describe 'gpo_export''s wiring' {
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
        $roots = @('WorkDir')
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
}

Describe 'Get-GpoLiveContentHash' {
    It 'keeps its format: the pinned value for a known template' {
        $gpt = New-Gpt -Root (Join-Path $TestDrive 'pinned')
        Get-GpoLiveContentHash -Path $gpt | Should -BeExactly $script:pinnedLive[$script:nl]
    }

    It 'ignores gpt.ini, whose version counter GPMC bumps on every edit' {
        $gpt = New-Gpt -Root (Join-Path $TestDrive 'version')
        $before = Get-GpoLiveContentHash -Path $gpt
        [System.IO.File]::WriteAllText((Join-Path $gpt 'gpt.ini'), "[General]`r`nVersion=65537`r`n")
        Get-GpoLiveContentHash -Path $gpt | Should -BeExactly $before
    }

    It 'only ignores the root gpt.ini, not a file of that name deeper down' {
        $gpt = New-Gpt -Root (Join-Path $TestDrive 'deep')
        $before = Get-GpoLiveContentHash -Path $gpt
        [System.IO.File]::WriteAllText((Join-Path (Join-Path $gpt 'empty') 'gpt.ini'), 'x')
        Get-GpoLiveContentHash -Path $gpt | Should -Not -Be $before
    }

    It 'changes with the settings content' {
        $gpt = New-Gpt -Root (Join-Path $TestDrive 'settings')
        $before = Get-GpoLiveContentHash -Path $gpt
        [System.IO.File]::WriteAllText((Join-Path $gpt 'a.txt'), 'changed')
        Get-GpoLiveContentHash -Path $gpt | Should -Not -Be $before
    }

    It 'throws, naming the folder, when the template is missing' {
        $missing = Join-Path $TestDrive 'missing'
        { Get-GpoLiveContentHash -Path $missing } | Should -Throw "*SYSVOL folder $missing does not exist*"
    }
}

Describe 'New-ZipFromDirectory' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $script:source = Join-Path $TestDrive 'export'
        New-Item -ItemType Directory -Path (Join-Path $script:source 'gpos/RDP Settings/{GUID}/DomainSysvol/GPO/User') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:source 'gpo-manifest.json'), '{"gpos":{}}')
        [System.IO.File]::WriteAllText((Join-Path $script:source 'gpos/RDP Settings/{GUID}/Backup.xml'), '<x/>')
        $script:zipPath = Join-Path $TestDrive 'gpo-export.zip'
        New-ZipFromDirectory -Source $script:source -Destination $script:zipPath
        $zip = [System.IO.Compression.ZipFile]::OpenRead($script:zipPath)
        try { $script:entries = @($zip.Entries | ForEach-Object { $_.FullName } | Sort-Object) }
        finally { $zip.Dispose() }
    }

    It 'names entries with forward slashes, relative to the source' {
        $script:entries | Should -Contain 'gpo-manifest.json'
        $script:entries | Should -Contain 'gpos/RDP Settings/{GUID}/Backup.xml'
        @($script:entries | Where-Object { $_.Contains('\') }) | Should -BeNullOrEmpty
    }

    It 'gives an empty directory an explicit entry, and a non-empty one none' {
        $script:entries | Should -Contain 'gpos/RDP Settings/{GUID}/DomainSysvol/GPO/User/'
        $script:entries | Should -Not -Contain 'gpos/RDP Settings/{GUID}/'
    }
}

Describe 'ConvertTo-RelativeDn' {
    It 'makes <Dn> relative to the root' -TestCases @(
        @{ Dn = 'DC=gpolab,DC=test'; Expected = '' }
        @{ Dn = 'dc=GPOLAB,dc=TEST'; Expected = '' }
        @{ Dn = 'OU=Servers,OU=IacLab,DC=gpolab,DC=test'; Expected = 'OU=Servers,OU=IacLab' }
        @{ Dn = 'OU=Servers,OU=IacLab,dc=gpolab,dc=test'; Expected = 'OU=Servers,OU=IacLab' }
    ) {
        param($Dn, $Expected)
        ConvertTo-RelativeDn -Dn $Dn -RootDn 'DC=gpolab,DC=test' | Should -BeExactly $Expected
    }

    It 'refuses a DN outside the root, including a lookalike suffix' {
        { ConvertTo-RelativeDn -Dn 'OU=X,DC=other,DC=test' -RootDn 'DC=gpolab,DC=test' } | Should -Throw '*is not inside*'
        { ConvertTo-RelativeDn -Dn 'OU=X,DC=notgpolab,DC=test' -RootDn 'DC=gpolab,DC=test' } | Should -Throw '*is not inside*'
    }
}

Describe 'Get-TrusteeEntry' {
    It 'records <Name> (<SidType>) as <ExpectedName> (<ExpectedType>)' -TestCases @(
        @{ Name = 'GPOLAB\GG-IacLab-Servers'; SidType = 'Group'; ExpectedName = 'GG-IacLab-Servers'; ExpectedType = 'Group' }
        @{ Name = 'Authenticated Users'; SidType = 'WellKnownGroup'; ExpectedName = 'Authenticated Users'; ExpectedType = 'Group' }
        @{ Name = 'GPOLAB\alice'; SidType = 'User'; ExpectedName = 'alice'; ExpectedType = 'User' }
        @{ Name = 'GPOLAB\SRV01$'; SidType = 'Computer'; ExpectedName = 'SRV01$'; ExpectedType = 'Computer' }
        @{ Name = 'OTHER\GG-X'; SidType = 'Alias'; ExpectedName = 'OTHER\GG-X'; ExpectedType = 'Group' }
    ) {
        param($Name, $SidType, $ExpectedName, $ExpectedType)
        $entry = Get-TrusteeEntry -Permission (New-Permission -Name $Name -SidType $SidType) -NetBiosName 'GPOLAB'
        $entry.name | Should -BeExactly $ExpectedName
        $entry.type | Should -BeExactly $ExpectedType
        @($entry.Keys) | Should -Be @('name', 'type')
    }
}

Describe 'Get-CarriedOverGpoState' {
    BeforeAll {
        $script:state = @{
            'A' = @{ hash = 'HA'; dir = 'A' }
            'B' = @{ hash = 'HB'; dir = 'B' }
            'C?' = @{ hash = 'HC'; dir = 'C_' }
        }
    }

    It 'carries nothing over without a filter, so a GPO gone from the domain shows as deleted' {
        (Get-CarriedOverGpoState -State $script:state -Selected @()).Count | Should -Be 0
        (Get-CarriedOverGpoState -State $script:state).Count | Should -Be 0
    }

    It 'keeps every unselected GPO''s hash and folder with a filter (the 0.10.0 fix)' {
        $carried = Get-CarriedOverGpoState -State $script:state -Selected @('A')
        @($carried.Keys | Sort-Object) | Should -Be @('B', 'C?')
        $carried['B'].hash | Should -BeExactly 'HB'
        $carried['C?'].dir | Should -BeExactly 'C_'
    }

    It 'returns copies, not the recorded entries themselves' {
        $carried = Get-CarriedOverGpoState -State $script:state -Selected @('A')
        $carried['B'].hash = 'changed'
        $script:state['B'].hash | Should -BeExactly 'HB'
    }

    It 'treats empty names as no filter, and copes with no state' {
        (Get-CarriedOverGpoState -State $script:state -Selected @('', $null)).Count | Should -Be 0
        (Get-CarriedOverGpoState -State $null -Selected @('A')).Count | Should -Be 0
    }
}

Describe 'Get-DeletedGpoEntry' {
    BeforeAll {
        $script:recorded = @{
            'Old Policy' = @{ hash = 'H1'; dir = 'Old Policy' }
            'Kept' = @{ hash = 'H2'; dir = 'Kept' }
            'Also: gone' = @{ hash = 'H3'; dir = 'Also_ gone' }
        }
        $script:live = @{ 'Kept' = @{ hash = 'H2'; dir = 'Kept' } }
    }

    It 'returns the recorded GPOs the domain no longer has, sorted, with their folders' {
        $deleted = @(Get-DeletedGpoEntry -Recorded $script:recorded -Live $script:live -Filtered $false)
        $deleted.Count | Should -Be 2
        $deleted[0].name | Should -BeExactly 'Also: gone'
        $deleted[0].backup_dir | Should -BeExactly 'Also_ gone'
        $deleted[1].name | Should -BeExactly 'Old Policy'
        @($deleted[0].Keys) | Should -Be @('name', 'backup_dir')
    }

    It 'returns nothing while filtering: an unselected GPO is not a deleted one' {
        @(Get-DeletedGpoEntry -Recorded $script:recorded -Live $script:live -Filtered $true) | Should -BeNullOrEmpty
    }

    It 'returns nothing without a recorded state (the first export)' {
        @(Get-DeletedGpoEntry -Recorded $null -Live $script:live -Filtered $false) | Should -BeNullOrEmpty
        @(Get-DeletedGpoEntry -Recorded @{} -Live $script:live -Filtered $false) | Should -BeNullOrEmpty
    }
}
