# A fake of IIS's configuration API (Microsoft.ApplicationHost.AdminManager)
# for the IIS modules' Pester tests, dot-sourced by them. _IisConfig.psm1
# makes every call into the API through its private Invoke-IisComInvokeMember;
# Register-IisFakeCom mocks that one function, so the util's own code runs
# against these objects: a property is read or set, a method is a ScriptMethod.
# Dot-source it in a BeforeAll after importing _IisConfig.psm1 (its functions
# are script-scoped, so not a module of its own), and call Register-IisFakeCom
# in a BeforeEach or It.

function script:New-IisFakeElement {
    <#
    .SYNOPSIS
    A configuration element: Properties.Item(name).Value, and the child elements in Collection.
    #>
    param (
        [hashtable]
        $Values = @{},

        [object[]]
        $Children = @()
    )

    $map = @{}
    foreach ($key in $Values.Keys) {
        $map[$key] = [pscustomobject]@{ Value = $Values[$key] }
    }
    $properties = [pscustomobject]@{ Map = $map }
    $properties | Add-Member -MemberType ScriptMethod -Name Item -Value {
        param ($name)
        if (-not $this.Map.ContainsKey($name)) {
            $this.Map[$name] = [pscustomobject]@{ Value = $null }
        }
        $this.Map[$name]
    }

    [pscustomobject]@{
        Properties = $properties
        Collection = (New-IisFakeCollection -Elements $Children)
    }
}

function script:New-IisFakeMimeMap {
    <#
    .SYNOPSIS
    The mimeMap elements for a hashtable of extension = MIME type, in the order given ([ordered] keeps it).
    #>
    param (
        [System.Collections.IDictionary]
        $Map = @{}
    )

    foreach ($key in $Map.Keys) {
        New-IisFakeElement -Values @{ fileExtension = $key; mimeType = $Map[$key] }
    }
}

function script:New-IisFakeCollection {
    <#
    .SYNOPSIS
    An element collection that records DeleteElement and AddElement.

    .PARAMETER Shadowed
    Inherited elements hidden by local ones: deleting a local element for an
    extension lets the shadowed one for it show through in its place, as IIS
    does when a level overrides its parent's mapping.

    .PARAMETER Sticky
    DeleteElement records the call and removes nothing.
    #>
    param (
        [object[]]
        $Elements = @(),

        [object[]]
        $Shadowed = @(),

        [switch]
        $Sticky
    )

    $collection = [pscustomobject]@{
        Items = [System.Collections.Generic.List[object]]::new()
        Shadowed = [System.Collections.Generic.List[object]]::new()
        Sticky = [bool]$Sticky
        Deleted = [System.Collections.Generic.List[object]]::new()
        Added = [System.Collections.Generic.List[object]]::new()
    }
    foreach ($element in $Elements) {
        $collection.Items.Add($element)
    }
    foreach ($element in $Shadowed) {
        $collection.Shadowed.Add($element)
    }

    $collection | Add-Member -MemberType ScriptProperty -Name Count -Value { $this.Items.Count }
    $collection | Add-Member -MemberType ScriptMethod -Name Item -Value {
        param ($index)
        $this.Items[$index]
    }
    $collection | Add-Member -MemberType ScriptMethod -Name DeleteElement -Value {
        param ($index)
        $this.Deleted.Add($index)
        if ($this.Sticky) {
            return
        }
        $gone = $this.Items[$index]
        $this.Items.RemoveAt($index)
        $extension = $gone.Properties.Item('fileExtension').Value
        for ($i = 0; $i -lt $this.Shadowed.Count; $i++) {
            if ($this.Shadowed[$i].Properties.Item('fileExtension').Value -eq $extension) {
                $this.Items.Insert($index, $this.Shadowed[$i])
                $this.Shadowed.RemoveAt($i)
                break
            }
        }
    }
    $collection | Add-Member -MemberType ScriptMethod -Name CreateNewElement -Value {
        param ($name)
        $element = New-IisFakeElement
        $element | Add-Member -MemberType NoteProperty -Name ElementName -Value $name
        $element
    }
    $collection | Add-Member -MemberType ScriptMethod -Name AddElement -Value {
        param ($element, $position)
        $this.Added.Add([pscustomobject]@{ Element = $element; Position = $position })
        $this.Items.Add($element)
    }
    $collection
}

function script:New-IisFakeManager {
    <#
    .SYNOPSIS
    An admin manager whose GetAdminSection(section, path) returns the collection Sections holds for "section|path".
    #>
    param (
        [hashtable]
        $Sections = @{}
    )

    $manager = [pscustomobject]@{
        Sections = $Sections
        Commits = 0
        CommitPath = $null
    }
    $manager | Add-Member -MemberType ScriptMethod -Name GetAdminSection -Value {
        param ($section, $path)
        $key = "$section|$path"
        if (-not $this.Sections.ContainsKey($key)) {
            throw "Cannot read configuration file for $key"
        }
        [pscustomobject]@{ Collection = $this.Sections[$key] }
    }
    $manager | Add-Member -MemberType ScriptMethod -Name CommitChanges -Value { $this.Commits++ }
    $manager
}

function script:New-IisFakeSite {
    <#
    .SYNOPSIS
    A system.applicationHost/sites element.

    .PARAMETER Applications
    Hashtables of path and Directories, each directory a hashtable of path and physicalPath.
    #>
    param (
        [string]
        $Name,

        [hashtable[]]
        $Applications = @()
    )

    $apps = foreach ($app in $Applications) {
        $directories = foreach ($directory in @($app.Directories)) {
            New-IisFakeElement -Values @{ path = $directory.path; physicalPath = $directory.physicalPath }
        }
        New-IisFakeElement -Values @{ path = $app.path } -Children @($directories)
    }
    New-IisFakeElement -Values @{ name = $Name } -Children @($apps)
}

function script:Register-IisFakeCom {
    <#
    .SYNOPSIS
    Mocks _IisConfig's one call into the API, so the util talks to the fakes above. Call it in BeforeEach or It.
    #>
    Mock -ModuleName _IisConfig Invoke-IisComInvokeMember {
        if ($Flags -band [System.Reflection.BindingFlags]::SetProperty) {
            $Object.$Name = $ArgumentList[0]
            return
        }
        $method = $Object.psobject.Methods[$Name]
        if ($method -is [System.Management.Automation.PSScriptMethod]) {
            if ($null -eq $ArgumentList) {
                $ArgumentList = @()
            }
            , $method.Invoke([object[]]$ArgumentList)
        }
        else {
            , $Object.$Name
        }
    }
}
