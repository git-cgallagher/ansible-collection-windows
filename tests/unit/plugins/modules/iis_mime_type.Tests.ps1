# Pester 5 unit tests for iis_mime_type's logic: the functions it calls from
# plugins/module_utils/_IisConfig.psm1 that check its options, decide whether
# to add, change or remove a mapping against the map IIS serves at the level,
# pick the file to write, and make the change (committing it only outside
# check mode), and the module's wiring to that util. IIS's configuration API is
# tests/unit/plugins/module_utils/IisFake.ps1's fake. The module's behaviour
# against IIS is its integration target (tests/integration/targets/iis_mime_type).
# Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/iis_mime_type.ps1'
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_IisConfig.psm1') -Force
    . (Join-Path $script:repoRoot 'tests/unit/plugins/module_utils/IisFake.ps1')

    $script:server = 'MACHINE/WEBROOT/APPHOST'
    $script:section = 'system.webServer/staticContent'

    function script:New-Entry {
        param([string]$Extension, [string]$MimeType, [int]$Index = 0)
        [pscustomobject]@{ Index = $Index; Extension = $Extension; MimeType = $MimeType }
    }

    # What a writable manager's collection holds after the change, as extension=type.
    function script:Format-MimeMap {
        param([object]$Collection)
        @(Get-IisMimeMapEntry -Collection $Collection | ForEach-Object { '{0}={1}' -f $_.Extension, $_.MimeType })
    }
}

AfterAll {
    Remove-Module _IisConfig -ErrorAction SilentlyContinue
}

Describe 'iis_mime_type''s wiring' {
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

    It 'calls nothing but the util and PowerShell' {
        $called = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ } | Sort-Object -Unique)
        @($called | Where-Object { $script:util -notcontains $_ -and -not (Get-Command -Name $_ -ErrorAction SilentlyContinue) }) |
            Should -BeNullOrEmpty
    }

    It 'checks, decides and changes through the util' {
        foreach ($name in 'Get-IisFileExtensionProblem', 'ConvertTo-IisFileExtension', 'Test-IisMimeType', 'Resolve-IisConfigLevel',
            'Get-IisMimeMapDecision', 'Get-IisCommitTarget', 'Get-IisWebConfigOverride', 'Invoke-IisMimeMapChange') {
            $script:text | Should -Match "$name "
        }
    }

    It 'leaves committing to the util, which skips it in check mode' {
        $script:text | Should -Not -Match 'CommitChanges'
        $script:text | Should -Match 'CheckMode = \$module\.CheckMode'
    }

    It 'never calls FailJson inside a try block (it exits through an exception)' {
        $tries = $script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TryStatementAst] }, $true)
        $inTry = @(foreach ($try in $tries) {
                $try.Body.FindAll({
                        param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'FailJson'
                    }, $true)
            })
        @($tries).Count | Should -BeGreaterThan 0
        $inTry | Should -BeNullOrEmpty
    }

    It 'declares the documented options with their defaults' {
        $specAst = $script:ast.Find({
                param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$spec'
            }, $false)
        $spec = & ([scriptblock]::Create($specAst.Right.Extent.Text))
        @($spec.options.Keys | Sort-Object) | Should -Be @('application', 'config_file', 'extension', 'mime_type', 'site', 'state')
        $spec.options.extension.required | Should -BeTrue
        $spec.options.state.default | Should -BeExactly 'present'
        @($spec.options.state.choices) | Should -Be @('absent', 'present')
        $spec.options.config_file.default | Should -BeExactly 'applicationHost.config'
        @($spec.options.config_file.choices) | Should -Be @('applicationHost.config', 'web.config')
        $spec.required_if[0] | Should -Be @('state', 'present', 'mime_type')
        $spec.required_by.application | Should -BeExactly 'site'
        $spec.supports_check_mode | Should -BeTrue
    }
}

