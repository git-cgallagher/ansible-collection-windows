# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the iis_* modules: IIS's configuration system through its native
# COM API (Microsoft.ApplicationHost.AdminManager, the API appcmd.exe uses),
# resolving the site and application options to a configuration path, and
# reading a level's MIME map. Private to this collection, with no compatibility
# promise. Windows PowerShell 5.1 syntax only.
#
# Every call into the API goes through Invoke-IisComMember or
# Set-IisComProperty, never PowerShell's own COM binding: in a module's
# runspace that throws a NullReferenceException on these objects before IIS
# sees the call.

$script:IisServerPath = 'MACHINE/WEBROOT/APPHOST'

Function ConvertTo-IisComArgument {
    <#
    .SYNOPSIS
    Returns the arguments for Type.InvokeMember as an object[] of base objects.

    .DESCRIPTION
    PowerShell wraps objects in a PSObject; passed as is, the API would get
    PowerShell's wrapper instead of its own element.
    #>
    [CmdletBinding()]
    param (
        [AllowNull()]
        [object[]]
        $ArgumentList
    )

    if ($null -eq $ArgumentList) {
        $ArgumentList = @()
    }
    $values = New-Object -TypeName 'object[]' -ArgumentList $ArgumentList.Count
    for ($i = 0; $i -lt $ArgumentList.Count; $i++) {
        $value = $ArgumentList[$i]
        if ($null -ne $value) {
            $value = $value.psobject.BaseObject
        }
        $values[$i] = $value
    }

    # The comma keeps PowerShell from unrolling the array on output.
    , $values
}

Function Invoke-IisComInvokeMember {
    <#
    .SYNOPSIS
    Type.InvokeMember on an IIS configuration API object, rethrowing the API's own error.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [Parameter(Mandatory = $true)]
        [System.Reflection.BindingFlags]
        $Flags,

        [AllowNull()]
        [object[]]
        $ArgumentList
    )

    $values = ConvertTo-IisComArgument -ArgumentList $ArgumentList
    try {
        $result = [System.__ComObject].InvokeMember($Name, $Flags, $null, $Object.psobject.BaseObject, $values)
    }
    catch {
        # PowerShell's MethodInvocationException wraps a TargetInvocationException
        # that wraps the COMException carrying IIS's message.
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) {
            $exception = $exception.InnerException
        }
        throw $exception
    }

    # The comma keeps PowerShell from enumerating a COM collection on output.
    , $result
}

Function Invoke-IisComMember {
    <#
    .SYNOPSIS
    Calls a method, or reads a property, of an IIS configuration API object.

    .DESCRIPTION
    Through IDispatch with DISPATCH_METHOD | DISPATCH_PROPERTYGET, as VBScript
    calls these objects, so Item(index) works whichever of the two IIS declares.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [AllowNull()]
        [object[]]
        $ArgumentList
    )

    $flags = [System.Reflection.BindingFlags]'InvokeMethod, GetProperty'
    $result = Invoke-IisComInvokeMember -Object $Object -Name $Name -Flags $flags -ArgumentList $ArgumentList

    # The comma keeps PowerShell from enumerating a COM collection on output.
    , $result
}

Function Set-IisComProperty {
    <#
    .SYNOPSIS
    Sets a property of an IIS configuration API object.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $Object,

        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [AllowNull()]
        [object]
        $Value
    )

    $flags = [System.Reflection.BindingFlags]::SetProperty
    $null = Invoke-IisComInvokeMember -Object $Object -Name $Name -Flags $flags -ArgumentList @(, $Value)
}

Function Get-IisElementValue {
    <#
    .SYNOPSIS
    Returns the value of a configuration element's attribute, such as a mimeMap element's fileExtension.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $Element,

        [Parameter(Mandatory = $true)]
        [string]
        $Name
    )

    $properties = Invoke-IisComMember -Object $Element -Name 'Properties'
    $property = Invoke-IisComMember -Object $properties -Name 'Item' -ArgumentList $Name
    Invoke-IisComMember -Object $property -Name 'Value'
}

