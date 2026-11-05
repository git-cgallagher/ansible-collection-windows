# Pester 5 unit tests for gpo_import's logic: the pure functions it calls from
# plugins/module_utils/_GpoCommon.psm1 that find and resolve backups by the
# GPO name they record, refuse cpassword, key and record imports, and the
# module's wiring to that util. The module's behaviour against a domain is its
# integration target (tests/integration/targets/gpo_import). Run with
# Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/gpo_import.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_GpoCommon.psm1') -Force

    # A Backup-GPO instance: {backup-id}\ with Backup.xml, gpreport.xml and
    # bkupInfo.xml in Backup-GPO's namespace, CDATA values included.
    function script:New-Backup {
        param([string]$Root, [string]$Name, [string]$GpoId = [guid]::NewGuid().ToString(), [string]$BackupId = [guid]::NewGuid().ToString(),
            [string[]]$Skip = @())
        $dir = Join-Path $Root ('{' + $BackupId.ToUpperInvariant() + '}')
        New-Item -ItemType Directory -Path (Join-Path $dir 'DomainSysvol/GPO/Machine') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'DomainSysvol/GPO/Machine/registry.pol'), "settings of $Name")
        $values = @($GpoId.ToUpperInvariant(), $BackupId.ToUpperInvariant(), $Name)
        $info = ('<?xml version="1.0" encoding="utf-8"?><BackupInst xmlns="http://www.microsoft.com/GroupPolicy/GPOOperations/Manifest">' +
            '<GPOGuid><![CDATA[{{{0}}}]]></GPOGuid><GPODomain><![CDATA[lab.example]]></GPODomain><ID><![CDATA[{{{1}}}]]></ID>' +
            '<Comment><![CDATA[]]></Comment><GPODisplayName><![CDATA[{2}]]></GPODisplayName></BackupInst>') -f $values
        $files = @{ 'Backup.xml' = '<GroupPolicyBackupScheme/>'; 'gpreport.xml' = '<GPO/>'; 'bkupInfo.xml' = $info }
        foreach ($f in $files.Keys) {
            if ($Skip -notcontains $f) { [System.IO.File]::WriteAllText((Join-Path $dir $f), $files[$f]) }
        }
        $dir
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
        $isJoin = { param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Join-Path' }
        @($script:ast.FindAll($isJoin, $true)) | Should -BeNullOrEmpty
    }

    It 'writes only under "if (-not $checkMode)", apart from the preflight''s probe file' {
        $writers = @('Import-GPO', 'New-Item', 'Remove-Item', 'Write-Utf8File')
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

    It 'never deletes a GPO, unlinks one, or touches links, filtering, WMI filters, status or inheritance' {
        $forbidden = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -match '^Remove-GPO$|^(New|Set|Remove)-GP(Link|Permission|Inheritance)$|^(New|Set|Remove)-ADObject$|^Rename-GPO$' })
        $forbidden | Should -BeNullOrEmpty
        Get-Content -LiteralPath $script:modulePath -Raw | Should -Not -Match '\.(GpoStatus|WmiFilter)\s*='
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

Describe 'Get-GpoBackupIndex' {
    It 'finds backups directly under the path and one level down, by the name bkupInfo.xml records' {
        $root = Join-Path $TestDrive 'index'
        $gpoId = [guid]::NewGuid().ToString()
        $backupId = [guid]::NewGuid().ToString()
        $flat = New-Backup -Root $root -Name 'Flat GPO' -GpoId $gpoId -BackupId $backupId
        $nested = New-Backup -Root (Join-Path $root 'folder named otherwise') -Name 'Nested GPO'
        $index = Get-GpoBackupIndex -Path $root
        @($index.backups).Count | Should -Be 2
        $f = $index.backups | Where-Object { $_.name -eq 'Flat GPO' }
        $f.dir | Should -Be (Get-Item -LiteralPath $flat).FullName
        $f.parent | Should -Be (Get-Item -LiteralPath $root).FullName
        $f.gpo_id | Should -BeExactly $gpoId.ToLowerInvariant()
        $f.backup_id | Should -BeExactly $backupId.ToLowerInvariant()
        ($index.backups | Where-Object { $_.name -eq 'Nested GPO' }).parent | Should -Be (Get-Item -LiteralPath (Split-Path -LiteralPath $nested)).FullName
        $index.unreadable | Should -BeNullOrEmpty
    }

    It 'skips folders without bkupInfo.xml and does not look two levels down' {
        $root = Join-Path $TestDrive 'skip'
        New-Backup -Root $root -Name 'No info' -Skip 'bkupInfo.xml' | Out-Null
        New-Backup -Root (Join-Path $root 'a/b') -Name 'Too deep' | Out-Null
        @((Get-GpoBackupIndex -Path $root).backups) | Should -BeNullOrEmpty
    }

    It 'lists a backup whose bkupInfo.xml does not parse as unreadable' {
        $root = Join-Path $TestDrive 'unreadable'
        $dir = New-Backup -Root $root -Name 'Broken'
        [System.IO.File]::WriteAllText((Join-Path $dir 'bkupInfo.xml'), '<BackupInst>')
        $index = Get-GpoBackupIndex -Path $root
        @($index.backups) | Should -BeNullOrEmpty
        @($index.unreadable) | Should -Be @((Get-Item -LiteralPath $dir).FullName)
    }

    It 'returns nothing for a missing path' {
        $index = Get-GpoBackupIndex -Path (Join-Path $TestDrive 'missing')
        @($index.backups) | Should -BeNullOrEmpty
    }
}