Describe 'Get-IisFileExtensionProblem' {
    It 'accepts <Extension>' -ForEach @(
        @{ Extension = 'txt' }
        @{ Extension = '.txt' }
        @{ Extension = '.tar.gz' }
        @{ Extension = '.*' }
        @{ Extension = '.C++' }
    ) {
        Get-IisFileExtensionProblem -Extension $Extension | Should -BeNullOrEmpty
    }

    It 'says <Expected> for <Case>' -ForEach @(
        @{ Case = 'an empty extension'; Extension = ''; Expected = 'must not be empty' }
        @{ Case = '$null'; Extension = $null; Expected = 'must not be empty' }
        @{ Case = 'a dot alone'; Extension = '.'; Expected = 'must not be empty' }
        @{ Case = 'a space'; Extension = '.my ext'; Expected = 'must not contain whitespace' }
        @{ Case = 'a tab'; Extension = ".my`text"; Expected = 'must not contain whitespace' }
        @{ Case = 'a double quote'; Extension = '.a"b'; Expected = 'must not contain quotes or path separators (/ or \)' }
        @{ Case = 'a single quote'; Extension = ".a'b"; Expected = 'must not contain quotes or path separators (/ or \)' }
        @{ Case = 'a slash'; Extension = 'dir/.txt'; Expected = 'must not contain quotes or path separators (/ or \)' }
        @{ Case = 'a backslash'; Extension = 'dir\.txt'; Expected = 'must not contain quotes or path separators (/ or \)' }
    ) {
        Get-IisFileExtensionProblem -Extension $Extension | Should -BeExactly $Expected
    }
}

Describe 'Test-IisMimeType' {
    It 'accepts <MimeType>' -ForEach @(
        @{ MimeType = 'text/plain' }
        @{ MimeType = 'application/vnd.ms-excel' }
        @{ MimeType = 'application/x-font+woff2;charset=utf-8' }
    ) {
        Test-IisMimeType -MimeType $MimeType | Should -BeTrue
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'no slash'; MimeType = 'textplain' }
        @{ Case = 'two slashes'; MimeType = 'text/plain/x' }
        @{ Case = 'an empty type'; MimeType = '/plain' }
        @{ Case = 'an empty subtype'; MimeType = 'text/' }
        @{ Case = 'whitespace'; MimeType = 'text/ plain' }
        @{ Case = 'a backslash for the slash'; MimeType = 'text\plain' }
        @{ Case = 'an empty string'; MimeType = '' }
        @{ Case = '$null'; MimeType = $null }
    ) {
        Test-IisMimeType -MimeType $MimeType | Should -BeFalse
    }
}

Describe 'Get-IisMimeMapDecision' {
    It 'adds a mapping IIS doesn''t serve' {
        $d = Get-IisMimeMapDecision -Current $null -State present -Extension '.unit' -MimeType 'text/x-unit'
        $d.Changed | Should -BeTrue
        $d.Before | Should -BeNullOrEmpty
        $d.After.extension | Should -BeExactly '.unit'
        $d.After.mime_type | Should -BeExactly 'text/x-unit'
    }

    It 'leaves a mapping IIS already serves alone' {
        $d = Get-IisMimeMapDecision -Current (New-Entry '.unit' 'text/x-unit') -State present -Extension '.unit' -MimeType 'text/x-unit'
        $d.Changed | Should -BeFalse
        $d.Before.extension | Should -BeExactly '.unit'
        $d.Before.mime_type | Should -BeExactly 'text/x-unit'
        $d.After.mime_type | Should -BeExactly 'text/x-unit'
    }

    It 'changes a mapping to another MIME type' {
        $d = Get-IisMimeMapDecision -Current (New-Entry '.unit' 'text/plain') -State present -Extension '.unit' -MimeType 'text/x-unit'
        $d.Changed | Should -BeTrue
        $d.Before.mime_type | Should -BeExactly 'text/plain'
        $d.After.mime_type | Should -BeExactly 'text/x-unit'
    }

    It 'compares MIME types case-sensitively, so a change of case is a change' {
        $d = Get-IisMimeMapDecision -Current (New-Entry '.unit' 'Text/X-Unit') -State present -Extension '.unit' -MimeType 'text/x-unit'
        $d.Changed | Should -BeTrue
    }

    It 'keeps IIS''s spelling of an existing extension' {
        $d = Get-IisMimeMapDecision -Current (New-Entry '.UNIT' 'text/plain') -State present -Extension '.unit' -MimeType 'text/x-unit'
        $d.After.extension | Should -BeExactly '.UNIT'
        $d.Before.extension | Should -BeExactly '.UNIT'
    }

    It 'removes a mapping IIS serves' {
        $d = Get-IisMimeMapDecision -Current (New-Entry '.unit' 'text/x-unit') -State absent -Extension '.unit' -MimeType $null
        $d.Changed | Should -BeTrue
        $d.Before.mime_type | Should -BeExactly 'text/x-unit'
        $d.After | Should -BeNullOrEmpty
    }

    It 'has nothing to remove when IIS doesn''t serve the extension' {
        $d = Get-IisMimeMapDecision -Current $null -State absent -Extension '.unit' -MimeType $null
        $d.Changed | Should -BeFalse
        $d.Before | Should -BeNullOrEmpty
        $d.After | Should -BeNullOrEmpty
    }
}

