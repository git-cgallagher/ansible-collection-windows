# Pester 5 unit tests for iis_mime_type_info's logic: the function it calls
# from plugins/module_utils/_IisConfig.psm1 that filters and sorts a level's
# MIME map and tells inherited entries from local ones, and the module's
# wiring to that util. Reading the map and the stored extensions is in
# tests/unit/plugins/module_utils/_IisConfig.Tests.ps1. The module's behaviour
# against IIS is its integration target (tests/integration/targets/iis_mime_type_info).
# Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/iis_mime_type_info.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_IisConfig.psm1') -Force

    $script:site = 'MACHINE/WEBROOT/APPHOST/Default Web Site'

    # Entries as Get-IisMimeMapEntry returns them, from extension = MIME type.
    function script:New-MimeEntry {
        param([System.Collections.IDictionary]$Map)
        $i = 0
        foreach ($key in $Map.Keys) {
            [pscustomobject]@{ Index = $i; Extension = $key; MimeType = $Map[$key] }
            $i++
        }
    }

    function script:New-Stored {
        param([string[]]$Extensions)
        $set = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($e in $Extensions) {
            $null = $set.Add($e)
        }
        , $set
    }
}

AfterAll {
    Remove-Module _IisConfig -ErrorAction SilentlyContinue
}

Describe 'iis_mime_type_info''s wiring' {
    BeforeAll {
        $script:text = Get-Content -LiteralPath $script:modulePath -Raw
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
        $script:util = @((Get-Module _IisConfig).ExportedFunctions.Keys)
    }

    It 'loads the IIS module util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._IisConfig\r?$'
    }

    It 'defines no functions of its own (no copy of the util''s to drift)' {
        @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) |
            Should -BeNullOrEmpty
    }

    It 'calls nothing but the util and PowerShell, and writes nothing' {
        $called = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        @($called | Where-Object { $script:util -notcontains $_ -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }) |
            Should -BeNullOrEmpty
        foreach ($writer in 'Invoke-IisMimeMapChange', 'Set-IisElementValue', 'Invoke-IisComMember') {
            $called | Should -Not -Contain $writer
        }
        $script:text | Should -Not -Match 'CommitPath'
    }

    It 'reads the level, its parent and what the level stores, and lists through the util' {
        $names = 'ConvertTo-IisFileExtension', 'Resolve-IisConfigLevel', 'Get-IisMimeMapEntry', 'Get-IisStoredMimeMapExtension', 'Get-IisMimeTypeList'
        foreach ($name in $names) {
            $script:text | Should -Match "$name "
        }
    }

    It 'declares the documented options, none required' {
        $specAst = $script:ast.Find({
                param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$spec'
            }, $false)
        $spec = & ([scriptblock]::Create($specAst.Right.Extent.Text))
        @($spec.options.Keys | Sort-Object) | Should -Be @('application', 'extension', 'mime_type', 'site')
        @($spec.options.Values | Where-Object { $_.required }) | Should -BeNullOrEmpty
        $spec.required_by.application | Should -BeExactly 'site'
        $spec.supports_check_mode | Should -BeTrue
    }
}

Describe 'Get-IisMimeTypeList' {
    BeforeAll {
        $script:entries = @(New-MimeEntry ([ordered]@{
                    '.zip' = 'application/x-zip-compressed'
                    '.TXT' = 'text/plain'
                    '.~tmp' = 'application/octet-stream'
                    '.apk' = 'application/vnd.android.package-archive'
                    '.7z' = 'application/x-7z-compressed'
                    '.Css' = 'text/css'
                    '.log' = 'text/plain'
                }))
    }

    It 'returns a list of ordered results with the documented keys' {
        $list = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site
        $list.GetType().FullName | Should -Match '^System\.Collections\.Generic\.List`1\[\[System\.Object'
        @($list).Count | Should -Be 7
        @($list[0].Keys) | Should -Be @('extension', 'mime_type', 'config_path', 'inherited')
        $list[0].config_path | Should -BeExactly $script:site
    }

    It 'sorts by extension ordinally, ignoring case, whatever the host''s culture' {
        $list = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site
        @($list | ForEach-Object { $_.extension }) | Should -Be @('.7z', '.apk', '.Css', '.log', '.TXT', '.zip', '.~tmp')
    }

    It 'filters by extension, case-insensitively, keeping IIS''s spelling' {
        $list = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site -Extension '.txt'
        @($list).Count | Should -Be 1
        $list[0].extension | Should -BeExactly '.TXT'
        $list[0].mime_type | Should -BeExactly 'text/plain'
    }

    It 'filters by MIME type, case-insensitively' {
        $list = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site -MimeType 'TEXT/PLAIN'
        @($list | ForEach-Object { $_.extension }) | Should -Be @('.log', '.TXT')
    }

    It 'applies both filters together' {
        $both = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site -Extension '.log' -MimeType 'text/plain'
        @($both | ForEach-Object { $_.extension }) | Should -Be @('.log')
        $neither = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site -Extension '.log' -MimeType 'text/css'
        $neither.Count | Should -Be 0
    }

    It 'returns an empty list, not $null, when nothing matches or the level maps nothing' {
        $none = Get-IisMimeTypeList -Entries $script:entries -ConfigPath $script:site -Extension '.nope'
        $null -eq $none | Should -BeFalse
        @($none).Count | Should -Be 0
        $empty = Get-IisMimeTypeList -Entries @() -ConfigPath $script:site
        $null -eq $empty | Should -BeFalse
        @($empty).Count | Should -Be 0
    }

    It 'marks nothing inherited at the server level' {
        $list = Get-IisMimeTypeList -Entries $script:entries -ParentEntries @() -Stored $null -ConfigPath 'MACHINE/WEBROOT/APPHOST'
        @($list | Where-Object { $_.inherited }) | Should -BeNullOrEmpty
    }

    Context 'at a level below the server' {
        BeforeAll {
            $script:parent = @(New-MimeEntry ([ordered]@{ '.txt' = 'text/plain'; '.css' = 'TEXT/CSS'; '.log' = 'text/plain'; '.zip' = 'application/zip' }))
        }

        It 'marks <Extension> inherited: <Inherited> (<Why>)' -ForEach @(
            @{ Extension = '.TXT'; Inherited = $true; Why = 'the parent serves the same mapping, its key spelled differently' }
            @{ Extension = '.Css'; Inherited = $false; Why = 'the parent''s MIME type differs in case' }
            @{ Extension = '.zip'; Inherited = $false; Why = 'the parent maps it to another type' }
            @{ Extension = '.apk'; Inherited = $false; Why = 'the parent doesn''t map it' }
            @{ Extension = '.log'; Inherited = $false; Why = 'the level stores its own copy of the parent''s mapping' }
        ) {
            $stored = New-Stored '.LOG'
            $list = Get-IisMimeTypeList -Entries $script:entries -ParentEntries $script:parent -Stored $stored -ConfigPath $script:site -Extension $Extension
            @($list).Count | Should -Be 1
            $list[0].inherited | Should -Be $Inherited
            $list[0].inherited | Should -BeOfType [bool]
        }

        It 'reports a repeat of the parent''s mapping as inherited when what the level stores is unknown' {
            $list = Get-IisMimeTypeList -Entries $script:entries -ParentEntries $script:parent -Stored $null -ConfigPath $script:site -Extension '.log'
            $list[0].inherited | Should -BeTrue
        }
    }
}
