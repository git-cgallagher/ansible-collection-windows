# Pester 5 unit tests for plugins/module_utils/_GpoCommon.psm1, the pure logic
# gpo_export and gpo_import share. No domain, no Ansible: run them with
#   Invoke-Pester -Path tests/unit
# (the powershell CI job does). Windows PowerShell 5.1 or pwsh.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:utilPath = Join-Path $script:repoRoot 'plugins/module_utils/_GpoCommon.psm1'
    Import-Module $script:utilPath -Force

    # Windows semantics where they matter: the modules run on Windows, where
    # StringBuilder.AppendLine writes CRLF. These pinned values are what a
    # module on Windows records; on another OS the LF ones are expected.
    $script:nl = [Environment]::NewLine
    $script:pinnedFull = @{
        "`r`n" = '36A5AFCB018E6EA779CD3B9A7CAE59CA1130598FAD0685E294EEFF7D3230CD58'
        "`n" = '300DF96BAE5E468FCB07FE40D773A63099644DF76BD08A76147FE8A826F5708E'
    }

    function script:New-FlatTree {
        param([string]$Root)
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Root 'a.txt'), 'x')
        New-Item -ItemType Directory -Path (Join-Path $Root 'empty') | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $Root 'gpt.ini'), '[General]')
        $Root
    }
}

AfterAll {
    Remove-Module _GpoCommon -ErrorAction SilentlyContinue
}

Describe 'The module util' {
    It 'exports exactly the functions it defines' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:utilPath, [ref]$null, [ref]$null)
        $defined = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
                ForEach-Object { $_.Name } | Sort-Object)
        $exported = @((Get-Module _GpoCommon).ExportedFunctions.Keys | Sort-Object)
        $exported | Should -Be $defined
    }
}

Describe 'ConvertTo-SafeName' {
    It 'replaces <Name> with <Expected>' -TestCases @(
        @{ Name = 'IacLab - Server Baseline'; Expected = 'IacLab - Server Baseline' }
        @{ Name = 'a\b/c:d*e?f"g<h>i|j'; Expected = 'a_b_c_d_e_f_g_h_i_j' }
        @{ Name = 'Trailing. . '; Expected = 'Trailing' }
        @{ Name = '...'; Expected = '_' }
        @{ Name = ''; Expected = '_' }
    ) {
        param($Name, $Expected)
        ConvertTo-SafeName -Name $Name | Should -BeExactly $Expected
    }

    It 'maps two names to one folder, the clash gpo_export refuses' {
        ConvertTo-SafeName -Name 'Dup?' | Should -BeExactly (ConvertTo-SafeName -Name 'Dup:')
    }
}

Describe 'Get-StringHash' {
    It 'is the upper-case hex SHA-256 of the UTF-8 bytes' {
        Get-StringHash -Text '' | Should -BeExactly 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        $eAcute = [string][char]0xE9
        # SHA-256 of the UTF-8 bytes C3 A9, not of the UTF-16 or ANSI ones.
        Get-StringHash -Text $eAcute | Should -BeExactly '4A99557E4033C3539DE2EB65472017CAD5F9557F7A0625A09F1C3F6E2BA69C4C'
        Get-StringHash -Text 'a' | Should -Not -Be (Get-StringHash -Text 'A')
    }
}