Describe 'deciding against the map IIS serves at each level' {
    # The server maps .txt and .json; Default Web Site inherits .txt, maps
    # .json to its own type and adds .site; its application /app1 removes .txt.
    BeforeEach {
        Register-IisFakeCom
        $siteElement = New-IisFakeSite -Name 'Default Web Site' -Applications @(
            @{ path = '/'; Directories = @(@{ path = '/'; physicalPath = 'C:\inetpub\wwwroot' }) }
            @{ path = '/app1'; Directories = @(@{ path = '/'; physicalPath = 'C:\inetpub\app1' }) }
        )
        $serverMap = New-IisFakeMimeMap ([ordered]@{ '.txt' = 'text/plain'; '.json' = 'application/json' })
        $siteMap = New-IisFakeMimeMap ([ordered]@{ '.txt' = 'text/plain'; '.json' = 'application/x-site'; '.site' = 'text/x-site' })
        $appMap = New-IisFakeMimeMap ([ordered]@{ '.json' = 'application/x-site'; '.site' = 'text/x-site' })
        $script:manager = New-IisFakeManager -Sections @{
            "system.applicationHost/sites|$script:server" = (New-IisFakeCollection -Elements @($siteElement))
            "$script:section|$script:server" = (New-IisFakeCollection -Elements @($serverMap))
            "$script:section|$script:server/Default Web Site" = (New-IisFakeCollection -Elements @($siteMap))
            "$script:section|$script:server/Default Web Site/app1" = (New-IisFakeCollection -Elements @($appMap))
        }

        function script:Get-LevelDecision {
            param($Site, $Application, $Extension, $State, $MimeType)
            $level = Resolve-IisConfigLevel -AdminManager $script:manager -Site $Site -Application $Application
            $effective = Get-IisSectionCollection -AdminManager $script:manager -Section $script:section -ConfigPath $level.ConfigPath
            $current = Get-IisMimeMapEntry -Collection $effective -Extension (ConvertTo-IisFileExtension -Extension $Extension) | Select-Object -First 1
            Get-IisMimeMapDecision -Current $current -State $State -Extension (ConvertTo-IisFileExtension -Extension $Extension) -MimeType $MimeType
        }
    }

    It '<Case>' -ForEach @(
        @{
            Case = 'the server''s own mapping is no change'; Site = $null; App = $null; Ext = 'json'
            State = 'present'; Mime = 'application/json'; Changed = $false; Before = 'application/json'
        }
        @{
            Case = 'the site''s inherited mapping is no change, not a copy'; Site = 'Default Web Site'; App = $null; Ext = 'TXT'
            State = 'present'; Mime = 'text/plain'; Changed = $false; Before = 'text/plain'
        }
        @{
            Case = 'the site''s override is what it compares with'; Site = 'Default Web Site'; App = $null; Ext = '.json'
            State = 'present'; Mime = 'application/json'; Changed = $true; Before = 'application/x-site'
        }
        @{
            Case = 'hiding an inherited mapping at the site is a change'; Site = 'Default Web Site'; App = $null; Ext = '.txt'
            State = 'absent'; Mime = $null; Changed = $true; Before = 'text/plain'
        }
        @{
            Case = 'a mapping the application removed is a new one there'; Site = 'Default Web Site'; App = '/app1'; Ext = '.txt'
            State = 'present'; Mime = 'text/plain'; Changed = $true; Before = $null
        }
        @{
            Case = 'removing what the application already removed is no change'; Site = 'Default Web Site'; App = '/app1'; Ext = '.txt'
            State = 'absent'; Mime = $null; Changed = $false; Before = $null
        }
    ) {
        $d = Get-LevelDecision -Site $Site -Application $App -Extension $Ext -State $State -MimeType $Mime
        $d.Changed | Should -Be $Changed
        if ($null -eq $Before) {
            $d.Before | Should -BeNullOrEmpty
        }
        else {
            $d.Before.mime_type | Should -BeExactly $Before
        }
    }
}

