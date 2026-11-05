# Pester 5 unit tests for gpo_export's logic: the pure functions it calls from
# plugins/module_utils/_GpoCommon.psm1 that name each GPO's folder, read and
# write its export record and decide what is exported again, and the module's
# wiring to that util. The module's behaviour against a domain is its
# integration target (tests/integration/targets/gpo_export). Run with
# Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/gpo_export.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_GpoCommon.psm1') -Force
    $script:id = '6AC1786C-016F-11D2-945F-00C04FB984F9'
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

    It 'never builds a path under the user-supplied path with Join-Path (it resolves the drive)' {
        $isJoin = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' }
        $joins = @($script:ast.FindAll($isJoin, $true) |
                Where-Object { $_.CommandElements.Count -gt 1 -and $_.CommandElements[1].Extent.Text -in '$DestPath', '$probeDir' } |
                ForEach-Object { $_.Extent.Text })
        $joins | Should -BeNullOrEmpty
    }

    It 'writes only under "if (-not $checkMode)", apart from the check-mode probe file' {
        $writers = @('Backup-GPO', 'New-Item', 'Remove-Item', 'Write-Utf8File')
        $isWrite = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $writers -contains $n.GetCommandName() }
        $writes = @($script:ast.FindAll($isWrite, $true))
        @($writes | ForEach-Object { $_.GetCommandName() } | Sort-Object -Unique) | Should -Be $writers
        $unguarded = @($writes | Where-Object {
                $guarded = $false
                for ($node = $_; $node.Parent; $node = $node.Parent) {
                    if ($node -is [System.Management.Automation.Language.StatementBlockAst] -and
                        $node.Parent -is [System.Management.Automation.Language.IfStatementAst]) {
                        foreach ($clause in $node.Parent.Clauses) {
                            if ($clause.Item2 -eq $node -and $clause.Item1.Extent.Text -eq '-not $checkMode') { $guarded = $true }
                        }
                    }
                }
                -not $guarded -and $_.Extent.Text -notmatch '-LiteralPath \$probeFile'
            } | ForEach-Object { $_.Extent.Text })
        $unguarded | Should -BeNullOrEmpty
    }

    It 'reports a preflight fact as $null until it is checked, not as $false' {
        $src = Get-Content -LiteralPath $script:modulePath -Raw
        foreach ($fact in 'ad', 'gpmc', 'path_writable', 'path_probed') {
            $src | Should -Match ('(?m)^\s+{0} = \$null\r?$' -f $fact)
        }
        # GPMC is read before the path probe, so a path failure still reports it.
        $src.IndexOf('preflight.gpmc = $true') | Should -BeLessThan $src.IndexOf('Get-NearestExistingDirectory -Path $DestPath')
    }

    It 'never touches links, filtering, WMI filters, status or inheritance' {
        $topology = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -match '^(New|Set|Remove)-GP(Link|Permission|Inheritance)$|^Get-GP(Permission|Inheritance)$|^(Get|New|Set)-ADObject$' })
        $topology | Should -BeNullOrEmpty
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

Describe 'Get-GpoFolderName' {
    It 'maps each name to its safe folder name, sorted by name' {
        $dirs = Get-GpoFolderName -Names @('b?', 'a', '', 'c')
        @($dirs.Keys) | Should -Be @('a', 'b?', 'c')
        $dirs['b?'] | Should -BeExactly 'b_'
    }

    It 'throws, naming both GPOs and the folder, when two names map to one folder' {
        { Get-GpoFolderName -Names @('Dup?', 'Dup:') } | Should -Throw "*'Dup:' and 'Dup?' map to the same folder name 'Dup_'*"
    }

    It 'treats folder names that differ only in case as a clash, as Windows does' {
        { Get-GpoFolderName -Names @('Policy', 'POLICY') } | Should -Throw '*map to the same folder name*'
    }
}

Describe 'ConvertTo-GpoId' {
    It 'normalises <Value>' -TestCases @(
        @{ Value = '{6AC1786C-016F-11D2-945F-00C04FB984F9}' }
        @{ Value = '6ac1786c-016f-11d2-945f-00c04fb984f9' }
        @{ Value = ' 6AC1786C-016F-11D2-945F-00C04FB984F9 ' }
    ) {
        param($Value)
        ConvertTo-GpoId -Value $Value | Should -BeExactly '6ac1786c-016f-11d2-945f-00c04fb984f9'
    }

    It 'returns an empty string for <Value>' -TestCases @(
        @{ Value = '' }
        @{ Value = 'not-a-guid' }
    ) {
        param($Value)
        ConvertTo-GpoId -Value $Value | Should -BeExactly ''
    }
}

Describe 'The export record' {
    It 'round-trips through gpo-export.json' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'round') -Force
        $json = ConvertTo-GpoExportRecordJson -Name 'IacLab - RDP' -Id "{$script:id}" -Domain 'lab.example' -ContentHash 'ABC'
        Write-Utf8File -Path (Join-Path $dir.FullName 'gpo-export.json') -Content $json
        $record = Read-GpoExportRecord -Path $dir.FullName
        $record.name | Should -BeExactly 'IacLab - RDP'
        $record.id | Should -BeExactly $script:id.ToLowerInvariant()
        $record.content_hash | Should -BeExactly 'ABC'
        ($json | ConvertFrom-Json).hash_basis | Should -BeExactly 'sysvol'
        ($json | ConvertFrom-Json).domain | Should -BeExactly 'lab.example'
    }

    It 'reads as $null when the folder has none' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'none') -Force
        Read-GpoExportRecord -Path $dir.FullName | Should -BeNullOrEmpty
    }

    It 'reads as $null when it does not parse' {
        $dir = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'bad') -Force
        [System.IO.File]::WriteAllText((Join-Path $dir.FullName 'gpo-export.json'), '{ not json')
        Read-GpoExportRecord -Path $dir.FullName | Should -BeNullOrEmpty
    }
}

Describe 'Get-GpoExportReason' {
    BeforeAll {
        $script:record = @{ name = 'X'; id = $script:id.ToLowerInvariant(); content_hash = 'H1' }
    }

    It 'exports a GPO whose folder is missing' {
        Get-GpoExportReason -FolderExists $false -Id $script:id -ContentHash 'H1' | Should -BeExactly 'not exported yet'
    }

    It 'exports again into an incomplete folder, saying why' {
        Get-GpoExportReason -FolderExists $true -Problem 'no gpreport.xml in {B}' -Record $script:record -Id $script:id -ContentHash 'H1' |
            Should -BeExactly 'backup folder incomplete (no gpreport.xml in {B})'
    }

    It 'exports again into a folder without a record (an interrupted run)' {
        Get-GpoExportReason -FolderExists $true -Id $script:id -ContentHash 'H1' | Should -BeExactly 'no export record'
    }

    It 'exports again when the folder holds another GPO of the same name' {
        Get-GpoExportReason -FolderExists $true -Record $script:record -Id ([guid]::NewGuid().ToString()) -ContentHash 'H1' |
            Should -BeExactly 'the folder holds another GPO''s backup'
    }

    It 'exports again when the live content changed' {
        Get-GpoExportReason -FolderExists $true -Record $script:record -Id $script:id -ContentHash 'H2' | Should -BeExactly 'content changed'
    }

    It 'leaves an up-to-date folder alone, whatever the GUID''s form' {
        Get-GpoExportReason -FolderExists $true -Record $script:record -Id "{$script:id}" -ContentHash 'H1' | Should -BeExactly ''
    }
}