Describe 'Get-DirContentHash' {
    It 'returns an empty string for a missing or empty path' {
        Get-DirContentHash -Path (Join-Path $TestDrive 'missing') | Should -BeExactly ''
        Get-DirContentHash -Path '' | Should -BeExactly ''
    }

    It 'keeps its format: the pinned value for a known tree' {
        $root = New-FlatTree -Root (Join-Path $TestDrive 'pinned')
        Get-DirContentHash -Path $root | Should -BeExactly $script:pinnedFull[$script:nl]
    }

    It 'hashes the lines it documents, in case-folded path order' {
        $root = Join-Path $TestDrive 'lines'
        New-Item -ItemType Directory -Path (Join-Path $root 'Sub') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'B.txt'), 'two')
        [System.IO.File]::WriteAllText((Join-Path $root 'Sub/c.txt'), 'three')
        $sep = [System.IO.Path]::DirectorySeparatorChar
        $sha = { param($t) (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($t))) -Algorithm SHA256).Hash }
        $expected = "file|b.txt|$(& $sha 'two')$($script:nl)dir|sub$($script:nl)file|sub$($sep)c.txt|$(& $sha 'three')$($script:nl)"
        Get-DirContentHash -Path $root | Should -BeExactly (Get-StringHash -Text $expected)
    }

    It 'changes when an empty directory appears' {
        $root = Join-Path $TestDrive 'emptydir'
        New-Item -ItemType Directory -Path $root | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $root 'a.txt'), 'x')
        $before = Get-DirContentHash -Path $root
        New-Item -ItemType Directory -Path (Join-Path $root 'User') | Out-Null
        Get-DirContentHash -Path $root | Should -Not -Be $before
    }

    It 'changes when a file''s content changes, and not when only its timestamp does' {
        $root = Join-Path $TestDrive 'content'
        New-Item -ItemType Directory -Path $root | Out-Null
        $file = Join-Path $root 'a.txt'
        [System.IO.File]::WriteAllText($file, 'x')
        $before = Get-DirContentHash -Path $root
        (Get-Item -LiteralPath $file).LastWriteTimeUtc = [datetime]'2020-01-01'
        Get-DirContentHash -Path $root | Should -BeExactly $before
        [System.IO.File]::WriteAllText($file, 'y')
        Get-DirContentHash -Path $root | Should -Not -Be $before
    }

    It 'leaves out the excluded relative paths, case-insensitively' {
        $root = New-FlatTree -Root (Join-Path $TestDrive 'exclude')
        $without = Get-DirContentHash -Path $root -Exclude 'GPT.INI'
        $without | Should -Not -Be (Get-DirContentHash -Path $root)
        Remove-Item -LiteralPath (Join-Path $root 'gpt.ini')
        Get-DirContentHash -Path $root | Should -BeExactly $without
    }
}

Describe 'Get-GpoSysvolPath' {
    It 'returns the DomainSysvol folder of the backup''s {GUID} folder' {
        $wrapper = Join-Path $TestDrive 'backup'
        $sysvol = Join-Path $wrapper '{11111111-2222-3333-4444-555555555555}/DomainSysvol'
        New-Item -ItemType Directory -Path $sysvol -Force | Out-Null
        Get-GpoSysvolPath -BackupDir $wrapper | Should -Be (Get-Item -LiteralPath $sysvol).FullName
    }

    It 'returns $null for a GPO with no settings (no DomainSysvol) or no {GUID} folder' {
        $noSettings = Join-Path $TestDrive 'nosettings'
        New-Item -ItemType Directory -Path (Join-Path $noSettings '{AAAA}') -Force | Out-Null
        Get-GpoSysvolPath -BackupDir $noSettings | Should -BeNullOrEmpty
        $noGuid = Join-Path $TestDrive 'noguid'
        New-Item -ItemType Directory -Path (Join-Path $noGuid 'other') -Force | Out-Null
        Get-GpoSysvolPath -BackupDir $noGuid | Should -BeNullOrEmpty
    }
}

Describe 'Write-Utf8File' {
    It 'writes UTF-8 without a byte order mark' {
        $file = Join-Path $TestDrive 'utf8.json'
        $content = '{"name":"' + [char]0xE9 + '"}'
        Write-Utf8File -Path $file -Content $content
        $bytes = [System.IO.File]::ReadAllBytes($file)
        $bytes[0] | Should -Be ([byte][char]'{')
        $bytes.Length | Should -Be ($content.Length + 1)
        [System.Text.Encoding]::UTF8.GetString($bytes) | Should -BeExactly $content
    }
}