Function Set-IisElementValue {
    <#
    .SYNOPSIS
    Sets the value of a configuration element's attribute.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $Element,

        [Parameter(Mandatory = $true)]
        [string]
        $Name,

        [AllowNull()]
        [object]
        $Value
    )

    $properties = Invoke-IisComMember -Object $Element -Name 'Properties'
    $property = Invoke-IisComMember -Object $properties -Name 'Item' -ArgumentList $Name
    Set-IisComProperty -Object $property -Name 'Value' -Value $Value
}

Function New-IisAdminManager {
    <#
    .SYNOPSIS
    Returns IIS's configuration API: read-only, or writable when a commit path is given.

    .PARAMETER CommitPath
    Where a writable manager commits: MACHINE/WEBROOT/APPHOST for applicationHost.config
    (a <location> element when the section path is deeper), or a site or application path
    for that level's web.config.
    #>
    [CmdletBinding()]
    param (
        [string]
        $CommitPath
    )

    $progId = 'Microsoft.ApplicationHost.AdminManager'
    if ($CommitPath) {
        $progId = 'Microsoft.ApplicationHost.WritableAdminManager'
    }

    try {
        $manager = New-Object -ComObject $progId -ErrorAction Stop
    }
    catch {
        $msg = "IIS isn't installed on this host, or its configuration system can't be reached ($progId): $($_.Exception.Message)"
        throw "$msg Install the Web-Server feature (IIS), for example with ansible.windows.win_feature."
    }

    if ($CommitPath) {
        Set-IisComProperty -Object $manager -Name 'CommitPath' -Value $CommitPath
    }
    $manager
}

Function Get-IisSectionCollection {
    <#
    .SYNOPSIS
    Returns the element collection of a configuration section, as IIS merges it at a configuration path.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $AdminManager,

        [Parameter(Mandatory = $true)]
        [string]
        $Section,

        [Parameter(Mandatory = $true)]
        [string]
        $ConfigPath
    )

    try {
        $sectionElement = Invoke-IisComMember -Object $AdminManager -Name 'GetAdminSection' -ArgumentList $Section, $ConfigPath
        $collection = Invoke-IisComMember -Object $sectionElement -Name 'Collection'
    }
    catch {
        throw "Couldn't read $Section at ${ConfigPath}: $($_.Exception.Message)"
    }

    # The comma keeps PowerShell from enumerating a COM collection on output.
    , $collection
}

Function Get-IisMimeMapEntry {
    <#
    .SYNOPSIS
    Writes the mimeMap elements of a system.webServer/staticContent collection to the pipeline.

    .DESCRIPTION
    Index is the element's position in the collection, valid until the collection
    changes. Where an element is defined isn't returned: IIS answers
    ERROR_NOT_SUPPORTED when asked for a collection element's deepestPathSet
    metadata (see Get-IisStoredMimeMapExtension).

    .PARAMETER Extension
    Only the element for this file extension (compared case-insensitively, as IIS does).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $Collection,

        [string]
        $Extension
    )

    $count = Invoke-IisComMember -Object $Collection -Name 'Count'
    for ($i = 0; $i -lt $count; $i++) {
        $element = Invoke-IisComMember -Object $Collection -Name 'Item' -ArgumentList $i
        $fileExtension = [string](Get-IisElementValue -Element $element -Name 'fileExtension')
        if ($Extension -and $fileExtension -ne $Extension) {
            continue
        }

        [PSCustomObject]@{
            Index = $i
            Extension = $fileExtension
            MimeType = [string](Get-IisElementValue -Element $element -Name 'mimeType')
        }
    }
}