Describe 'Resolve-GpoBackupName' {
    BeforeAll {
        $script:backups = @(
            [ordered]@{ name = 'Server Baseline'; dir = 'C:\b\1' }
            [ordered]@{ name = 'RDP'; dir = 'C:\b\2' }
            [ordered]@{ name = 'rdp'; dir = 'C:\b\3' }
        )
    }

    It 'resolves names case-insensitively, in the order given, once each' {
        $r = Resolve-GpoBackupName -Backups $script:backups -Names @('server baseline', 'SERVER BASELINE')
        @($r.resolved.Keys) | Should -Be @('server baseline')
        $r.resolved['server baseline'].dir | Should -Be 'C:\b\1'
        $r.missing | Should -BeNullOrEmpty
        $r.ambiguous | Should -BeNullOrEmpty
    }

    It 'reports a name no backup records as missing' {
        $r = Resolve-GpoBackupName -Backups $script:backups -Names @('Server Baseline', 'Nope')
        @($r.missing) | Should -Be @('Nope')
        @($r.resolved.Keys) | Should -Be @('Server Baseline')
    }

    It 'reports a name two backups record as ambiguous, naming both' {
        $r = Resolve-GpoBackupName -Backups $script:backups -Names @('RDP')
        @($r.ambiguous) | Should -Be @('RDP: C:\b\2, C:\b\3')
        @($r.resolved.Keys) | Should -BeNullOrEmpty
    }
}

Describe 'Test-GpoBackupInstance' {
    It 'passes a complete backup' {
        Test-GpoBackupInstance -Path (New-Backup -Root (Join-Path $TestDrive 'complete') -Name 'X') | Should -BeExactly ''
    }

    It 'names the missing <File>' -TestCases @(
        @{ File = 'Backup.xml' }
        @{ File = 'gpreport.xml' }
    ) {
        param($File)
        $dir = New-Backup -Root (Join-Path $TestDrive "no-$File") -Name 'X' -Skip $File
        Test-GpoBackupInstance -Path $dir | Should -Match "^no $([regex]::Escape($File)) in \{"
    }
}

Describe 'Get-GpoCpasswordFile' {
    It 'finds a non-empty cpassword and ignores an empty one, only under the given directories' {
        $a = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cp/a/Preferences') -Force
        $b = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cp/b') -Force
        $c = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'cp/c') -Force
        [System.IO.File]::WriteAllText((Join-Path $a.FullName 'Groups.xml'), '<User cpassword="example-not-secret"/>')
        [System.IO.File]::WriteAllText((Join-Path $b.FullName 'Groups.xml'), '<User cpassword=""/>')
        [System.IO.File]::WriteAllText((Join-Path $c.FullName 'Groups.xml'), '<User cpassword="x"/>')
        $found = Get-GpoCpasswordFile -Path @((Join-Path $TestDrive 'cp/a'), (Join-Path $TestDrive 'cp/b'), (Join-Path $TestDrive 'missing'))
        @($found) | Should -Be @((Join-Path $a.FullName 'Groups.xml'))
    }

    It 'returns nothing for no directories' {
        @(Get-GpoCpasswordFile -Path @()) | Should -BeNullOrEmpty
    }
}

