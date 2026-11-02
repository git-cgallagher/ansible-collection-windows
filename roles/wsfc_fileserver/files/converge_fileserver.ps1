# converge_fileserver.ps1 — create a clustered general-purpose file server, or
# bring an existing one in line with the role's variables.
#
# Runs on one of the cluster's nodes (the managing node) with the
# FailoverClusters module. Invoked by roles/wsfc_fileserver via
# ansible.windows.win_powershell; also runnable standalone for debugging.
#
# Order of operations:
#   1. check the named disks exist as cluster disks
#   2. Add-ClusterFileServerRole, or, for an existing role, move in the disks
#      it lacks (from Available Storage) and bring it online
#   3. preferred owners
#   4. SMB shares scoped to the file server, on whichever node owns it now:
#      folder, share, properties, exact share permissions
#
# -ReportOnly (and Ansible check mode) reports every action without changing
# anything; for a role that doesn't exist yet it stops after step 2.
#
# Windows PowerShell 5.1-compatible.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [string[]]$StaticAddresses = @(),
    [string[]]$IgnoreNetworks = @(),
    [string[]]$Disks = @(),
    # The shares' shape is the role's argument spec.
    [string]$SharesJson = '[]',
    [string[]]$PreferredOwners = @(),
    [bool]$ReportOnly = $false
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Non-interactive: a confirmation prompt would fail the run.
$ConfirmPreference = 'None'

$inAnsible = $null -ne (Get-Variable -Name Ansible -ErrorAction SilentlyContinue)
if ($inAnsible -and $Ansible.CheckMode) { $ReportOnly = $true }

$actions = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$script:created = $false
$script:owner = ''

# Record an action; carry it out unless this is a report-only run.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Change)
    $actions.Add($Description)
    if (-not $ReportOnly) { & $Change }
}

function Get-ShortName {
    param([string]$Computer)
    ($Computer -split '\.')[0].ToUpperInvariant()
}

function Get-ResourceTypeName {
    param($Resource)
    $type = $Resource.ResourceType
    if ($null -ne $type -and $type.PSObject.Properties['Name']) { return [string]$type.Name }
    [string]$type
}

function Get-GroupOrNull {
    param([string]$Conn, [string]$GroupName)
    try {
        Get-ClusterGroup -Cluster $Conn -Name $GroupName -ErrorAction Stop
    }
    catch {
        $null
    }
}