Describe 'Get-IisCommitTarget' {
    BeforeAll {
        $script:level = [pscustomobject]@{ ConfigPath = "$script:server/Default Web Site/app1" }
    }

    It 'writes to applicationHost.config by default, at any level' {
        $t = Get-IisCommitTarget -Level $script:level
        $t.CommitPath | Should -BeExactly $script:server
        $t.File | Should -BeExactly 'applicationHost.config'
    }

    It 'writes to the level''s web.config with config_file=web.config' {
        $t = Get-IisCommitTarget -Level $script:level -WebConfig
        $t.CommitPath | Should -BeExactly "$script:server/Default Web Site/app1"
        $t.File | Should -BeExactly "the web.config of $script:server/Default Web Site/app1"
    }
}

Describe 'Get-IisWebConfigOverride' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive "site-$([guid]::NewGuid())"
        $null = New-Item -ItemType Directory -Path $script:dir
        $script:webConfig = [System.IO.Path]::Combine($script:dir, 'web.config')
    }

    It 'finds nothing without a content directory or a web.config' {
        Get-IisWebConfigOverride -PhysicalPath $null -Extension '.unit' | Should -BeNullOrEmpty
        Get-IisWebConfigOverride -PhysicalPath $script:dir -Extension '.unit' | Should -BeNullOrEmpty
    }

    It 'reports a clear element' {
        $xml = '<configuration><system.webServer><staticContent><clear /></staticContent></system.webServer></configuration>'
        Set-Content -LiteralPath $script:webConfig -Value $xml
        Get-IisWebConfigOverride -PhysicalPath $script:dir -Extension '.unit' |
            Should -BeExactly "$script:webConfig clears the inherited MIME map (<clear />)"
    }

    It 'reports the file''s own <Element> element for the extension, compared case-insensitively' -ForEach @(
        @{ Element = 'mimeMap'; Xml = '<mimeMap fileExtension=".UNIT" mimeType="text/plain" />' }
        @{ Element = 'remove'; Xml = '<remove fileExtension=".Unit" />' }
    ) {
        $content = "<configuration><system.webServer><staticContent>$Xml</staticContent></system.webServer></configuration>"
        Set-Content -LiteralPath $script:webConfig -Value $content
        Get-IisWebConfigOverride -PhysicalPath $script:dir -Extension '.unit' |
            Should -BeExactly "$script:webConfig has its own <$Element> element for .unit"
    }

    It 'ignores other extensions, and a web.config in an XML namespace is read too' {
        $xml = '<configuration xmlns="http://schemas.microsoft.com/.NetConfiguration/v2.0"><system.webServer><staticContent>' +
        '<mimeMap fileExtension=".other" mimeType="text/plain" /></staticContent></system.webServer></configuration>'
        Set-Content -LiteralPath $script:webConfig -Value $xml
        Get-IisWebConfigOverride -PhysicalPath $script:dir -Extension '.unit' | Should -BeNullOrEmpty
        Get-IisWebConfigOverride -PhysicalPath $script:dir -Extension '.other' | Should -Match 'has its own <mimeMap> element for \.other$'
    }
}