Describe 'Get-GpoImportKey' {
    It 'changes with the settings and with the migration table, not with the backup''s metadata' {
        $dir = New-Backup -Root (Join-Path $TestDrive 'key') -Name 'X'
        $key = Get-GpoImportKey -BackupDir $dir
        [System.IO.File]::WriteAllText((Join-Path $dir 'gpreport.xml'), '<GPO generated="later"/>')
        Get-GpoImportKey -BackupDir $dir | Should -BeExactly $key
        Get-GpoImportKey -BackupDir $dir -MigrationTableHash 'ABC' | Should -Not -Be $key
        [System.IO.File]::WriteAllText((Join-Path $dir 'DomainSysvol/GPO/Machine/registry.pol'), 'other settings')
        Get-GpoImportKey -BackupDir $dir | Should -Not -Be $key
    }

    It 'is gpo_sync_import''s key for the same backup: the DomainSysvol hash and the table''s, joined by |' {
        $dir = New-Backup -Root (Join-Path $TestDrive 'same') -Name 'X'
        $expected = Get-StringHash -Text ((Get-DirContentHash -Path (Join-Path $dir 'DomainSysvol')) + '|' + 'T')
        Get-GpoImportKey -BackupDir $dir -MigrationTableHash 'T' | Should -BeExactly $expected
    }
}

Describe 'The import record' {
    It 'round-trips, keyed by GUID in one form' {
        $file = Join-Path $TestDrive 'record.json'
        $id = [guid]::NewGuid().ToString()
        $record = @{ $id = @{ name = 'Server Baseline'; import_key = 'K1'; version = '2/2/0/0' } }
        Write-Utf8File -Path $file -Content (ConvertTo-GpoImportRecordJson -Record $record)
        $read = Read-GpoImportRecord -Path $file
        @($read.Keys) | Should -Be @($id.ToLowerInvariant())
        $read[$id.ToLowerInvariant()].name | Should -BeExactly 'Server Baseline'
        $read[$id.ToLowerInvariant()].import_key | Should -BeExactly 'K1'
        $read[$id.ToLowerInvariant()].version | Should -BeExactly '2/2/0/0'
    }

    It 'writes the same bytes for the same record, whatever the insertion order' {
        $idA = 'a0000000-0000-0000-0000-000000000000'
        $idB = 'b0000000-0000-0000-0000-000000000000'
        $a = @{}
        $a[$idB] = @{ name = 'B'; import_key = '2' }
        $a[$idA] = @{ name = 'A'; import_key = '1' }
        $b = @{}
        $b[$idA] = @{ name = 'A'; import_key = '1' }
        $b[$idB] = @{ name = 'B'; import_key = '2' }
        ConvertTo-GpoImportRecordJson -Record $a | Should -BeExactly (ConvertTo-GpoImportRecordJson -Record $b)
    }

    It 'reads as empty when the file does not exist' {
        (Read-GpoImportRecord -Path (Join-Path $TestDrive 'none.json')).Count | Should -Be 0
    }

    It 'throws when the file does not parse' {
        $file = Join-Path $TestDrive 'bad.json'
        [System.IO.File]::WriteAllText($file, '{ "other": 1 }')
        { Read-GpoImportRecord -Path $file } | Should -Throw "*has no 'gpos' object*"
    }
}