# Converges the shares on the node that owns the file server (SMB shares
# scoped to a clustered name can only be managed there). Self-contained so it
# can run through Invoke-Command; returns the actions and warnings it found.
$shareBlock = {
    param([string]$Scope, [string]$Json, [bool]$DryRun)
    $ErrorActionPreference = 'Stop'
    $ConfirmPreference = 'None'
    $found = New-Object System.Collections.Generic.List[string]
    $notes = New-Object System.Collections.Generic.List[string]

    function Invoke-ShareChange {
        param([string]$Description, [scriptblock]$Change)
        $found.Add($Description)
        if (-not $DryRun) { & $Change }
    }

    function Get-Value {
        param($Object, [string]$Key, $Default = $null)
        if ($null -ne $Object -and $Object.PSObject.Properties[$Key] -and $null -ne $Object.$Key) {
            return $Object.$Key
        }
        $Default
    }

    function Get-Sid {
        param([string]$Account)
        try {
            (New-Object System.Security.Principal.NTAccount($Account)).Translate(
                [System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            throw "Account '$Account' doesn't resolve to a security identifier"
        }
    }

    # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE
    # object; enumerate it.
    $shares = @(foreach ($item in ($Json | ConvertFrom-Json)) { $item })
    foreach ($spec in $shares) {
        $shareName = [string](Get-Value -Object $spec -Key 'name' -Default '')
        $path = ([string](Get-Value -Object $spec -Key 'path' -Default '')).TrimEnd('\')
        if (-not $shareName -or -not $path) { throw 'Every share needs a name and a path' }
        $wanted = @{
            Description = [string](Get-Value -Object $spec -Key 'description' -Default '')
            ContinuouslyAvailable = [bool](Get-Value -Object $spec -Key 'continuously_available' -Default $false)
            FolderEnumerationMode = [string](Get-Value -Object $spec -Key 'folder_enumeration_mode' -Default 'Unrestricted')
            EncryptData = [bool](Get-Value -Object $spec -Key 'encrypt_data' -Default $false)
        }
        $access = [ordered]@{
            Full = @(Get-Value -Object $spec -Key 'full_access' -Default @())
            Change = @(Get-Value -Object $spec -Key 'change_access' -Default @())
            Read = @(Get-Value -Object $spec -Key 'read_access' -Default @())
        }
        $manageAccess = ($access.Full.Count + $access.Change.Count + $access.Read.Count) -gt 0

        $existing = Get-SmbShare -ScopeName $Scope -Name $shareName -ErrorAction SilentlyContinue
        if ($null -eq $existing) {
            $drive = Split-Path -Path $path -Qualifier
            if (-not (Test-Path -LiteralPath "$drive\")) {
                throw "Share $shareName : $drive isn't a volume on $env:COMPUTERNAME, which owns $Scope (is it on one of the role's disks?)"
            }
            if (-not (Test-Path -LiteralPath $path)) {
                Invoke-ShareChange "create folder $path" {
                    $null = New-Item -ItemType Directory -Path $path -Force
                }
            }
            $newParams = @{
                Name = $shareName
                Path = $path
                ScopeName = $Scope
                ContinuouslyAvailable = $wanted.ContinuouslyAvailable
                FolderEnumerationMode = $wanted.FolderEnumerationMode
                EncryptData = $wanted.EncryptData
            }
            if ($wanted.Description) { $newParams.Description = $wanted.Description }
            if ($access.Full.Count) { $newParams.FullAccess = $access.Full }
            if ($access.Change.Count) { $newParams.ChangeAccess = $access.Change }
            if ($access.Read.Count) { $newParams.ReadAccess = $access.Read }
            Invoke-ShareChange "create share \\$Scope\$shareName ($path)" {
                $null = New-SmbShare @newParams
            }
            continue
        }

        if ($existing.Path.TrimEnd('\') -ne $path) {
            $notes.Add("Share \\$Scope\$shareName points at $($existing.Path), not $path; it was left as it is")
        }
        $drift = @{}
        foreach ($key in $wanted.Keys) {
            if ([string]$existing.$key -ne [string]$wanted[$key]) { $drift[$key] = $wanted[$key] }
        }
        if ($drift.Count -gt 0) {
            $what = ($drift.Keys | Sort-Object | ForEach-Object { "$_=$($drift[$_])" }) -join ', '
            Invoke-ShareChange "set share \\$Scope\$shareName $what" {
                $null = Set-SmbShare -ScopeName $Scope -Name $shareName @drift -Force
            }
        }

        if (-not $manageAccess) { continue }
        # Exact share permissions, compared by SID so 'Domain Admins' and
        # 'EXAMPLE\Domain Admins' are the same account.
        $desired = @{}
        foreach ($right in $access.Keys) {
            foreach ($account in $access[$right]) {
                $sid = Get-Sid $account
                if ($desired.ContainsKey($sid)) {
                    throw "Share $shareName lists $account in more than one access list"
                }
                $desired[$sid] = @{ account = $account; right = $right }
            }
        }
        $current = @{}
        foreach ($entry in @(Get-SmbShareAccess -ScopeName $Scope -Name $shareName)) {
            if ([string]$entry.AccessControlType -ne 'Allow') {
                $notes.Add("Share \\$Scope\$shareName has a Deny entry for $($entry.AccountName); it was left as it is")
                continue
            }
            $current[(Get-Sid $entry.AccountName)] = @{ account = $entry.AccountName; right = [string]$entry.AccessRight }
        }
        foreach ($sid in @($current.Keys)) {
            if (-not $desired.ContainsKey($sid)) {
                $account = $current[$sid].account
                Invoke-ShareChange "revoke $account from share \\$Scope\$shareName" {
                    $null = Revoke-SmbShareAccess -ScopeName $Scope -Name $shareName -AccountName $account -Force
                }
            }
        }
        foreach ($sid in @($desired.Keys)) {
            $want = $desired[$sid]
            if (-not $current.ContainsKey($sid) -or $current[$sid].right -ne $want.right) {
                Invoke-ShareChange "grant $($want.account) $($want.right) on share \\$Scope\$shareName" {
                    $null = Grant-SmbShareAccess -ScopeName $Scope -Name $shareName -AccountName $want.account -AccessRight $want.right -Force
                }
            }
        }
    }
    [pscustomobject]@{ actions = @($found); warnings = @($notes) }
}

function Invoke-Main {
    if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
        throw "$env:COMPUTERNAME has no FailoverClusters module; build the cluster first (the wsfc role)"
    }
    Import-Module FailoverClusters
    $conn = $env:COMPUTERNAME
    $cluster = Get-Cluster -Name $conn

    # --- 1. disks ---------------------------------------------------------------
    $diskOwners = @{}
    foreach ($diskName in $Disks) {
        $resource = Get-ClusterResource -Cluster $conn | Where-Object { $_.Name -eq $diskName } | Select-Object -First 1
        if ($null -eq $resource) {
            throw "Cluster $($cluster.Name) has no disk named '$diskName' (create it with the wsfc role's wsfc_disks)"
        }
        $typeName = Get-ResourceTypeName $resource
        if ($typeName -ne 'Physical Disk') { throw "Cluster resource $diskName is a '$typeName', not a Physical Disk" }
        $diskOwners[$diskName] = [string]$resource.OwnerGroup.Name
    }

    # --- 2. the role ------------------------------------------------------------
    $group = Get-GroupOrNull -Conn $conn -GroupName $Name
    if ($null -eq $group) {
        if ($Disks.Count -eq 0) { throw "Creating file server $Name needs at least one disk (wsfc_fileserver_disks)" }
        foreach ($diskName in $Disks) {
            if ($diskOwners[$diskName] -ne 'Available Storage') {
                throw "Disk $diskName belongs to cluster group '$($diskOwners[$diskName])', not Available Storage"
            }
        }
        $roleParams = @{
            Cluster = $conn
            Name = $Name
            Storage = $Disks
        }
        if ($StaticAddresses.Count -gt 0) { $roleParams.StaticAddress = $StaticAddresses }
        if ($IgnoreNetworks.Count -gt 0) { $roleParams.IgnoreNetwork = $IgnoreNetworks }
        Invoke-Change "create file server $Name on $($Disks -join ', ')" {
            $null = Add-ClusterFileServerRole @roleParams
            $script:created = $true
        }
        if ($ReportOnly) {
            if (@(ConvertFrom-JsonArray $SharesJson).Count -gt 0 -or $PreferredOwners.Count -gt 0) {
                $warnings.Add('Preferred owners and shares are planned once the file server exists')
            }
            return
        }
        $group = Get-ClusterGroup -Cluster $conn -Name $Name
    }
    else {
        $groupType = [string]$group.GroupType
        if ($groupType -ne 'FileServer') {
            throw "Cluster group $Name exists but is a $groupType, not a file server"
        }
        $fileServer = Get-ClusterResource -Cluster $conn |
            Where-Object { $_.OwnerGroup.Name -eq $Name -and (Get-ResourceTypeName $_) -eq 'File Server' } |
            Select-Object -First 1
        foreach ($diskName in $Disks) {
            $diskOwner = $diskOwners[$diskName]
            if ($diskOwner -eq $Name) { continue }
            if ($diskOwner -ne 'Available Storage') {
                throw "Disk $diskName belongs to cluster group '$diskOwner', not Available Storage or $Name"
            }
            Invoke-Change "add disk $diskName to file server $Name" {
                $null = Move-ClusterResource -Cluster $conn -Name $diskName -Group $Name
                if ($null -ne $fileServer) {
                    $null = Add-ClusterResourceDependency -Cluster $conn -Resource $fileServer.Name -Provider $diskName
                }
            }
        }
        if ([string]$group.State -ne 'Online') {
            Invoke-Change "bring file server $Name online (it was $($group.State))" {
                $null = Start-ClusterGroup -Cluster $conn -Name $Name -Wait 300
            }
        }
    }

    # --- 3. preferred owners ----------------------------------------------------
    if ($PreferredOwners.Count -gt 0) {
        $currentOwners = @((Get-ClusterOwnerNode -Cluster $conn -Group $Name).OwnerNodes | ForEach-Object { Get-ShortName $_.Name })
        $wantedOwners = @($PreferredOwners | ForEach-Object { Get-ShortName $_ })
        if (($currentOwners -join ',') -ne ($wantedOwners -join ',')) {
            Invoke-Change "set preferred owners of $Name to $($PreferredOwners -join ', ')" {
                $null = Set-ClusterOwnerNode -Cluster $conn -Group $Name -Owners $PreferredOwners
            }
        }
    }

    # --- 4. shares --------------------------------------------------------------
    $group = Get-ClusterGroup -Cluster $conn -Name $Name
    $script:owner = [string]$group.OwnerNode.Name
    if (@(ConvertFrom-JsonArray $SharesJson).Count -eq 0) { return }
    if ([string]$group.State -ne 'Online' -and -not $ReportOnly) {
        throw "File server $Name is $($group.State) on $($script:owner); its shares need it online"
    }
    if ((Get-ShortName $script:owner) -eq (Get-ShortName $env:COMPUTERNAME)) {
        $shareResult = & $shareBlock $Name $SharesJson $ReportOnly
    }
    else {
        # Reaching the owner is the double hop: it needs the role's become
        # account (or delegation).
        $shareResult = Invoke-Command -ComputerName $script:owner -ScriptBlock $shareBlock -ArgumentList $Name, $SharesJson, $ReportOnly
    }
    foreach ($a in @($shareResult.actions)) { $actions.Add("$($script:owner): $a") }
    foreach ($w in @($shareResult.warnings)) { $warnings.Add($w) }
}

# Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE object;
# enumerate it.
function ConvertFrom-JsonArray {
    param([string]$Json)
    foreach ($item in ($Json | ConvertFrom-Json)) { $item }
}

$failed = $false
$errorText = ''
$errorDetail = ''
try {
    Invoke-Main
}
catch {
    $failed = $true
    $errorText = '{0} (at line {1}: {2})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber,
    $_.InvocationInfo.Line.Trim()
    $errorDetail = ($_.Exception.ToString() + "`n" + $_.ScriptStackTrace)
    if ($errorDetail.Length -gt 4000) { $errorDetail = $errorDetail.Substring(0, 4000) }
    if (-not $inAnsible) { throw }
}

$result = @{
    name = $Name
    report_only = $ReportOnly
    created = $script:created
    owner = $script:owner
    actions = @($actions)
    warnings = @($warnings)
    identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}
if ($inAnsible) {
    # A report-only run that found work reports "changed", like check mode.
    $Ansible.Changed = $actions.Count -gt 0
    $Ansible.Result = $result
    if ($failed) {
        $Ansible.Failed = $true
        $result.error = $errorText
        $result.error_detail = $errorDetail
    }
}
else {
    [pscustomobject]$result
}