Describe 'Invoke-IisMimeMapChange' {
    BeforeEach {
        Register-IisFakeCom
        $script:writer = New-IisFakeManager
        $script:base = @{
            Writer = $script:writer
            Extension = '.unit'
            ConfigPath = "$script:server/Default Web Site"
            File = 'applicationHost.config'
        }
    }

    It 'adds a new mapping and commits once' {
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap @{ '.txt' = 'text/plain' })
        $mapping = @{ extension = '.unit'; mime_type = 'text/x-unit' }
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $mapping -CurrentMimeType $null
        $refusal | Should -BeNullOrEmpty
        $collection.Deleted.Count | Should -Be 0
        $collection.Added.Count | Should -Be 1
        $collection.Added[0].Element.ElementName | Should -BeExactly 'mimeMap'
        $collection.Added[0].Position | Should -Be -1
        Format-MimeMap $collection | Should -Be @('.txt=text/plain', '.unit=text/x-unit')
        $script:writer.Commits | Should -Be 1
    }

    It 'changes a mapping by deleting it and adding it again, in IIS''s spelling' {
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap ([ordered]@{ '.txt' = 'text/plain'; '.UNIT' = 'text/plain' }))
        $mapping = @{ extension = '.UNIT'; mime_type = 'text/x-unit' }
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $mapping -CurrentMimeType 'text/plain'
        $refusal | Should -BeNullOrEmpty
        @($collection.Deleted) | Should -Be @(1)
        Format-MimeMap $collection | Should -Be @('.txt=text/plain', '.UNIT=text/x-unit')
        $script:writer.Commits | Should -Be 1
    }

    It 'removes a mapping without adding one' {
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap @{ '.unit' = 'text/x-unit' })
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $null -CurrentMimeType 'text/x-unit'
        $refusal | Should -BeNullOrEmpty
        @($collection.Deleted) | Should -Be @(0)
        $collection.Added.Count | Should -Be 0
        Format-MimeMap $collection | Should -BeNullOrEmpty
        $script:writer.Commits | Should -Be 1
    }

    It 'hides an inherited mapping that shows through a deleted local one by deleting that too' {
        # IIS writes <remove> for the deletion of an inherited entry.
        $local = New-IisFakeMimeMap @{ '.unit' = 'text/x-local' }
        $collection = New-IisFakeCollection -Elements @($local) -Shadowed @(New-IisFakeMimeMap @{ '.unit' = 'text/x-server' })
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $null -CurrentMimeType 'text/x-local'
        $refusal | Should -BeNullOrEmpty
        @($collection.Deleted) | Should -Be @(0, 0)
        Format-MimeMap $collection | Should -BeNullOrEmpty
        $script:writer.Commits | Should -Be 1
    }

    It 'refuses, and writes nothing, when the extension is still there after two deletions' {
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap @{ '.unit' = 'text/x-unit' }) -Sticky
        $mapping = @{ extension = '.unit'; mime_type = 'text/plain' }
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $mapping -CurrentMimeType 'text/x-unit'
        $refusal | Should -BeExactly ("Couldn't delete .unit from applicationHost.config at $script:server/Default Web Site: " +
            'it is still there after two deletions.')
        $collection.Deleted.Count | Should -Be 2
        $collection.Added.Count | Should -Be 0
        $script:writer.Commits | Should -Be 0
    }

    It 'refuses, and touches nothing, when the file being written sees <Stored> but IIS serves <Served>' -ForEach @(
        @{ Stored = 'text/x-apphost'; Served = 'text/x-webconfig' }
        @{ Stored = 'text/x-unit'; Served = 'Text/X-Unit' }
        @{ Stored = $null; Served = 'text/x-webconfig' }
        @{ Stored = 'text/x-apphost'; Served = $null }
    ) {
        $map = @{}
        if ($null -ne $Stored) {
            $map['.unit'] = $Stored
        }
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap $map)
        $mapping = @{ extension = '.unit'; mime_type = 'text/plain' }
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $mapping -CurrentMimeType $Served
        $refusal | Should -BeExactly ("Can't change .unit at $script:server/Default Web Site through applicationHost.config: IIS serves '$Served', " +
            "but that file sees '$Stored'.")
        $collection.Deleted.Count | Should -Be 0
        $collection.Added.Count | Should -Be 0
        $script:writer.Commits | Should -Be 0
    }

    It 'in check mode makes the same change in memory and commits nothing' {
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap @{ '.unit' = 'text/plain' })
        $mapping = @{ extension = '.unit'; mime_type = 'text/x-unit' }
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $mapping -CurrentMimeType 'text/plain' -CheckMode
        $refusal | Should -BeNullOrEmpty
        @($collection.Deleted) | Should -Be @(0)
        $collection.Added.Count | Should -Be 1
        $script:writer.Commits | Should -Be 0
    }

    It 'in check mode still refuses what it can''t do' {
        $collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap @{ '.unit' = 'text/x-apphost' })
        $refusal = Invoke-IisMimeMapChange @script:base -Collection $collection -Mapping $null -CurrentMimeType 'text/x-webconfig' -CheckMode
        $refusal | Should -Match '^Can''t change \.unit'
        $script:writer.Commits | Should -Be 0
    }
}