Function Get-IisStoredMimeMapExtension {
    <#
    .SYNOPSIS
    Returns the file extensions a site or application level's own configuration maps, as a case-insensitive set.

    .DESCRIPTION
    Reads the mimeMap elements stored for the level itself: in its <location>
    elements of applicationHost.config (in the directory redirection.config
    names when shared configuration is on), and in the web.config in
    PhysicalPath, including that file's <location path="."> elements. IIS's
    native API doesn't say where a collection element is defined, and the
    effective map can't tell a level that repeats its parent's mapping from one
    that inherits it. A <location> element in a parent level's web.config that
    targets this level isn't read.

    .PARAMETER ConfigPath
    The level's configuration path, such as MACHINE/WEBROOT/APPHOST/Default Web Site/app1.

    .PARAMETER PhysicalPath
    The level's content directory, where its web.config lives; $null to skip it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]
        $ConfigPath,

        [AllowNull()]
        [string]
        $PhysicalPath
    )

    $extensions = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    # local-name() throughout: web.config files generated by older tools put
    # the <configuration> element in an XML namespace.
    $mimeMapXPath = "*[local-name()='system.webServer']/*[local-name()='staticContent']/*[local-name()='mimeMap']"

    $configDir = [System.IO.Path]::Combine($env:SystemRoot, 'System32', 'inetsrv', 'config')
    $appHostDir = $configDir
    $redirectionPath = [System.IO.Path]::Combine($configDir, 'redirection.config')
    if (Test-Path -LiteralPath $redirectionPath -PathType Leaf) {
        $redirection = New-Object -TypeName System.Xml.XmlDocument
        $redirection.Load($redirectionPath)
        $redirect = $redirection.SelectSingleNode("/*[local-name()='configuration']/*[local-name()='configurationRedirection']")
        if ($redirect -and $redirect.GetAttribute('enabled') -eq 'true' -and $redirect.GetAttribute('path')) {
            $appHostDir = [Environment]::ExpandEnvironmentVariables($redirect.GetAttribute('path'))
        }
    }

    # <location path="Default Web Site/app1">: compared case-insensitively, as IIS does.
    $locationPath = $ConfigPath.Substring($script:IisServerPath.Length).Trim('/')
    $appHost = New-Object -TypeName System.Xml.XmlDocument
    $appHost.Load([System.IO.Path]::Combine($appHostDir, 'applicationHost.config'))
    foreach ($location in $appHost.SelectNodes("/*[local-name()='configuration']/*[local-name()='location']")) {
        if ($location.GetAttribute('path').Trim('/') -eq $locationPath) {
            foreach ($mimeMap in $location.SelectNodes($mimeMapXPath)) {
                $null = $extensions.Add($mimeMap.GetAttribute('fileExtension'))
            }
        }
    }

    if ($PhysicalPath) {
        $webConfigPath = [System.IO.Path]::Combine($PhysicalPath, 'web.config')
        if (Test-Path -LiteralPath $webConfigPath -PathType Leaf) {
            $webConfig = New-Object -TypeName System.Xml.XmlDocument
            $webConfig.Load($webConfigPath)
            $root = $webConfig.SelectSingleNode("/*[local-name()='configuration']")
            if ($root) {
                $scopes = @($root) + @(
                    foreach ($location in $root.SelectNodes("*[local-name()='location']")) {
                        if ($location.GetAttribute('path').Trim('/') -in @('', '.')) {
                            $location
                        }
                    }
                )
                foreach ($scope in $scopes) {
                    foreach ($mimeMap in $scope.SelectNodes($mimeMapXPath)) {
                        $null = $extensions.Add($mimeMap.GetAttribute('fileExtension'))
                    }
                }
            }
        }
    }

    # The comma keeps PowerShell from enumerating the set on output.
    , $extensions
}

