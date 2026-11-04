# Pester 5 unit tests for plugins/module_utils/_IisConfig.psm1's reading side:
# the calls into IIS's configuration API, resolving the site and application
# options to a configuration level, reading a level's MIME map and the
# extensions a level stores itself. The API is IisFake.ps1's fake, behind a
# mock of the util's one call into it; the XML files are written to $TestDrive.
# What iis_mime_type and iis_mime_type_info decide is in their own files.
# Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_IisConfig.psm1') -Force
    . (Join-Path $PSScriptRoot 'IisFake.ps1')

    $script:server = 'MACHINE/WEBROOT/APPHOST'
    $script:sitesKey = "system.applicationHost/sites|$script:server"

    # A server with two sites: Default Web Site has the root, a virtual
    # directory /vd under it, and applications /app1 (with a virtual directory
    # /docs) and /shop/cart; Empty Site has no root virtual directory.
    function script:New-SiteManager {
        $default = New-IisFakeSite -Name 'Default Web Site' -Applications @(
            @{
                path = '/'
                Directories = @(
                    @{ path = '/'; physicalPath = '%IIS_UNIT_ROOT%\wwwroot' }
                    @{ path = '/vd'; physicalPath = 'C:\content\vd' }
                )
            }
            @{
                path = '/app1'
                Directories = @(
                    @{ path = '/'; physicalPath = 'C:\content\app1' }
                    @{ path = '/docs'; physicalPath = 'C:\content\docs' }
                )
            }
            @{ path = '/shop/cart/'; Directories = @(@{ path = '/'; physicalPath = 'C:\content\cart' }) }
        )
        $empty = New-IisFakeSite -Name 'Empty Site' -Applications @(@{ path = '/other'; Directories = @(@{ path = '/'; physicalPath = 'C:\other' }) })
        New-IisFakeManager -Sections @{ $script:sitesKey = (New-IisFakeCollection -Elements @($default, $empty)) }
    }

    function script:Set-Xml {
        param([string]$Path, [string]$Content)
        $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($Path)) -Force
        Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
    }
}

AfterAll {
    Remove-Module _IisConfig -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-IisComArgument' {
    It 'unwraps PowerShell''s wrapper from each argument and keeps $null' {
        $values = InModuleScope _IisConfig {
            ConvertTo-IisComArgument -ArgumentList @((New-Object -TypeName psobject -ArgumentList 'x'), $null, 3)
        }
        , $values | Should -BeOfType [object[]]
        $values.Count | Should -Be 3
        $values[0].GetType().FullName | Should -Be 'System.String'
        $values[1] | Should -BeNullOrEmpty
        $values[2] | Should -Be 3
    }

    It 'turns no arguments into an empty array, not $null' {
        $values = InModuleScope _IisConfig { ConvertTo-IisComArgument -ArgumentList $null }
        , $values | Should -BeOfType [object[]]
        $values.Count | Should -Be 0
    }
}

Describe 'Invoke-IisComMember and the element helpers' {
    BeforeEach {
        Register-IisFakeCom
    }

    It 'calls methods and reads properties as one IDispatch call' {
        $element = New-IisFakeElement -Values @{ mimeType = 'text/plain' }
        Invoke-IisComMember -Object $element -Name 'Properties' | Should -Be $element.Properties
        Should -Invoke -ModuleName _IisConfig Invoke-IisComInvokeMember -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Properties' -and $Flags -eq [System.Reflection.BindingFlags]'InvokeMethod, GetProperty'
        }
    }

    It 'reads an attribute through Properties.Item(name).Value' {
        $element = New-IisFakeElement -Values @{ fileExtension = '.txt' }
        InModuleScope _IisConfig -Parameters @{ Element = $element } {
            param ($Element)
            Get-IisElementValue -Element $Element -Name 'fileExtension'
        } | Should -BeExactly '.txt'
    }

    It 'sets an attribute with a SetProperty call on its Value' {
        $element = New-IisFakeElement
        Set-IisElementValue -Element $element -Name 'mimeType' -Value 'text/x-unit'
        $element.Properties.Map['mimeType'].Value | Should -BeExactly 'text/x-unit'
        Should -Invoke -ModuleName _IisConfig Invoke-IisComInvokeMember -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Value' -and $Flags -eq [System.Reflection.BindingFlags]::SetProperty -and $ArgumentList[0] -eq 'text/x-unit'
        }
    }
}