Describe 'Get-NearestExistingDirectory' {
    It 'returns an existing directory itself' {
        Get-NearestExistingDirectory -Path $TestDrive | Should -Be $TestDrive
    }

    It 'returns the nearest existing parent of a directory that doesn''t exist yet' {
        $missing = Join-Path (Join-Path (Join-Path $TestDrive 'a') 'b') 'c'
        Get-NearestExistingDirectory -Path $missing | Should -Be $TestDrive
    }

    It 'skips a file of that name: a file is not a directory to probe' {
        $file = Join-Path $TestDrive 'plainfile'
        [System.IO.File]::WriteAllText($file, '')
        Get-NearestExistingDirectory -Path $file | Should -Be $TestDrive
    }

    It 'returns $null, without an error, for a path on a drive that doesn''t exist' {
        # Windows PowerShell's Test-Path writes "Cannot find drive" for such a
        # path, which the modules' $ErrorActionPreference = 'Stop' turns into
        # a failure before the preflight can say why (found by gpo_export's
        # integration target). pwsh on Linux doesn't, so model Windows: the
        # mock throws unless the call suppresses errors.
        Mock -ModuleName _GpoCommon Test-Path {
            if ($PesterBoundParameters['ErrorAction'] -ne 'SilentlyContinue') {
                throw "Cannot find drive. A drive with the name 'Q' does not exist."
            }
            $false
        }
        Get-NearestExistingDirectory -Path 'Q:\gpo-iac\backup' | Should -BeNullOrEmpty
        Get-DirContentHash -Path 'Q:\gpo-iac' | Should -BeExactly ''
        Should -Invoke -ModuleName _GpoCommon Test-Path -Times 2 -Exactly -ParameterFilter { $ErrorAction -eq 'SilentlyContinue' } -Scope It
    }

    It 'returns $null when no parent exists, or for an empty path' {
        Get-NearestExistingDirectory -Path '' | Should -BeNullOrEmpty
        Get-NearestExistingDirectory -Path 'relative-nowhere/at/all' | Should -BeNullOrEmpty
    }
}

Describe 'Test-Denied' {
    It 'is true only for a permission whose Denied is set' {
        Test-Denied ([pscustomobject]@{ Permission = 'GpoApply'; Denied = $true }) | Should -BeTrue
        Test-Denied ([pscustomobject]@{ Permission = 'GpoApply'; Denied = $false }) | Should -BeFalse
        Test-Denied ([pscustomobject]@{ Permission = 'GpoApply' }) | Should -BeFalse
    }
}

Describe 'Get-RelativeTrusteeName' {
    It 'strips only this domain''s NetBIOS prefix' {
        Get-RelativeTrusteeName -Name 'GPOLAB\GG-IacLab-Servers' -NetBiosName 'GPOLAB' | Should -BeExactly 'GG-IacLab-Servers'
        Get-RelativeTrusteeName -Name 'OTHER\GG-IacLab-Servers' -NetBiosName 'GPOLAB' | Should -BeExactly 'OTHER\GG-IacLab-Servers'
        Get-RelativeTrusteeName -Name 'Authenticated Users' -NetBiosName 'GPOLAB' | Should -BeExactly 'Authenticated Users'
        Get-RelativeTrusteeName -Name 'NT AUTHORITY\SYSTEM' -NetBiosName 'GPOLAB' | Should -BeExactly 'NT AUTHORITY\SYSTEM'
    }
}

Describe 'WMI filter msWMI-Parm2 encoding' {
    It 'round-trips namespace <Namespace> and query <Query>' -TestCases @(
        @{ Namespace = 'root\CIMv2'; Query = 'SELECT * FROM Win32_OperatingSystem WHERE ProductType > 1' }
        @{ Namespace = 'root\CIMv2'; Query = "SELECT * FROM Win32_ComputerSystem WHERE Name LIKE 'a;b%'" }
        @{ Namespace = 'root\virtualization\v2'; Query = 'SELECT * FROM Msvm_ComputerSystem' }
    ) {
        param($Namespace, $Query)
        $parsed = ConvertFrom-WmiFilterParm2 -Parm2 (ConvertTo-WmiFilterParm2 -Namespace $Namespace -Query $Query)
        $parsed.namespace | Should -BeExactly $Namespace
        $parsed.query | Should -BeExactly $Query
    }

    It 'encodes the way GPMC writes it' {
        ConvertTo-WmiFilterParm2 -Namespace 'root\CIMv2' -Query 'SELECT * FROM X' |
            Should -BeExactly '1;3;10;15;WQL;root\CIMv2;SELECT * FROM X;'
    }

    It 'returns $null for a multi-query filter or text that doesn''t parse' {
        ConvertFrom-WmiFilterParm2 -Parm2 '2;3;10;15;WQL;root\CIMv2;SELECT * FROM X;3;10;15;WQL;root\CIMv2;SELECT * FROM Y;' |
            Should -BeNullOrEmpty
        ConvertFrom-WmiFilterParm2 -Parm2 'garbage' | Should -BeNullOrEmpty
        ConvertFrom-WmiFilterParm2 -Parm2 '' | Should -BeNullOrEmpty
    }
}
