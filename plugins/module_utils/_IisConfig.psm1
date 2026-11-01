# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the iis_* modules: IIS's configuration system through its native
# COM API (Microsoft.ApplicationHost.AdminManager, the API appcmd.exe uses),
# resolving the site and application options to a configuration path, and
# reading a level's MIME map. Private to this collection, with no compatibility
# promise. Windows PowerShell 5.1 syntax only.

$script:IisServerPath = 'MACHINE/WEBROOT/APPHOST'

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
        $manager.CommitPath = $CommitPath
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
        $collection = $AdminManager.GetAdminSection($Section, $ConfigPath).Collection
    }
    catch {
        # TEMPORARY (PR 22): the full exception, to diagnose the IIS lab.
        $detail = "$($_.Exception.GetType().FullName) on a $([Threading.Thread]::CurrentThread.GetApartmentState()) thread: $($_.Exception.ToString())"
        throw "Couldn't read $Section at ${ConfigPath}: $($_.Exception.Message) [$detail]"
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
    changes. DefinedAt is the configuration path the element comes from (the
    deepestPathSet metadata), or '' when IIS doesn't report it.

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

    for ($i = 0; $i -lt $Collection.Count; $i++) {
        $element = $Collection.Item($i)
        $fileExtension = [string]$element.Properties.Item('fileExtension').Value
        if ($Extension -and $fileExtension -ne $Extension) {
            continue
        }

        try {
            $definedAt = ([string]$element.GetMetadata('deepestPathSet')).TrimEnd('/')
        }
        catch {
            # ERROR_NOT_SUPPORTED: callers fall back to comparing with the parent level.
            $definedAt = ''
        }

        [PSCustomObject]@{
            Index = $i
            Extension = $fileExtension
            MimeType = [string]$element.Properties.Item('mimeType').Value
            DefinedAt = $definedAt
        }
    }
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
    for ($i = 0; $i -lt $sites.Count; $i++) {
        $candidate = $sites.Item($i)
        if ([string]$candidate.Properties.Item('name').Value -eq $Site) {
            $siteElement = $candidate
            break
        }
    }
    if ($null -eq $siteElement) {
        throw "IIS has no website named '$Site'."
    }
    $siteName = [string]$siteElement.Properties.Item('name').Value

    # Every virtual path under the site: each application's path joined with
    # each of its virtual directories' paths ('' is the site's root).
    $virtualPath = $null
    $physicalPath = $null
    $applications = $siteElement.Collection
    for ($a = 0; $a -lt $applications.Count -and $null -eq $virtualPath; $a++) {
        $app = $applications.Item($a)
        $appPath = ([string]$app.Properties.Item('path').Value).TrimEnd('/')
        $directories = $app.Collection
        for ($d = 0; $d -lt $directories.Count; $d++) {
            $directory = $directories.Item($d)
            $candidatePath = $appPath + ([string]$directory.Properties.Item('path').Value).TrimEnd('/')
            if ($candidatePath -eq $wanted) {
                $virtualPath = $candidatePath
                $physicalPath = [Environment]::ExpandEnvironmentVariables([string]$directory.Properties.Item('physicalPath').Value)
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

Export-ModuleMember -Function New-IisAdminManager, Get-IisSectionCollection, Get-IisMimeMapEntry, Resolve-IisConfigLevel, ConvertTo-IisFileExtension