Describe 'New-IisAdminManager' {
    BeforeAll {
        # New-Object has -ComObject only on Windows, and a mock takes the
        # parameters of the command it replaces: shadow it inside the util with
        # a function that has them, for this block only.
        InModuleScope _IisConfig {
            function script:New-Object {
                [CmdletBinding()]
                param ([string]$TypeName, [string]$ComObject, [object[]]$ArgumentList)
                throw "New-Object is mocked in these tests ($TypeName$ComObject$ArgumentList)"
            }
        }
    }

    AfterAll {
        InModuleScope _IisConfig { Remove-Item -LiteralPath 'Function:\New-Object' }
    }

    BeforeEach {
        Register-IisFakeCom
    }

    It 'opens the read-only manager without a commit path' {
        Mock -ModuleName _IisConfig New-Object { [pscustomobject]@{ CommitPath = $null } }
        $manager = New-IisAdminManager
        $manager.CommitPath | Should -BeNullOrEmpty
        Should -Invoke -ModuleName _IisConfig New-Object -Times 1 -Exactly -ParameterFilter { $ComObject -eq 'Microsoft.ApplicationHost.AdminManager' }
    }

    It 'opens the writable manager and sets its commit path' {
        Mock -ModuleName _IisConfig New-Object { [pscustomobject]@{ CommitPath = $null } }
        $manager = New-IisAdminManager -CommitPath 'MACHINE/WEBROOT/APPHOST/Default Web Site'
        $manager.CommitPath | Should -BeExactly 'MACHINE/WEBROOT/APPHOST/Default Web Site'
        Should -Invoke -ModuleName _IisConfig New-Object -Times 1 -Exactly -ParameterFilter { $ComObject -eq 'Microsoft.ApplicationHost.WritableAdminManager' }
    }

    It 'says to install IIS when the API can''t be created' {
        Mock -ModuleName _IisConfig New-Object { throw 'Retrieving the COM class factory failed' }
        { New-IisAdminManager } | Should -Throw -ExpectedMessage (
            "IIS isn't installed on this host, or its configuration system can't be reached (Microsoft.ApplicationHost.AdminManager): " +
            'Retrieving the COM class factory failed Install the Web-Server feature (IIS)*')
    }
}

Describe 'Get-IisSectionCollection' {
    BeforeEach {
        Register-IisFakeCom
    }

    It 'returns the section''s collection at the path' {
        $collection = New-IisFakeCollection
        $manager = New-IisFakeManager -Sections @{ "system.webServer/staticContent|$script:server" = $collection }
        $got = Get-IisSectionCollection -AdminManager $manager -Section 'system.webServer/staticContent' -ConfigPath $script:server
        [object]::ReferenceEquals($got, $collection) | Should -BeTrue
    }

    It 'names the section and path when IIS can''t read it' {
        $manager = New-IisFakeManager
        { Get-IisSectionCollection -AdminManager $manager -Section 'system.webServer/staticContent' -ConfigPath "$script:server/Nope" } |
            Should -Throw -ExpectedMessage "Couldn't read system.webServer/staticContent at $script:server/Nope: *Cannot read configuration file*"
    }
}

Describe 'Get-IisMimeMapEntry' {
    BeforeEach {
        Register-IisFakeCom
        $script:collection = New-IisFakeCollection -Elements @(New-IisFakeMimeMap ([ordered]@{ '.txt' = 'text/plain'; '.JSON' = 'application/json'; '.css' = 'text/css' }))
    }

    It 'returns every element with its index, extension and MIME type' {
        $entries = @(Get-IisMimeMapEntry -Collection $script:collection)
        $entries.Count | Should -Be 3
        $entries[1].Index | Should -Be 1
        $entries[1].Extension | Should -BeExactly '.JSON'
        $entries[1].MimeType | Should -BeExactly 'application/json'
    }

    It 'finds one extension case-insensitively, as IIS compares them, and returns IIS''s spelling' {
        $entries = @(Get-IisMimeMapEntry -Collection $script:collection -Extension '.json')
        $entries.Count | Should -Be 1
        $entries[0].Index | Should -Be 1
        $entries[0].Extension | Should -BeExactly '.JSON'
    }

    It 'returns nothing for an extension IIS doesn''t map' {
        @(Get-IisMimeMapEntry -Collection $script:collection -Extension '.nope').Count | Should -Be 0
    }
}