Describe 'Get-GpoImportDecision' {
    BeforeAll {
        $script:target = '6ac1786c-016f-11d2-945f-00c04fb984f9'
        $script:rec = @{ $script:target = @{ name = 'X'; import_key = 'K1'; version = '3/3/0/0' } }
    }

    It 'imports a GPO the domain lacks, record or not' {
        Get-GpoImportDecision -TargetId '' -Record $script:rec -ImportKey 'K1' | Should -BeExactly 'GPO missing in target'
    }

    It 'imports a GPO the record does not name (a missing or unreadable record reads as empty)' {
        Get-GpoImportDecision -TargetId $script:target -Record @{} -ImportKey 'K1' | Should -BeExactly 'never imported by this pipeline'
        Get-GpoImportDecision -TargetId $script:target -ImportKey 'K1' | Should -BeExactly 'never imported by this pipeline'
    }

    It 'imports a GPO of the same name under another GUID (the record names only GUIDs)' {
        Get-GpoImportDecision -TargetId ([guid]::NewGuid().ToString()) -Record $script:rec -ImportKey 'K1' |
            Should -BeExactly 'never imported by this pipeline'
    }

    It 'imports when the backup or the migration table changed' {
        Get-GpoImportDecision -TargetId $script:target -Record $script:rec -ImportKey 'K2' |
            Should -BeExactly 'backup content or migration table changed'
    }

    It 'skips a GPO already imported from the same backup and table, whatever the GUID''s form' {
        Get-GpoImportDecision -TargetId "{$($script:target.ToUpperInvariant())}" -LiveVersion '3/3/0/0' -Record $script:rec -ImportKey 'K1' |
            Should -BeExactly ''
    }

    It 'imports again when the target GPO was edited since, naming both versions' {
        Get-GpoImportDecision -TargetId $script:target -LiveVersion '4/4/0/0' -Record $script:rec -ImportKey 'K1' |
            Should -BeExactly 'target GPO edited since last import (version 3/3/0/0 -> 4/4/0/0)'
    }

    It 'gives a changed backup as the reason when the GPO was edited too' {
        Get-GpoImportDecision -TargetId $script:target -LiveVersion '4/4/0/0' -Record $script:rec -ImportKey 'K2' |
            Should -BeExactly 'backup content or migration table changed'
    }

    It 'imports again when the record holds no version for the GPO' {
        $old = @{ $script:target = @{ name = 'X'; import_key = 'K1'; version = '' } }
        Get-GpoImportDecision -TargetId $script:target -LiveVersion '3/3/0/0' -Record $old -ImportKey 'K1' |
            Should -BeExactly 'target GPO edited since last import (version  -> 3/3/0/0)'
    }

    It 'imports with force, even when up to date' {
        Get-GpoImportDecision -Force $true -TargetId $script:target -Record $script:rec -ImportKey 'K1' | Should -BeExactly 'forced'
    }

    It 'decides from a record file end to end: same backup skipped, changed table imported' {
        $dir = New-Backup -Root (Join-Path $TestDrive 'e2e') -Name 'X'
        $file = Join-Path $TestDrive 'e2e.json'
        $key = Get-GpoImportKey -BackupDir $dir -MigrationTableHash ''
        $entry = @{ name = 'X'; import_key = $key; version = '5/5/1/1' }
        Write-Utf8File -Path $file -Content (ConvertTo-GpoImportRecordJson -Record @{ $script:target = $entry })
        $record = Read-GpoImportRecord -Path $file
        Get-GpoImportDecision -TargetId $script:target -LiveVersion '5/5/1/1' -Record $record -ImportKey (Get-GpoImportKey -BackupDir $dir) |
            Should -BeExactly ''
        Get-GpoImportDecision -TargetId $script:target -LiveVersion '5/5/1/1' -Record $record `
            -ImportKey (Get-GpoImportKey -BackupDir $dir -MigrationTableHash 'T') | Should -BeExactly 'backup content or migration table changed'
        Get-GpoImportDecision -TargetId $script:target -LiveVersion '6/6/1/1' -Record $record -ImportKey (Get-GpoImportKey -BackupDir $dir) |
            Should -BeExactly 'target GPO edited since last import (version 5/5/1/1 -> 6/6/1/1)'
    }
}

Describe 'Get-GpoVersionStamp' {
    It 'joins the computer and user AD and SYSVOL versions, in that order' {
        $gpo = [pscustomobject]@{
            Computer = [pscustomobject]@{ DSVersion = 7; SysvolVersion = 6 }
            User = [pscustomobject]@{ DSVersion = 2; SysvolVersion = 1 }
        }
        Get-GpoVersionStamp -Gpo $gpo | Should -BeExactly '7/6/2/1'
    }

    It 'moves when an edit bumps any one of them' {
        $user = [pscustomobject]@{ DSVersion = 0; SysvolVersion = 0 }
        $before = [pscustomobject]@{ Computer = [pscustomobject]@{ DSVersion = 7; SysvolVersion = 7 }; User = $user }
        $after = [pscustomobject]@{ Computer = [pscustomobject]@{ DSVersion = 7; SysvolVersion = 8 }; User = $user }
        Get-GpoVersionStamp -Gpo $after | Should -Not -Be (Get-GpoVersionStamp -Gpo $before)
    }
}