Function Resolve-IisConfigLevel {
    <#
    .SYNOPSIS
    Resolves the modules' site and application options to an IIS configuration level.

    .DESCRIPTION
    Without a site, the server level. A site must exist (names compare
    case-insensitively, without wildcards), and an application must be the
    virtual path of an application or virtual directory under it.

    Returns ConfigPath (for example MACHINE/WEBROOT/APPHOST/Default Web Site/app1),
    ParentPath (the level that one inherits from; $null at the server level),
    Site (IIS's spelling of the name; $null at the server level) and PhysicalPath
    (the level's content directory, where its web.config lives; $null when unknown).
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]
        $AdminManager,

        [AllowNull()]
        [object]
        $Site,

        [AllowNull()]
        [object]
        $Application
    )

    if ($null -eq $Site) {
        return [PSCustomObject]@{
            ConfigPath = $script:IisServerPath
            ParentPath = $null
            Site = $null
            PhysicalPath = $null
        }
    }

    $Site = [string]$Site
    if (-not $Site) {
        throw "site must not be empty; omit it for the server level."
    }

    $wanted = ''
    if ($null -ne $Application) {
        $Application = [string]$Application
        if ($Application.Contains('\')) {
            throw "application must be a virtual path with forward slashes, such as /app1; got '$Application'."
        }
        $wanted = '/' + $Application.Trim('/')
        if ($wanted -eq '/') {
            throw "application must name an application or virtual directory under the site; omit it for the site level."
        }
    }

    $sites = Get-IisSectionCollection -AdminManager $AdminManager -Section 'system.applicationHost/sites' -ConfigPath $script:IisServerPath
    $siteElement = $null
    $siteCount = Invoke-IisComMember -Object $sites -Name 'Count'
    for ($i = 0; $i -lt $siteCount; $i++) {
        $candidate = Invoke-IisComMember -Object $sites -Name 'Item' -ArgumentList $i
        if ([string](Get-IisElementValue -Element $candidate -Name 'name') -eq $Site) {
            $siteElement = $candidate
            break
        }
    }
    if ($null -eq $siteElement) {
        throw "IIS has no website named '$Site'."
    }
    $siteName = [string](Get-IisElementValue -Element $siteElement -Name 'name')

    # Every virtual path under the site: each application's path joined with
    # each of its virtual directories' paths ('' is the site's root).
    $virtualPath = $null
    $physicalPath = $null
    $applications = Invoke-IisComMember -Object $siteElement -Name 'Collection'
    $applicationCount = Invoke-IisComMember -Object $applications -Name 'Count'
    for ($a = 0; $a -lt $applicationCount -and $null -eq $virtualPath; $a++) {
        $app = Invoke-IisComMember -Object $applications -Name 'Item' -ArgumentList $a
        $appPath = ([string](Get-IisElementValue -Element $app -Name 'path')).TrimEnd('/')
        $directories = Invoke-IisComMember -Object $app -Name 'Collection'
        $directoryCount = Invoke-IisComMember -Object $directories -Name 'Count'
        for ($d = 0; $d -lt $directoryCount; $d++) {
            $directory = Invoke-IisComMember -Object $directories -Name 'Item' -ArgumentList $d
            $candidatePath = $appPath + ([string](Get-IisElementValue -Element $directory -Name 'path')).TrimEnd('/')
            if ($candidatePath -eq $wanted) {
                $virtualPath = $candidatePath
                $physicalPath = [Environment]::ExpandEnvironmentVariables([string](Get-IisElementValue -Element $directory -Name 'physicalPath'))
                break
            }
        }
    }

    if ($null -eq $virtualPath) {
        if ($wanted) {
            throw "Website '$siteName' has no application or virtual directory at '$wanted'."
        }
        # A site without a root virtual directory is still a configuration level.
        $virtualPath = ''
    }

    $configPath = "$script:IisServerPath/$siteName$virtualPath"
    [PSCustomObject]@{
        ConfigPath = $configPath
        ParentPath = $configPath.Substring(0, $configPath.LastIndexOf('/'))
        Site = $siteName
        PhysicalPath = $physicalPath
    }
}

Function ConvertTo-IisFileExtension {
    <#
    .SYNOPSIS
    Adds the leading dot IIS's MIME map keys carry, when it's missing.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]
        $Extension
    )

    if ($Extension.StartsWith('.')) {
        $Extension
    }
    else {
        ".$Extension"
    }
}

$exportFunctions = @(
    'ConvertTo-IisFileExtension'
    'Get-IisMimeMapEntry'
    'Get-IisSectionCollection'
    'Get-IisStoredMimeMapExtension'
    'Invoke-IisComMember'
    'New-IisAdminManager'
    'Resolve-IisConfigLevel'
    'Set-IisElementValue'
)
Export-ModuleMember -Function $exportFunctions