Describe 'Resolve-IisConfigLevel' {
    BeforeAll {
        $env:IIS_UNIT_ROOT = 'D:\iisroot'
    }

    AfterAll {
        Remove-Item -LiteralPath Env:IIS_UNIT_ROOT -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Register-IisFakeCom
        $script:manager = New-SiteManager
    }

    It 'is the server level without a site, and reads nothing' {
        $level = Resolve-IisConfigLevel -AdminManager $script:manager -Site $null -Application $null
        $level.ConfigPath | Should -BeExactly $script:server
        $level.ParentPath | Should -BeNullOrEmpty
        $level.Site | Should -BeNullOrEmpty
        $level.PhysicalPath | Should -BeNullOrEmpty
        Should -Invoke -ModuleName _IisConfig Invoke-IisComInvokeMember -Times 0 -Exactly
    }

    It 'resolves a site, case-insensitively, to IIS''s spelling and its root''s content directory' {
        $level = Resolve-IisConfigLevel -AdminManager $script:manager -Site 'default web site' -Application $null
        $level.ConfigPath | Should -BeExactly "$script:server/Default Web Site"
        $level.ParentPath | Should -BeExactly $script:server
        $level.Site | Should -BeExactly 'Default Web Site'
        $level.PhysicalPath | Should -BeExactly 'D:\iisroot\wwwroot'
    }

    It 'resolves application <Application> to <Expected>' -ForEach @(
        @{ Application = '/app1'; Expected = '/app1'; Physical = 'C:\content\app1'; Parent = '' }
        @{ Application = 'app1'; Expected = '/app1'; Physical = 'C:\content\app1'; Parent = '' }
        @{ Application = '/app1/'; Expected = '/app1'; Physical = 'C:\content\app1'; Parent = '' }
        @{ Application = '/vd'; Expected = '/vd'; Physical = 'C:\content\vd'; Parent = '' }
        @{ Application = '/app1/docs'; Expected = '/app1/docs'; Physical = 'C:\content\docs'; Parent = '/app1' }
        @{ Application = '/shop/cart'; Expected = '/shop/cart'; Physical = 'C:\content\cart'; Parent = '/shop' }
    ) {
        $level = Resolve-IisConfigLevel -AdminManager $script:manager -Site 'Default Web Site' -Application $Application
        $level.ConfigPath | Should -BeExactly "$script:server/Default Web Site$Expected"
        $level.ParentPath | Should -BeExactly "$script:server/Default Web Site$Parent"
        $level.Site | Should -BeExactly 'Default Web Site'
        $level.PhysicalPath | Should -BeExactly $Physical
    }

    It 'resolves a site without a root virtual directory to the site level, with no content directory' {
        $level = Resolve-IisConfigLevel -AdminManager $script:manager -Site 'Empty Site' -Application $null
        $level.ConfigPath | Should -BeExactly "$script:server/Empty Site"
        $level.PhysicalPath | Should -BeNullOrEmpty
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'an empty site'; Site = ''; Application = $null; Message = 'site must not be empty; omit it for the server level.' }
        @{ Case = 'a site IIS doesn''t have'; Site = 'Nope'; Application = $null; Message = "IIS has no website named 'Nope'." }
        @{ Case = 'a site name as a wildcard'; Site = 'Default*'; Application = $null; Message = "IIS has no website named 'Default*'." }
        @{
            Case = 'a backslash in the application'; Site = 'Default Web Site'; Application = '\app1'
            Message = "application must be a virtual path with forward slashes, such as /app1; got '\app1'."
        }
        @{
            Case = 'the site''s root as the application'; Site = 'Default Web Site'; Application = '/'
            Message = 'application must name an application or virtual directory under the site; omit it for the site level.'
        }
        @{
            Case = 'an application the site doesn''t have'; Site = 'Default Web Site'; Application = '/nope'
            Message = "Website 'Default Web Site' has no application or virtual directory at '/nope'."
        }
    ) {
        { Resolve-IisConfigLevel -AdminManager $script:manager -Site $Site -Application $Application } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'ConvertTo-IisFileExtension' {
    It 'spells <Extension> as <Expected>' -ForEach @(
        @{ Extension = 'txt'; Expected = '.txt' }
        @{ Extension = '.txt'; Expected = '.txt' }
        @{ Extension = 'TXT'; Expected = '.TXT' }
        @{ Extension = 'tar.gz'; Expected = '.tar.gz' }
        @{ Extension = '*'; Expected = '.*' }
    ) {
        ConvertTo-IisFileExtension -Extension $Extension | Should -BeExactly $Expected
    }
}

Describe 'Get-IisStoredMimeMapExtension' {
    BeforeEach {
        $script:configDir = Join-Path $TestDrive "config-$([guid]::NewGuid())"
        $script:siteDir = Join-Path $TestDrive "site-$([guid]::NewGuid())"
        Set-Xml (Join-Path $script:configDir 'applicationHost.config') @'
<configuration>
  <system.webServer><staticContent><mimeMap fileExtension=".server" mimeType="text/x-server" /></staticContent></system.webServer>
  <location path="Default Web Site">
    <system.webServer><staticContent><mimeMap fileExtension=".site" mimeType="text/x-site" /></staticContent></system.webServer>
  </location>
  <location path="default web site/App1/">
    <system.webServer><staticContent>
      <remove fileExtension=".gone" />
      <mimeMap fileExtension=".App" mimeType="text/x-app" />
    </staticContent></system.webServer>
  </location>
</configuration>
'@
    }

    It 'reads the level''s location elements in applicationHost.config, matching their path case-insensitively, and nothing else' {
        $stored = Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site/app1" -PhysicalPath $null -ConfigDirectory $script:configDir
        $stored.GetType().Name | Should -Be 'HashSet`1'
        @($stored) | Should -Be @('.App')
        $stored.Contains('.app') | Should -BeTrue
    }

    It 'reads a site''s own location element but not its applications''' {
        $stored = Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site" -PhysicalPath $null -ConfigDirectory $script:configDir
        @($stored) | Should -Be @('.site')
    }

    It 'reads the level''s web.config and its location elements for path . and the empty path, in a namespace too' {
        Set-Xml (Join-Path $script:siteDir 'web.config') @'
<configuration xmlns="http://schemas.microsoft.com/.NetConfiguration/v2.0">
  <system.webServer><staticContent><mimeMap fileExtension=".web" mimeType="text/x-web" /></staticContent></system.webServer>
  <location path=".">
    <system.webServer><staticContent><mimeMap fileExtension=".dot" mimeType="text/x-dot" /></staticContent></system.webServer>
  </location>
  <location path="">
    <system.webServer><staticContent><mimeMap fileExtension=".blank" mimeType="text/x-blank" /></staticContent></system.webServer>
  </location>
  <location path="sub">
    <system.webServer><staticContent><mimeMap fileExtension=".sub" mimeType="text/x-sub" /></staticContent></system.webServer>
  </location>
</configuration>
'@
        $stored = Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site" -PhysicalPath $script:siteDir -ConfigDirectory $script:configDir
        @($stored | Sort-Object) | Should -Be @('.blank', '.dot', '.site', '.web')
    }

    It 'skips a content directory without a web.config' {
        $stored = Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site" -PhysicalPath $script:siteDir -ConfigDirectory $script:configDir
        @($stored) | Should -Be @('.site')
    }

    It 'reads applicationHost.config from where an enabled redirection.config points' {
        $shared = Join-Path $TestDrive "shared-$([guid]::NewGuid())"
        Set-Xml (Join-Path $shared 'applicationHost.config') @'
<configuration>
  <location path="Default Web Site"><system.webServer><staticContent><mimeMap fileExtension=".shared" mimeType="text/x-shared" /></staticContent></system.webServer></location>
</configuration>
'@
        $env:IIS_UNIT_SHARED = $shared
        try {
            Set-Xml (Join-Path $script:configDir 'redirection.config') @'
<configuration><configurationRedirection enabled="true" path="%IIS_UNIT_SHARED%" /></configuration>
'@
            $stored = Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site" -PhysicalPath $null -ConfigDirectory $script:configDir
            @($stored) | Should -Be @('.shared')
        }
        finally {
            Remove-Item -LiteralPath Env:IIS_UNIT_SHARED -ErrorAction SilentlyContinue
        }
    }

    It 'ignores a redirection.config that is turned off' {
        Set-Xml (Join-Path $script:configDir 'redirection.config') @'
<configuration><configurationRedirection enabled="false" path="C:\nowhere" /></configuration>
'@
        $stored = Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site" -PhysicalPath $null -ConfigDirectory $script:configDir
        @($stored) | Should -Be @('.site')
    }

    It 'throws when applicationHost.config can''t be read' {
        { Get-IisStoredMimeMapExtension -ConfigPath "$script:server/Default Web Site" -PhysicalPath $null -ConfigDirectory (Join-Path $TestDrive 'missing') } |
            Should -Throw
    }
}
