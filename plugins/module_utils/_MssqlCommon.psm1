# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

# Shared by the SQL Server modules (mssql_setup, mssql_info, mssql_network
# and mssql_configuration). Most of it is pure logic, with no Ansible.Basic,
# registry, setup or SQL Server calls, so Pester tests it on any platform
# (tests/unit/plugins/module_utils/_MssqlCommon.Tests.ps1): versions and
# editions, the media and its checksum, the features, the plan for an
# instance, setup's command line and its Summary.txt, the network plan,
# certificate checks, errorlog lines and firewall rules, and the sp_configure
# and tempdb plans with the T-SQL they run. A few functions read the host for
# every module: the instances the registry lists (Get-MssqlInstanceRegistry),
# their services (Get-MssqlServiceState), the errorlog (Read-MssqlErrorLog)
# and queries through SqlClient (Invoke-MssqlQuery, Invoke-MssqlNonQuery,
# which also writes). One changes it: Restart-MssqlEngine, which
# mssql_network and mssql_configuration restart an instance with.
# Script modules don't see the calling module's $ErrorActionPreference, so
# every call here that must stop on an error says -ErrorAction Stop.
# Private to this collection, with no compatibility promise. Windows
# PowerShell 5.1 syntax only.

# The versions the modules install. Major is the version setup and the
# registry use (MSSQL16.<instance>), Folder its directory under
# %ProgramFiles%\Microsoft SQL Server (160\Setup Bootstrap).
$script:MssqlVersions = @{
    '2022' = @{ Major = 16; Folder = '160' }
    '2025' = @{ Major = 17; Folder = '170' }
}

# Setup's /PID for the free Developer editions, as each one's media carries
# it in x64\DefaultSetup.ini. 2022's is read from its Developer ISO; 2025's
# two come from community sources (unconfirmed).
$script:MssqlDeveloperPids = [ordered]@{
    enterprise_developer = '22222-00000-00000-00000-00000'
    standard_developer = '33333-00000-00000-00000-00000'
}

# The features the modules install: the name in their options, setup's name
# (/FEATURES), and the name the registry records it under (an instance's
# ConfigurationState values, and the tokens of its Setup\FeatureList).
$script:MssqlFeatures = [ordered]@{
    SQLEngine = @{ Setup = 'SQLENGINE'; State = 'SQL_Engine_Core_Inst' }
    Replication = @{ Setup = 'REPLICATION'; State = 'SQL_Replication_Core_Inst' }
    FullText = @{ Setup = 'FULLTEXT'; State = 'SQL_FullText_Adv' }
}

Function Get-MssqlVersionInfo {
    <#
    .SYNOPSIS
    Returns a version's major number and folder (see $MssqlVersions), or
    $null for a version the modules don't install.
    #>
    [CmdletBinding()]
    param ([string]$Version)

    if (-not $script:MssqlVersions.ContainsKey($Version)) { return $null }
    $info = $script:MssqlVersions[$Version]
    @{ Version = $Version; Major = $info.Major; Folder = $info.Folder }
}

Function ConvertTo-MssqlVersionName {
    <#
    .SYNOPSIS
    Returns the version name ('2022', '2025') of a major version (16), an
    instance ID (MSSQL16.MSSQLSERVER) or a version number (16.0.1000.6), or ''
    for a version the modules don't install.
    #>
    [CmdletBinding()]
    param ([string]$Version)

    $major = 0
    if ($Version -match '^MSSQL(\d+)\.') {
        $major = [int]$Matches[1]
    }
    elseif ($Version -match '^(\d+)(\.|$)') {
        $major = [int]$Matches[1]
    }
    foreach ($name in $script:MssqlVersions.Keys) {
        if ($script:MssqlVersions[$name].Major -eq $major) { return $name }
    }
    ''
}

Function Get-MssqlPidEdition {
    <#
    .SYNOPSIS
    Returns the edition a product key installs: a Developer edition for its
    well-known key, evaluation for none (the Evaluation media carries no key),
    and licensed for any other key (a paid edition's, which only setup can
    tell apart).
    #>
    [CmdletBinding()]
    param ([string]$ProductId)

    if (-not $ProductId) { return 'evaluation' }
    foreach ($edition in $script:MssqlDeveloperPids.Keys) {
        if ($script:MssqlDeveloperPids[$edition] -eq $ProductId) { return $edition }
    }
    'licensed'
}

Function Get-MssqlMediaInfo {
    <#
    .SYNOPSIS
    Reads what SQL Server media is from two of its files: its build from
    MediaInfo.xml (the BaselineVersion property), and the product key setup
    uses by default from x64\DefaultSetup.ini (PID), which decides the edition
    (Get-MssqlPidEdition).
    #>
    [CmdletBinding()]
    param ([string]$MediaInfoXml, [string]$DefaultSetupIni)

    $build = ''
    if ($MediaInfoXml) {
        $xml = [xml]($MediaInfoXml.TrimStart([char]0xFEFF))
        foreach ($property in @($xml.SelectNodes('//Property'))) {
            if ([string]$property.GetAttribute('Id') -eq 'BaselineVersion') { $build = [string]$property.GetAttribute('Value') }
        }
    }
    $productId = ''
    foreach ($line in @([string]$DefaultSetupIni -split "`r?`n")) {
        if ($line -match '^\s*PID\s*=\s*"?([^"]*)"?\s*$') { $productId = $Matches[1].Trim() }
    }
    @{
        Build = $build
        Version = ConvertTo-MssqlVersionName $build
        ProductId = $productId
        Edition = Get-MssqlPidEdition $productId
    }
}

Function Get-MssqlEditionPlan {
    <#
    .SYNOPSIS
    Decides setup's /PID for the edition asked for, and refuses what setup
    can't install. MediaEdition is what the media's DefaultSetup.ini makes it
    (Get-MssqlMediaInfo); before the media is read, leave it out and only the
    checks that don't need it run.
    Returns ProductId (the /PID to pass; '' passes none, so setup takes the
    media's own key, or installs Evaluation) and Problem ('' when there is
    none).
    #>
    [CmdletBinding()]
    param (
        [string]$Version,
        [string]$Edition,
        [string]$ProductKey,
        [string]$MediaEdition
    )

    $plan = @{ ProductId = ''; Problem = '' }
    $developer = $script:MssqlDeveloperPids.Contains($Edition)
    if ($Edition -eq 'standard_developer' -and $Version -eq '2022') {
        $plan.Problem = 'SQL Server 2022 has no Standard Developer edition: use enterprise_developer (2022''s Developer edition), or 2025 media'
        return $plan
    }
    if ($ProductKey -and ($developer -or $Edition -eq 'evaluation')) {
        $plan.Problem = "Edition $Edition takes no product key"
        return $plan
    }
    if ($developer) {
        $plan.ProductId = $script:MssqlDeveloperPids[$Edition]
        # Evaluation media installs any edition its key unlocks.
        if ($MediaEdition -and $MediaEdition -ne 'evaluation' -and $MediaEdition -ne $Edition) {
            $plan.Problem = "The media is for edition $MediaEdition (the PID in its x64\DefaultSetup.ini), not $Edition"
        }
        return $plan
    }
    if ($Edition -eq 'evaluation') {
        if ($MediaEdition -and $MediaEdition -ne 'evaluation') {
            $plan.Problem = "The media is for edition $MediaEdition (the PID in its x64\DefaultSetup.ini): setup would install that, not Evaluation"
        }
        return $plan
    }
    # Enterprise and Standard: the key passed, or the media's own.
    if ($ProductKey) {
        $plan.ProductId = $ProductKey
    }
    elseif ($MediaEdition -and $MediaEdition -ne 'licensed') {
        $plan.Problem = "Edition $Edition needs product_key: the media carries no key of its own for it (it is for $MediaEdition)"
    }
    $plan
}

Function ConvertTo-MssqlEditionId {
    <#
    .SYNOPSIS
    Returns the edition, as the modules name it, of an edition string from
    the registry (Setup\Edition) or SERVERPROPERTY('Edition'), such as
    "Developer Edition (64-bit)"; '' for one they don't install (Express,
    Web).
    #>
    [CmdletBinding()]
    param ([string]$Edition)

    if ($Edition -match '^Standard Developer') { return 'standard_developer' }
    if ($Edition -match '^(Enterprise )?Developer') { return 'enterprise_developer' }
    if ($Edition -match 'Evaluation') { return 'evaluation' }
    if ($Edition -match '^Enterprise') { return 'enterprise' }
    if ($Edition -match '^Standard') { return 'standard' }
    ''
}

Function Get-MssqlSetupBootstrap {
    <#
    .SYNOPSIS
    Returns where an installed version keeps its own copy of setup.exe (what
    uninstalls an instance without the media) and setup's log directory
    (Summary.txt, and a folder per run), under ProgramFiles.
    #>
    [CmdletBinding()]
    param ([string]$Version, [string]$ProgramFiles)

    $info = Get-MssqlVersionInfo $Version
    if ($null -eq $info) { return $null }
    $root = '{0}\Microsoft SQL Server\{1}\Setup Bootstrap' -f $ProgramFiles.TrimEnd('\'), $info.Folder
    @{ Setup = '{0}\SQL{1}\setup.exe' -f $root, $Version; Log = $root + '\Log' }
}

Function Get-MssqlChecksumHash {
    <#
    .SYNOPSIS
    Returns the lower-case SHA-256 of a checksum given as sha256:<64 hex
    digits>, or '' when it isn't one.
    #>
    [CmdletBinding()]
    param ([string]$Checksum)

    if ($Checksum -match '^sha256:([0-9A-Fa-f]{64})$') { return $Matches[1].ToLowerInvariant() }
    ''
}

Function Get-MssqlMediaSource {
    <#
    .SYNOPSIS
    Classifies the media's path: a local path, a UNC path or an http(s) URL.
    Returns the ISO's file name and LocalPath, where the module reads it: the
    path itself when local, a copy in CacheDir otherwise. Problem says what's
    wrong with a path the module can't use.
    #>
    [CmdletBinding()]
    param ([string]$Path, [string]$CacheDir)

    $source = @{ Kind = ''; FileName = ''; LocalPath = ''; Problem = '' }
    if ($Path -match '^https?://[^/]+/([^?#]+)') {
        $source.Kind = 'url'
        $source.FileName = [uri]::UnescapeDataString(($Matches[1] -split '/')[-1])
    }
    elseif ($Path -match '^\\\\[^\\]+\\[^\\]+\\.') {
        $source.Kind = 'unc'
        $source.FileName = ($Path -split '\\')[-1]
    }
    elseif ($Path -match '^[A-Za-z]:\\.') {
        $source.Kind = 'local'
        $source.FileName = ($Path -split '\\')[-1]
        $source.LocalPath = $Path
    }
    else {
        $source.Problem = "media.path must be a local path (C:\...), a UNC path (\\server\share\...) or an http(s) URL, got '$Path'"
        return $source
    }
    if ($source.FileName -notmatch '^[^<>:"/\\|?*]+\.iso$') {
        $source.Problem = "media.path must name an .iso file, got '$Path'"
        return $source
    }
    if ($source.Kind -ne 'local') { $source.LocalPath = $CacheDir.TrimEnd('\') + '\' + $source.FileName }
    $source
}

Function ConvertTo-MssqlFeatureName {
    <#
    .SYNOPSIS
    Returns a feature's name as the modules write it (SQLEngine,
    Replication, FullText) from any case of it, or '' for a feature the
    modules don't install.
    #>
    [CmdletBinding()]
    param ([string]$Feature)

    foreach ($name in $script:MssqlFeatures.Keys) {
        if ($name -eq $Feature) { return $name }
    }
    ''
}

Function Get-MssqlInstalledFeature {
    <#
    .SYNOPSIS
    Which of the modules' features an instance has. SQLEngine always (every
    instance the registry lists has it); FullText when its launcher service
    exists; Replication from what the registry records under the instance
    ID: its ConfigurationState value SQL_Replication_Core_Inst (1 is
    installed), else that token in Setup\FeatureList (a number above 0). Where
    the registry has neither, Replication goes in Unknown and Known is false.
    Source names where Replication's state came from.
    #>
    [CmdletBinding()]
    param ([hashtable]$ConfigurationState, [string]$FeatureList, [bool]$HasFullTextService)

    $replication = $script:MssqlFeatures['Replication'].State
    $tokens = @{}
    foreach ($token in @([string]$FeatureList -split '\s+')) {
        if ($token -match '^([^=]+)=(\d+)$') { $tokens[$Matches[1]] = [int]$Matches[2] }
    }
    $hasReplication = $false
    $source = 'services'
    if ($null -ne $ConfigurationState) {
        $source = 'ConfigurationState'
        $hasReplication = [string]$ConfigurationState[$replication] -eq '1'
    }
    elseif ($tokens.ContainsKey($replication) -or $tokens.ContainsKey($script:MssqlFeatures['SQLEngine'].State)) {
        $source = 'FeatureList'
        $hasReplication = $tokens.ContainsKey($replication) -and $tokens[$replication] -gt 0
    }
    $features = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    $features.Add('SQLEngine')
    if ($source -eq 'services') {
        $unknown.Add('Replication')
    }
    elseif ($hasReplication) {
        $features.Add('Replication')
    }
    if ($HasFullTextService) { $features.Add('FullText') }
    @{ Features = $features.ToArray(); Unknown = $unknown.ToArray(); Known = $unknown.Count -eq 0; Source = $source }
}

Function Get-MssqlInstancePlan {
    <#
    .SYNOPSIS
    Decides what setup does for one instance. Action is install,
    add_features, uninstall or none; AddFeatures lists the features to add.
    Settings fixed at install that differ (version, edition, collation) come
    back as Notices, never as a reinstall, and so do installed features the
    options don't list, which are never removed.
    Desired: State, Version, Edition, Features, Collation (empty to skip the
    comparison). Installed: $null, or ConvertTo-MssqlInstanceFact's result.
    #>
    [CmdletBinding()]
    param ([string]$InstanceName, [hashtable]$Desired, [hashtable]$Installed)

    $notices = [System.Collections.Generic.List[string]]::new()
    $plan = @{ Action = 'none'; AddFeatures = @(); Notices = @() }
    if ($Desired.State -eq 'absent') {
        if ($null -ne $Installed) { $plan.Action = 'uninstall' }
        return $plan
    }
    if ($null -eq $Installed) {
        $plan.Action = 'install'
        return $plan
    }

    $sameVersion = $Installed.version -eq $Desired.Version
    if (-not $sameVersion) {
        $installedVersion = $Installed.version
        if (-not $installedVersion) { $installedVersion = "version $($Installed.version_number) ($($Installed.id))" }
        $notices.Add("Instance $InstanceName is SQL Server $installedVersion, not $($Desired.Version): an installed instance is never reinstalled or upgraded")
    }
    if ($Installed.edition_id -ne $Desired.Edition) {
        $notices.Add("Instance $InstanceName is edition '$($Installed.edition)', not $($Desired.Edition): an installed instance's edition is never changed")
    }
    if ($Desired.Collation -and $Installed.collation -and $Installed.collation -ne $Desired.Collation) {
        $notices.Add("Instance $InstanceName has collation $($Installed.collation), not $($Desired.Collation): the server collation is set at install only")
    }

    $installedFeatures = @($Installed.features)
    $unknownFeatures = @($Installed.features_unknown)
    $missing = @($Desired.Features | Where-Object { $installedFeatures -notcontains $_ -and $unknownFeatures -notcontains $_ })
    $untold = @($Desired.Features | Where-Object { $unknownFeatures -contains $_ })
    $extra = @($installedFeatures | Where-Object { @($Desired.Features) -notcontains $_ })
    if ($untold.Count -gt 0) {
        $message = ("Can't tell whether instance {0} has {1} (the registry records nothing for it), " +
            "so setup doesn't run for it") -f $InstanceName, ($untold -join ', ')
        $notices.Add($message)
    }
    if ($missing.Count -gt 0) {
        if (-not $sameVersion) {
            $notices.Add("Instance $InstanceName lacks $($missing -join ', '), which $($Desired.Version) media can't add to it")
        }
        else {
            $plan.Action = 'add_features'
            $plan.AddFeatures = $missing
        }
    }
    foreach ($feature in $extra) {
        $notices.Add("Instance $InstanceName has feature $feature, which features doesn't list: features are never removed")
    }
    $plan.Notices = $notices.ToArray()
    $plan
}

Function ConvertTo-MssqlSetupArgument {
    <#
    .SYNOPSIS
    One setup.exe argument: a Value of $null is a switch (/Q); a list is
    several quoted values (/SQLSYSADMINACCOUNTS="a" "b"). Secret marks a value
    Format-MssqlSetupArgument redacts.
    #>
    [CmdletBinding()]
    param ([string]$Name, $Value = $null, [switch]$Secret)

    @{ Name = $Name; Value = $Value; Secret = [bool]$Secret }
}

Function Get-MssqlSetupArgument {
    <#
    .SYNOPSIS
    Builds setup.exe's arguments. Action Install installs a new instance,
    AddFeatures adds Features to an existing one, Uninstall removes Features
    from one. Options holds the rest, by setup's meaning: InstanceName,
    Features, ProductId, UpdateSource, EngineAccount, EnginePassword,
    AgentAccount, AgentPassword, AgentStartup, Sysadmins, Collation,
    InstantFileInit, Paths and Tempdb (hashtables, by the module's option
    names). An empty value is left off, so setup applies its default.
    #>
    [CmdletBinding()]
    param ([string]$Action, [hashtable]$Options)

    $list = [System.Collections.Generic.List[object]]::new()
    $features = @($Options.Features | ForEach-Object { $script:MssqlFeatures[(ConvertTo-MssqlFeatureName $_)].Setup })
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'Q'))
    if ($Action -eq 'Uninstall') {
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'ACTION' -Value 'Uninstall'))
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'FEATURES' -Value ($features -join ',')))
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'INSTANCENAME' -Value $Options.InstanceName))
        return $list.ToArray()
    }

    $list.Add((ConvertTo-MssqlSetupArgument -Name 'ACTION' -Value 'Install'))
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'IACCEPTSQLSERVERLICENSETERMS'))
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'FEATURES' -Value ($features -join ',')))
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'INSTANCENAME' -Value $Options.InstanceName))
    # Cumulative updates come only from a folder named here, never from
    # Microsoft Update.
    if ($Options.UpdateSource) {
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'UpdateEnabled' -Value 'True'))
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'UpdateSource' -Value $Options.UpdateSource))
    }
    else {
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'UpdateEnabled' -Value 'False'))
    }
    if ($Action -eq 'AddFeatures') { return $list.ToArray() }

    if ($Options.ProductId) { $list.Add((ConvertTo-MssqlSetupArgument -Name 'PID' -Value $Options.ProductId -Secret)) }
    if ($Options.EngineAccount) { $list.Add((ConvertTo-MssqlSetupArgument -Name 'SQLSVCACCOUNT' -Value $Options.EngineAccount)) }
    if ($Options.EnginePassword) { $list.Add((ConvertTo-MssqlSetupArgument -Name 'SQLSVCPASSWORD' -Value $Options.EnginePassword -Secret)) }
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'SQLSVCSTARTUPTYPE' -Value 'Automatic'))
    if ($Options.AgentAccount) { $list.Add((ConvertTo-MssqlSetupArgument -Name 'AGTSVCACCOUNT' -Value $Options.AgentAccount)) }
    if ($Options.AgentPassword) { $list.Add((ConvertTo-MssqlSetupArgument -Name 'AGTSVCPASSWORD' -Value $Options.AgentPassword -Secret)) }
    if ($Options.AgentStartup) {
        $startup = (Get-Culture).TextInfo.ToTitleCase([string]$Options.AgentStartup)
        $list.Add((ConvertTo-MssqlSetupArgument -Name 'AGTSVCSTARTUPTYPE' -Value $startup))
    }
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'SQLSYSADMINACCOUNTS' -Value @($Options.Sysadmins)))
    if ($Options.Collation) { $list.Add((ConvertTo-MssqlSetupArgument -Name 'SQLCOLLATION' -Value $Options.Collation)) }
    $instantFileInit = 'False'
    if ($Options.InstantFileInit) { $instantFileInit = 'True' }
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'SQLSVCINSTANTFILEINIT' -Value $instantFileInit))
    # TCP/IP is off by default on the Developer editions; a server needs it.
    $list.Add((ConvertTo-MssqlSetupArgument -Name 'TCPENABLED' -Value '1'))

    $pathArguments = [ordered]@{
        instance_dir = 'INSTANCEDIR'
        data_root = 'INSTALLSQLDATADIR'
        data = 'SQLUSERDBDIR'
        log = 'SQLUSERDBLOGDIR'
        backup = 'SQLBACKUPDIR'
        tempdb_data = 'SQLTEMPDBDIR'
        tempdb_log = 'SQLTEMPDBLOGDIR'
    }
    $tempdbArguments = [ordered]@{
        file_count = 'SQLTEMPDBFILECOUNT'
        file_size_mb = 'SQLTEMPDBFILESIZE'
        file_growth_mb = 'SQLTEMPDBFILEGROWTH'
        log_size_mb = 'SQLTEMPDBLOGFILESIZE'
        log_growth_mb = 'SQLTEMPDBLOGFILEGROWTH'
    }
    foreach ($group in @(@{ Values = $Options.Paths; Names = $pathArguments }, @{ Values = $Options.Tempdb; Names = $tempdbArguments })) {
        if ($null -eq $group.Values) { continue }
        foreach ($key in $group.Names.Keys) {
            $value = $group.Values[$key]
            if ($null -ne $value -and [string]$value -ne '') {
                $list.Add((ConvertTo-MssqlSetupArgument -Name $group.Names[$key] -Value ([string]$value)))
            }
        }
    }
    $list.ToArray()
}

Function Get-MssqlSetupArgumentProblem {
    <#
    .SYNOPSIS
    Returns why setup couldn't take one of the arguments ('' when it can): a
    value holding a double quote, which setup's command line has no escape
    for. A secret's value never appears in the message.
    #>
    [CmdletBinding()]
    param ([object[]]$Arguments)

    foreach ($argument in $Arguments) {
        foreach ($value in @($argument.Value)) {
            if ([string]$value -match '"') { return "Setup can't take a double quote in /$($argument.Name)" }
        }
    }
    ''
}

Function Format-MssqlSetupArgument {
    <#
    .SYNOPSIS
    Joins setup's arguments into its command line, every value quoted. A
    value's trailing backslashes are doubled, or the last would escape the
    closing quote. With Redact, a secret value reads ********.
    #>
    [CmdletBinding()]
    param ([object[]]$Arguments, [switch]$Redact)

    $parts = foreach ($argument in $Arguments) {
        if ($null -eq $argument.Value) {
            '/' + $argument.Name
            continue
        }
        $values = @($argument.Value)
        if ($Redact -and $argument.Secret) { $values = @('********') }
        $quoted = @($values | ForEach-Object { '"' + ([string]$_ -replace '(\\+)$', '$1$1') + '"' })
        '/{0}={1}' -f $argument.Name, ($quoted -join ' ')
    }
    $parts -join ' '
}

Function Get-MssqlServiceName {
    <#
    .SYNOPSIS
    Returns the Windows service name of an instance's engine, Agent or
    full-text launcher: MSSQLSERVER, SQLSERVERAGENT and MSSQLFDLauncher for
    the default instance; MSSQL$<name>, SQLAgent$<name> and
    MSSQLFDLauncher$<name> for a named one.
    #>
    [CmdletBinding()]
    param ([string]$InstanceName, [ValidateSet('engine', 'agent', 'fulltext')][string]$Service)

    $names = @{
        engine = @('MSSQLSERVER', 'MSSQL$')
        agent = @('SQLSERVERAGENT', 'SQLAgent$')
        fulltext = @('MSSQLFDLauncher', 'MSSQLFDLauncher$')
    }
    if ($InstanceName -eq 'MSSQLSERVER') { return $names[$Service][0] }
    $names[$Service][1] + $InstanceName
}

Function Get-MssqlConnectionString {
    <#
    .SYNOPSIS
    Returns a SqlClient connection string to an instance on this host over
    shared memory (lpc:), as the account the module runs as.
    #>
    [CmdletBinding()]
    param ([string]$InstanceName, [string]$HostName, [int]$Timeout = 15)

    $server = 'lpc:' + $HostName
    if ($InstanceName -ne 'MSSQLSERVER') { $server += '\' + $InstanceName }
    'Data Source={0};Integrated Security=SSPI;Connect Timeout={1};Application Name=git_cgallagher.windows' -f $server, $Timeout
}

Function Get-MssqlInstanceNameProblem {
    <#
    .SYNOPSIS
    Returns why setup would refuse an instance name ('' when it wouldn't):
    MSSQLSERVER is the default instance; a named instance takes 1 to 16
    letters, digits, _ and $, starting with a letter or _, and isn't Default.
    #>
    [CmdletBinding()]
    param ([string]$Name)

    if ($Name -eq 'MSSQLSERVER') { return '' }
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_$]{0,15}$' -or $Name -eq 'DEFAULT') {
        return ("instance_name '{0}' isn't a name setup takes: MSSQLSERVER for the default instance, or 1 to 16 " +
            'letters, digits, _ and $, starting with a letter or _') -f $Name
    }
    ''
}

Function Get-MssqlAccountProblem {
    <#
    .SYNOPSIS
    Returns what's wrong with a service account and its password ('' when
    nothing is). No account means setup's default virtual account. A gMSA
    (a name ending in $) and the built-in NT SERVICE\ and NT AUTHORITY\
    accounts take no password; any other account needs one. Option is the
    options' prefix (engine, agent).
    #>
    [CmdletBinding()]
    param ([string]$Option, [string]$Account, [bool]$HasPassword)

    if (-not $Account) {
        if ($HasPassword) { return "${Option}_password is set without ${Option}_account" }
        return ''
    }
    $passwordless = $Account.EndsWith('$') -or $Account -match '^NT (SERVICE|AUTHORITY)\\'
    if ($passwordless -and $HasPassword) {
        return "${Option}_account $Account is a gMSA or built-in account, which takes no password: leave ${Option}_password out"
    }
    if (-not $passwordless -and -not $HasPassword) {
        return "${Option}_account $Account needs ${Option}_password (a gMSA's name ends in `$)"
    }
    ''
}

Function Get-MssqlRebootPendingReason {
    <#
    .SYNOPSIS
    Lists why Windows has a reboot pending, from the registry's markers (each
    a bool in State): ComponentBasedServicing, WindowsUpdate, FileRenames
    (PendingFileRenameOperations) and ComputerRename. Setup refuses to run
    while any is set.
    #>
    [CmdletBinding()]
    param ([hashtable]$State)

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($State.ComponentBasedServicing) { $reasons.Add('Component Based Servicing has a reboot pending') }
    if ($State.WindowsUpdate) { $reasons.Add('Windows Update needs a reboot') }
    if ($State.FileRenames) { $reasons.Add('file renames wait for a reboot (PendingFileRenameOperations)') }
    if ($State.ComputerRename) { $reasons.Add('the computer was renamed and not yet rebooted') }
    $reasons.ToArray()
}

Function Get-MssqlSetupSummary {
    <#
    .SYNOPSIS
    Reads setup's Summary.txt: its final result and exit message, every
    feature or rule that failed with the reason setup gives, and the chain of
    exceptions in its exception summary (outermost first, each as its short
    type name and message), whose innermost usually names the cause. Setup's
    own exit code says little more than "failed", so the module reports
    these.
    #>
    [CmdletBinding()]
    param ([string]$Text)

    $summary = @{ FinalResult = ''; ExitMessage = ''; Failures = @(); Exceptions = @() }
    $failures = [System.Collections.Generic.List[string]]::new()
    $exceptions = [System.Collections.Generic.List[string]]::new()
    $current = ''
    $failed = $false
    $exceptionType = ''
    $wantMessage = $false
    foreach ($line in @($Text -split "`r?`n")) {
        # An exception's message is on the line after its "Message:".
        if ($wantMessage -and $line.Trim()) {
            $wantMessage = $false
            $entry = '{0}: {1}' -f $exceptionType, $line.Trim()
            if (-not $exceptions.Contains($entry)) { $exceptions.Add($entry) }
            continue
        }
        if ($line -match '^\s*(Inner )?exception type:\s*(.+?)\s*$') {
            $exceptionType = ($Matches[2] -split '\.')[-1]
            continue
        }
        if ($line -match '^\s*Message:\s*$') {
            $wantMessage = $exceptionType -ne ''
            continue
        }
        if ($line -notmatch '^\s*([^:]+?):\s+(.*?)\s*$') { continue }
        $key = $Matches[1].Trim()
        $value = $Matches[2]
        switch ($key) {
            'Final result' { if (-not $summary.FinalResult) { $summary.FinalResult = $value } }
            'Exit message' { if (-not $summary.ExitMessage) { $summary.ExitMessage = $value } }
            { $_ -in 'Feature', 'Rule name' } {
                $current = $value
                $failed = $false
            }
            { $_ -in 'Status', 'Result' } { $failed = $current -and $value -eq 'Failed' }
            { $_ -in 'Error description', 'Message/Corrective Action' } {
                if ($failed) {
                    $failures.Add(('{0}: {1}' -f $current, $value))
                    $failed = $false
                }
            }
        }
    }
    $summary.Failures = $failures.ToArray()
    $summary.Exceptions = $exceptions.ToArray()
    $summary
}

Function Get-MssqlSetupHint {
    <#
    .SYNOPSIS
    Returns what a known setup failure means, from the details the module
    reports (Get-MssqlSetupSummary's), or '' for one it doesn't know.
    #>
    [CmdletBinding()]
    param ([string[]]$Details, [string]$Account)

    $text = $Details -join ' '
    if ($text -match 'trusted for delegation|0x80090345') {
        return ("Setup encrypts the service passwords with DPAPI as {0}, the account it runs as. The first time a domain " +
            "account uses DPAPI on a host, Windows backs its new master key up to a writable domain controller, and " +
            'without one the key isn''t created (Microsoft KB 3205778): check this host reaches a writable domain ' +
            'controller of the account''s domain by its DNS name.') -f $Account
    }
    ''
}

Function ConvertTo-MssqlStartMode {
    <#
    .SYNOPSIS
    Returns a service start mode as the options name it (automatic, manual,
    disabled) from Win32_Service's StartMode (Auto, Manual, Disabled).
    #>
    [CmdletBinding()]
    param ([string]$StartMode)

    switch ($StartMode) {
        'Auto' { return 'automatic' }
        'Manual' { return 'manual' }
        'Disabled' { return 'disabled' }
    }
    ([string]$StartMode).ToLowerInvariant()
}

Function ConvertTo-MssqlInstanceFact {
    <#
    .SYNOPSIS
    Turns one instance as Get-MssqlInstanceRegistry and Get-MssqlServiceState
    read it into the facts the modules return: version, edition, features,
    collation, paths, clustering, TCP and its services. A registry value that
    isn't there reads as '' (or false).
    #>
    [CmdletBinding()]
    param ([hashtable]$Registry, [hashtable]$Services)

    $setup = $Registry.Setup
    if ($null -eq $setup) { $setup = @{} }
    $tcp = $Registry.Tcp
    if ($null -eq $tcp) { $tcp = @{} }
    $tcpAll = $Registry.TcpAll
    if ($null -eq $tcpAll) { $tcpAll = @{} }
    $netLib = $Registry.SuperSocketNetLib
    if ($null -eq $netLib) { $netLib = @{} }
    if ($null -eq $Services) { $Services = @{} }

    $serviceFacts = [ordered]@{}
    foreach ($kind in 'engine', 'agent', 'fulltext') {
        $serviceName = Get-MssqlServiceName -InstanceName $Registry.Name -Service $kind
        $service = $Services[$serviceName]
        $serviceFacts[$kind] = $null
        if ($null -ne $service) {
            $serviceFacts[$kind] = @{
                name = $serviceName
                state = ([string]$service.State).ToLowerInvariant()
                start_mode = ConvertTo-MssqlStartMode $service.StartMode
                account = [string]$service.Account
            }
        }
    }
    $installed = Get-MssqlInstalledFeature -ConfigurationState $Registry.ConfigurationState -FeatureList ([string]$setup['FeatureList']) `
        -HasFullTextService ($null -ne $serviceFacts.fulltext)
    $versionNumber = [string]$setup['PatchLevel']
    if (-not $versionNumber) { $versionNumber = [string]$setup['Version'] }
    @{
        name = $Registry.Name
        id = $Registry.Id
        version = ConvertTo-MssqlVersionName $Registry.Id
        version_number = $versionNumber
        edition = [string]$setup['Edition']
        edition_id = ConvertTo-MssqlEditionId ([string]$setup['Edition'])
        features = $installed.Features
        features_known = $installed.Known
        features_unknown = $installed.Unknown
        features_source = $installed.Source
        collation = [string]$setup['Collation']
        paths = @{
            program = [string]$setup['SQLPath']
            data_root = [string]$setup['SQLDataRoot']
            binn = [string]$setup['SQLBinRoot']
        }
        clustered = $null -ne $Registry.Cluster
        tcp = @{
            enabled = [string]$tcp['Enabled'] -eq '1'
            port = [string]$tcpAll['TcpPort']
            dynamic_ports = [string]$tcpAll['TcpDynamicPorts']
        }
        encryption = @{
            mode = ConvertTo-MssqlEncryptionMode -ForceEncryption $netLib['ForceEncryption'] -ForceStrict $netLib['ForceStrict']
            force_encryption = [string]$netLib['ForceEncryption'] -eq '1'
            force_strict = [string]$netLib['ForceStrict'] -eq '1'
            certificate = ConvertTo-MssqlThumbprint ([string]$netLib['Certificate'])
        }
        services = $serviceFacts
    }
}

Function Get-MssqlRegistryValue {
    <#
    .SYNOPSIS
    Returns a registry key's values as a hashtable, or $null when the key
    doesn't exist.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $key) { return $null }
    $values = @{}
    foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
    $values
}

Function Get-MssqlInstanceRegistry {
    <#
    .SYNOPSIS
    Reads every SQL Server instance the registry lists (Instance
    Names\SQL), with the keys under its instance ID that
    ConvertTo-MssqlInstanceFact reads. Reads only.
    #>
    [CmdletBinding()]
    param ([string]$Root = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server')

    $instances = [System.Collections.Generic.List[object]]::new()
    $names = Get-MssqlRegistryValue "$Root\Instance Names\SQL"
    if ($null -eq $names) { return $instances.ToArray() }
    foreach ($name in @($names.Keys | Sort-Object)) {
        $id = [string]$names[$name]
        $base = "$Root\$id"
        $instances.Add(@{
                Name = [string]$name
                Id = $id
                Setup = Get-MssqlRegistryValue "$base\Setup"
                ConfigurationState = Get-MssqlRegistryValue "$base\ConfigurationState"
                SuperSocketNetLib = Get-MssqlRegistryValue "$base\MSSQLServer\SuperSocketNetLib"
                Tcp = Get-MssqlRegistryValue "$base\MSSQLServer\SuperSocketNetLib\Tcp"
                TcpAll = Get-MssqlRegistryValue "$base\MSSQLServer\SuperSocketNetLib\Tcp\IPAll"
                Cluster = Get-MssqlRegistryValue "$base\Cluster"
            })
    }
    $instances.ToArray()
}

Function Get-MssqlRebootState {
    <#
    .SYNOPSIS
    Reads the registry's pending-reboot markers, for
    Get-MssqlRebootPendingReason. Reads only.
    #>
    [CmdletBinding()]
    param ()

    $control = 'HKLM:\SYSTEM\CurrentControlSet\Control'
    $renames = Get-ItemProperty -LiteralPath "$control\Session Manager" -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
    $active = Get-ItemProperty -LiteralPath "$control\ComputerName\ActiveComputerName" -Name ComputerName -ErrorAction SilentlyContinue
    $pending = Get-ItemProperty -LiteralPath "$control\ComputerName\ComputerName" -Name ComputerName -ErrorAction SilentlyContinue
    @{
        ComponentBasedServicing = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdate = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        FileRenames = $null -ne $renames -and @($renames.PendingFileRenameOperations | Where-Object { $_ }).Count -gt 0
        ComputerRename = $null -ne $active -and $null -ne $pending -and [string]$active.ComputerName -ne [string]$pending.ComputerName
    }
}

Function Get-MssqlServiceState {
    <#
    .SYNOPSIS
    Reads the named services (Win32_Service): state, start mode and account,
    by service name. A service that doesn't exist is left out. Reads only.
    #>
    [CmdletBinding()]
    param ([string[]]$Name)

    $services = @{}
    foreach ($serviceName in $Name) {
        $filter = "Name='{0}'" -f ($serviceName -replace "'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $services[$serviceName] = @{ State = [string]$service.State; StartMode = [string]$service.StartMode; Account = [string]$service.StartName }
        }
    }
    $services
}

Function ConvertTo-MssqlThumbprint {
    <#
    .SYNOPSIS
    Returns a certificate thumbprint the way SQL Server's Certificate registry
    value holds it: lowercase hex, without the spaces and invisible marks a
    thumbprint copied from the certificate dialog carries.
    #>
    [CmdletBinding()]
    param ([string]$Thumbprint)

    ([string]$Thumbprint -replace '[\s\p{Cf}]', '').ToLowerInvariant()
}

Function Get-MssqlThumbprintProblem {
    <#
    .SYNOPSIS
    Returns why a value isn't a certificate thumbprint (a SHA-1 hash: 40 hex
    digits, spaces allowed), or '' when it is one.
    #>
    [CmdletBinding()]
    param ([string]$Thumbprint)

    if ((ConvertTo-MssqlThumbprint $Thumbprint) -notmatch '^[0-9a-f]{40}$') {
        return "certificate_thumbprint must be a certificate's SHA-1 thumbprint, 40 hex digits; got '$Thumbprint'"
    }
    ''
}

Function ConvertTo-MssqlEncryptionMode {
    <#
    .SYNOPSIS
    Names the encryption mode SuperSocketNetLib's flags set: strict (Force
    Strict Encryption), mandatory (Force Encryption) or optional (neither).
    #>
    [CmdletBinding()]
    param ([object]$ForceEncryption, [object]$ForceStrict)

    if ([string]$ForceStrict -eq '1') { return 'strict' }
    if ([string]$ForceEncryption -eq '1') { return 'mandatory' }
    'optional'
}

Function Get-MssqlStrictNotice {
    <#
    .SYNOPSIS
    What turning strict encryption on costs, as the mssql lab showed on SQL
    Server 2022 RTM: every client without TDS 8.0 is refused, over shared
    memory as well as TCP, .NET Framework's System.Data.SqlClient among them,
    and on 2022 SQL Server Agent too, which then stops (2025's Agent speaks
    TDS 8.0).
    #>
    [CmdletBinding()]
    param ([string]$Version)

    $notice = ('Strict encryption refuses every client without TDS 8.0, over shared memory as well as TCP: .NET ' +
        "Framework's System.Data.SqlClient among them, so this collection's modules can't connect to the instance")
    if ($Version -eq '2022') {
        $notice += ", and SQL Server 2022's SQL Server Agent, which stops (2025's Agent supports strict)"
    }
    $notice
}

Function Get-MssqlNetworkPlan {
    <#
    .SYNOPSIS
    Compares an instance's network registry values with the desired TCP port,
    certificate and encryption mode. Returns the writes that make them match
    (Changes: each with the Key it goes under, Tcp, TcpAll or NetLib, and the
    value's Name, Value, default Kind and a Description) and what it leaves
    alone but should say (Notices). A desired value that is $null or '' is
    left as it is.
    .PARAMETER Current
    The values as read: TcpEnabled and ListenOnAllIPs (the Tcp key), TcpPort
    and TcpDynamicPorts (Tcp\IPAll), ForceEncryption, ForceStrict and
    Certificate (SuperSocketNetLib).
    .PARAMETER Desired
    TcpPort (an int), Encryption (optional, mandatory or strict) and
    Thumbprint.
    #>
    [CmdletBinding()]
    param ([hashtable]$Current, [hashtable]$Desired)

    $changes = [System.Collections.Generic.List[object]]::new()
    $notices = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $Desired.TcpPort) {
        $port = [string][int]$Desired.TcpPort
        if ([string]$Current.TcpEnabled -ne '1') {
            $changes.Add(@{ Key = 'Tcp'; Name = 'Enabled'; Value = 1; Kind = 'DWord'; Description = 'enable TCP/IP' })
        }
        if ([string]$Current.TcpPort -ne $port) {
            $changes.Add(@{
                    Key = 'TcpAll'; Name = 'TcpPort'; Value = $port; Kind = 'String'
                    Description = "listen on TCP port $port (was '$($Current.TcpPort)')"
                })
        }
        if ([string]$Current.TcpDynamicPorts -ne '') {
            $changes.Add(@{
                    Key = 'TcpAll'; Name = 'TcpDynamicPorts'; Value = ''; Kind = 'String'
                    Description = "turn dynamic ports off (was '$($Current.TcpDynamicPorts)')"
                })
        }
        if ([string]$Current.ListenOnAllIPs -eq '0') {
            $notices.Add(("TCP/IP's Listen All is off, so SQL Server ignores the IPAll port this sets and listens on the " +
                    'ports of each address (IP1, IP2, ...) instead; turn Listen All on to use it'))
        }
    }
    if ($Desired.Thumbprint) {
        $thumbprint = ConvertTo-MssqlThumbprint $Desired.Thumbprint
        if ((ConvertTo-MssqlThumbprint $Current.Certificate) -ne $thumbprint) {
            $was = ConvertTo-MssqlThumbprint $Current.Certificate
            if (-not $was) { $was = 'none' }
            $changes.Add(@{
                    Key = 'NetLib'; Name = 'Certificate'; Value = $thumbprint; Kind = 'String'
                    Description = "bind certificate $thumbprint (was $was)"
                })
        }
    }
    if ($Desired.Encryption) {
        $flags = @{ optional = @(0, 0); mandatory = @(1, 0); strict = @(0, 1) }[[string]$Desired.Encryption]
        $names = @(@('ForceEncryption', 'Force Encryption'), @('ForceStrict', 'Force Strict Encryption'))
        for ($i = 0; $i -lt 2; $i++) {
            $now = 0
            if ([string]$Current[$names[$i][0]] -eq '1') { $now = 1 }
            if ($now -ne $flags[$i]) {
                $state = @('off', 'on')[$flags[$i]]
                $changes.Add(@{
                        Key = 'NetLib'; Name = $names[$i][0]; Value = $flags[$i]; Kind = 'DWord'
                        Description = "turn $($names[$i][1]) $state (encryption $($Desired.Encryption))"
                    })
            }
        }
    }
    @{ Changes = $changes.ToArray(); Notices = $notices.ToArray() }
}

Function Get-MssqlCertificateProblem {
    <#
    .SYNOPSIS
    Checks a certificate, as the module reads it from the computer's personal
    store, against what SQL Server needs to load it (Microsoft's "Certificate
    requirements for SQL Server"): valid now, for server authentication, with
    a private key in a legacy CSP, in the computer's key store, as a key
    exchange key (KeySpec 1, AT_KEYEXCHANGE). Returns the first problem, or
    ''.
    .PARAMETER Certificate
    Thumbprint, Found, NotBefore, NotAfter, ServerAuth, HasPrivateKey,
    KeyProvider ('csp' or 'ksp'), MachineKey and KeySpec.
    #>
    [CmdletBinding()]
    param ([hashtable]$Certificate, [datetime]$Now = (Get-Date))

    $thumbprint = $Certificate.Thumbprint
    if (-not $Certificate.Found) {
        return "certificate $thumbprint isn't in the computer's personal store (Cert:\LocalMachine\My)"
    }
    if ($Now -lt $Certificate.NotBefore -or $Now -gt $Certificate.NotAfter) {
        return ('certificate {0} is valid from {1:u} to {2:u}, not now' -f $thumbprint, $Certificate.NotBefore, $Certificate.NotAfter)
    }
    if (-not $Certificate.ServerAuth) {
        return "certificate $thumbprint isn't for server authentication: its enhanced key usage lacks Server Authentication (1.3.6.1.5.5.7.3.1)"
    }
    if (-not $Certificate.HasPrivateKey) {
        return "certificate $thumbprint has no private key on this host"
    }
    if ($Certificate.KeyProvider -ne 'csp') {
        return ("certificate $thumbprint's private key is in a key storage provider (CNG), which SQL Server can't use: issue it " +
            'with a legacy CSP, such as Microsoft RSA SChannel Cryptographic Provider, as a key exchange key')
    }
    if (-not $Certificate.MachineKey) {
        return "certificate $thumbprint's private key is in a user's key store, not the computer's, so SQL Server's service can't read it"
    }
    if ([int]$Certificate.KeySpec -ne 1) {
        return "certificate $thumbprint's private key has KeySpec $($Certificate.KeySpec); SQL Server needs a key exchange key (KeySpec 1, AT_KEYEXCHANGE)"
    }
    ''
}

Function Get-MssqlCertificateNameNotice {
    <#
    .SYNOPSIS
    Returns a notice when none of a certificate's DNS names (its subject
    alternative names, else its subject's CN) covers the host's name, which
    clients that check the certificate connect by; '' when one does. A
    wildcard covers one label.
    #>
    [CmdletBinding()]
    param ([string[]]$DnsNames, [string]$HostName, [string]$Thumbprint)

    $hostLower = ([string]$HostName).ToLowerInvariant()
    foreach ($name in @($DnsNames | Where-Object { $_ })) {
        $pattern = ([string]$name).ToLowerInvariant()
        if ($pattern -eq $hostLower) { return '' }
        $dot = $hostLower.IndexOf('.')
        if ($pattern.StartsWith('*.') -and $dot -gt 0 -and $hostLower.Substring($dot) -eq $pattern.Substring(1)) { return '' }
    }
    $names = @($DnsNames | Where-Object { $_ }) -join ', '
    if (-not $names) { $names = 'no DNS name' }
    $notice = "certificate $Thumbprint names $names, not ${HostName}: clients that check the certificate (strict always does) "
    $notice + 'connect only by a name it covers'
}

Function Test-MssqlReadRight {
    <#
    .SYNOPSIS
    Whether an access rule's rights let its holder read a file: Read or more,
    or the GENERIC_READ or GENERIC_ALL bits an ACE can hold instead.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ([long]$Rights)

    $mask = $Rights -band 0xFFFFFFFFL
    (($mask -band 0x20089L) -eq 0x20089L) -or (($mask -band 0x80000000L) -ne 0) -or (($mask -band 0x10000000L) -ne 0)
}

Function Get-MssqlErrorLogPath {
    <#
    .SYNOPSIS
    Returns the errorlog's path from the engine's startup parameters (the
    instance's MSSQLServer\Parameters values SQLArg0, SQLArg1, ...): the one
    that starts with -e. '' without one.
    #>
    [CmdletBinding()]
    param ([hashtable]$Parameters)

    if ($null -eq $Parameters) { return '' }
    foreach ($name in @($Parameters.Keys | Where-Object { $_ -match '^SQLArg\d+$' } | Sort-Object)) {
        $value = [string]$Parameters[$name]
        if ($value -match '^-e(.+)$') { return $Matches[1] }
    }
    ''
}

Function Get-MssqlErrorLogFact {
    <#
    .SYNOPSIS
    Reads what the current errorlog says about the engine's last start: its
    process ID, the certificate it loaded for encryption (a thumbprint,
    'self-generated', or '' before that line), the TCP ports it listens on
    for every address, and whether it got as far as "ready for client
    connections". Lines that mention strict encryption or TDS 8.0 are kept as
    they are.
    #>
    [CmdletBinding()]
    param ([string[]]$Lines)

    $processId = 0
    $certificate = ''
    $ports = [System.Collections.Generic.List[int]]::new()
    $strict = [System.Collections.Generic.List[string]]::new()
    $ready = $false
    foreach ($line in @($Lines)) {
        if ($line -match 'Server process ID is (\d+)') {
            $processId = [int]$Matches[1]
        }
        elseif ($line -match 'The certificate \[Cert Hash\(sha1\) "([0-9A-Fa-f]{40})"\] was successfully loaded for encryption') {
            $certificate = $Matches[1].ToLowerInvariant()
        }
        elseif ($line -match 'A self-generated certificate was successfully loaded for encryption') {
            $certificate = 'self-generated'
        }
        elseif ($line -match "Server is listening on \[ 'any' <ipv[46]> (\d+)\]") {
            $port = [int]$Matches[1]
            if (-not $ports.Contains($port)) { $ports.Add($port) }
        }
        elseif ($line -match 'SQL Server is now ready for client connections') {
            $ready = $true
        }
        if ($line -match '(?i)strict|TDS 8') { $strict.Add($line.Trim()) }
    }
    @{ ProcessId = $processId; Certificate = $certificate; Ports = $ports.ToArray(); Ready = $ready; StrictLines = $strict.ToArray() }
}

Function Get-MssqlFirewallRuleSpec {
    <#
    .SYNOPSIS
    The inbound firewall rules an instance needs: its TCP ports, and for a
    named instance SQL Server Browser's UDP 1434, which clients ask for a
    named instance's port. Each rule has the Name (its ID) the module finds it
    by.
    #>
    [CmdletBinding()]
    param ([string]$InstanceName, [string[]]$Ports)

    $group = 'SQL Server (git_cgallagher.windows)'
    $rules = [System.Collections.Generic.List[object]]::new()
    $rules.Add(@{
            Name = "mssql-iac-$InstanceName-tcp"
            DisplayName = "SQL Server ($InstanceName) TCP $($Ports -join ', ')"
            Group = $group
            Protocol = 'TCP'
            LocalPort = @($Ports)
        })
    if ($InstanceName -ne 'MSSQLSERVER') {
        $rules.Add(@{
                Name = 'mssql-iac-browser-udp'
                DisplayName = 'SQL Server Browser UDP 1434'
                Group = $group
                Protocol = 'UDP'
                LocalPort = @('1434')
            })
    }
    $rules.ToArray()
}

Function Get-MssqlFirewallRuleDifference {
    <#
    .SYNOPSIS
    Returns what an existing firewall rule has that its spec doesn't (an
    enabled inbound allow rule for every profile, with the spec's display
    name, protocol and ports), as text, or '' when it matches.
    #>
    [CmdletBinding()]
    param ([hashtable]$Spec, [hashtable]$Rule)

    $differences = [System.Collections.Generic.List[string]]::new()
    $expected = [ordered]@{
        DisplayName = $Spec.DisplayName
        Enabled = 'True'
        Direction = 'Inbound'
        Action = 'Allow'
        Profile = 'Any'
        Protocol = $Spec.Protocol
    }
    foreach ($name in $expected.Keys) {
        if ([string]$Rule[$name] -ne [string]$expected[$name]) { $differences.Add(("{0} '{1}'" -f $name, $Rule[$name])) }
    }
    $have = @($Rule.LocalPort | ForEach-Object { [string]$_ } | Sort-Object)
    $want = @($Spec.LocalPort | ForEach-Object { [string]$_ } | Sort-Object)
    if (($have -join ',') -ne ($want -join ',')) { $differences.Add(("ports '{0}'" -f ($have -join ', '))) }
    $differences -join ', '
}

Function Get-MssqlServiceSidName {
    <#
    .SYNOPSIS
    Returns the engine's per-service SID as an account name (NT
    SERVICE\MSSQLSERVER, NT SERVICE\MSSQL$INST1), which SQL Server's service
    carries whatever account it logs on as.
    #>
    [CmdletBinding()]
    param ([string]$InstanceName)

    'NT SERVICE\' + (Get-MssqlServiceName -InstanceName $InstanceName -Service 'engine')
}

Function Test-MssqlRestartPending {
    <#
    .SYNOPSIS
    Whether settings written without a restart are still waiting for one: the
    time they were written is after the running engine's start. No time, or
    an engine that isn't running, means nothing waits.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ([object]$ChangedAt, [object]$StartedAt)

    if ($null -eq $ChangedAt -or $null -eq $StartedAt) { return $false }
    [datetime]$ChangedAt -gt [datetime]$StartedAt
}

Function Invoke-MssqlQuery {
    <#
    .SYNOPSIS
    Runs one query through System.Data.SqlClient and returns its rows as
    ordered hashtables (DBNull as $null). Parameters become @name query
    parameters, never text in the query.
    #>
    [CmdletBinding()]
    param ([string]$ConnectionString, [string]$Query, [hashtable]$Parameters = @{}, [int]$Timeout = 30)

    Add-Type -AssemblyName System.Data
    $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $Timeout
        foreach ($key in $Parameters.Keys) { $null = $command.Parameters.AddWithValue('@' + $key, $Parameters[$key]) }
        $reader = $command.ExecuteReader()
        $rows = [System.Collections.Generic.List[object]]::new()
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $value = $reader.GetValue($i)
                if ($value -is [System.DBNull]) { $value = $null }
                $row[$reader.GetName($i)] = $value
            }
            $rows.Add($row)
        }
        $reader.Close()
        $rows.ToArray()
    }
    finally {
        $connection.Dispose()
    }
}

Function Invoke-MssqlNonQuery {
    <#
    .SYNOPSIS
    Runs a batch that returns no rows (sp_configure, RECONFIGURE, ALTER
    DATABASE) through System.Data.SqlClient. Parameters become @name query
    parameters, never text in the batch. An error anywhere in the batch
    throws.
    #>
    [CmdletBinding()]
    param ([string]$ConnectionString, [string]$Query, [hashtable]$Parameters = @{}, [int]$Timeout = 30)

    Add-Type -AssemblyName System.Data
    $connection = New-Object -TypeName System.Data.SqlClient.SqlConnection -ArgumentList $ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $Timeout
        foreach ($key in $Parameters.Keys) { $null = $command.Parameters.AddWithValue('@' + $key, $Parameters[$key]) }
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $connection.Dispose()
    }
}

Function ConvertTo-MssqlStringLiteral {
    <#
    .SYNOPSIS
    Returns a value as a T-SQL Unicode string literal, N'...' with each
    single quote doubled, for the statements that take no parameters (ALTER
    DATABASE's file names and paths).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param ([string]$Value)

    "N'" + ([string]$Value).Replace("'", "''") + "'"
}

Function ConvertTo-MssqlConfigValue {
    <#
    .SYNOPSIS
    Returns an sp_configure value as a whole number: an integer, a string of
    one, a float without a fraction, or a boolean (true is 1, false 0).
    $null for anything else, which the caller refuses.
    #>
    [CmdletBinding()]
    param ([object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return [long][int]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint32]) { return [long]$Value }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $number = [double]$Value
        if ([math]::Floor($number) -eq $number -and [math]::Abs($number) -lt 1e15) { return [long]$number }
        return $null
    }
    if ($Value -is [string] -and $Value.Trim() -match '^[+-]?\d{1,18}$') { return [long]$Value.Trim() }
    $null
}

Function Test-MssqlConfigValueInUse {
    <#
    .SYNOPSIS
    Whether sys.configurations shows an option's value in use. Two options
    show another value_in_use by design, as Microsoft's "Server configuration
    options" page documents: min server memory (MB) set to 0 shows 8 (32-bit)
    or 16 (64-bit), and max server memory (MB) set to 0 shows 2147483647.
    Comparing value with value_in_use alone calls min server memory's default
    waiting on every instance (the lab's SQL Server 2022 showed 0 and 16).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param ([string]$Name, [long]$Value, [long]$InUse)

    if ($Value -eq $InUse) { return $true }
    if ($Value -ne 0) { return $false }
    if ($Name -eq 'min server memory (MB)') { return $InUse -eq 8 -or $InUse -eq 16 }
    if ($Name -eq 'max server memory (MB)') { return $InUse -eq 2147483647 }
    $false
}

Function Get-MssqlConfigurationPlan {
    <#
    .SYNOPSIS
    Compares the sp_configure values asked for with sys.configurations and
    decides the changes. An option is matched by its whole name, ignoring
    case.
    .DESCRIPTION
    Returns a hashtable:
    - Problems: refusals (an option the instance doesn't have, one listed
      twice, a value that isn't a whole number or is outside the option's
      range, min server memory above max server memory).
    - Changes: Name (as the instance spells it), Value, Was, Dynamic,
      Advanced and Description, for each option whose value differs, and
      each dynamic one whose value isn't in use (set without RECONFIGURE;
      Test-MssqlConfigValueInUse decides, since two options show another
      value in use by design).
      By name, then max and min server memory in the order that never puts
      min above max on the way. 'show advanced options' is among them when
      it's asked for and differs, but the batch sets it through AdvancedOn
      and AdvancedOff.
    - AdvancedOn: turn 'show advanced options' on before the changes (an
      advanced option is among them, or it's asked for on).
    - AdvancedOff: turn it off after them (it must end off, and the batch
      turned it on, or it's asked for off).
    - ShowAdvancedWas: its value before, which a failed batch puts back.
    - Restart: the static options asked for whose value in use won't be the
      one asked for until the engine restarts (changed now, or before and
      still waiting).
    - Pending: options not asked for whose value isn't in use: Name, Value,
      InUse, Dynamic.
    - Notices: max server memory at or above the host's memory.
    .PARAMETER Current
    sys.configurations' rows: name, value, value_in_use, minimum, maximum,
    is_dynamic, is_advanced.
    .PARAMETER Desired
    Option name to value, as the module's sp_configure option holds them.
    .PARAMETER PhysicalMemoryMb
    The host's memory, for the max server memory notice; 0 skips it.
    #>
    [CmdletBinding()]
    param ([object[]]$Current, [System.Collections.IDictionary]$Desired, [long]$PhysicalMemoryMb = 0)

    $problems = [System.Collections.Generic.List[string]]::new()
    $notices = [System.Collections.Generic.List[string]]::new()
    $plan = @{
        Problems = @(); Changes = @(); AdvancedOn = $false; AdvancedOff = $false; ShowAdvancedWas = 0
        Restart = @(); Pending = @(); Notices = @()
    }
    $rows = @{}
    foreach ($row in @($Current)) { $rows[([string]$row.name).ToLowerInvariant()] = $row }

    # The options asked for, by lower-case name: the row and the value.
    $wanted = @{}
    $seen = @{}
    if ($null -ne $Desired) {
        foreach ($key in @($Desired.Keys | Sort-Object)) {
            $name = [string]$key
            $row = $rows[$name.ToLowerInvariant()]
            if ($null -eq $row) {
                $problems.Add("sp_configure has no option '$name' on this instance")
                continue
            }
            $lower = ([string]$row.name).ToLowerInvariant()
            if ($seen.ContainsKey($lower)) {
                $problems.Add("sp_configure option '$($row.name)' is listed twice")
                continue
            }
            $seen[$lower] = $true
            $value = ConvertTo-MssqlConfigValue $Desired[$key]
            if ($null -eq $value) {
                $problems.Add(("sp_configure option '{0}' takes a whole number, got '{1}'" -f $row.name, $Desired[$key]))
                continue
            }
            if ($value -lt [long]$row.minimum -or $value -gt [long]$row.maximum) {
                $problems.Add(("sp_configure option '{0}' takes {1} to {2}, got {3}" -f $row.name, $row.minimum, $row.maximum, $value))
                continue
            }
            $wanted[$lower] = @{ Row = $row; Value = $value }
        }
    }

    # Min server memory can't end above max server memory.
    $minKey = 'min server memory (mb)'
    $maxKey = 'max server memory (mb)'
    if (($wanted.ContainsKey($minKey) -or $wanted.ContainsKey($maxKey)) -and $rows.ContainsKey($minKey) -and $rows.ContainsKey($maxKey)) {
        $min = [long]$rows[$minKey].value
        $max = [long]$rows[$maxKey].value
        if ($wanted.ContainsKey($minKey)) { $min = $wanted[$minKey].Value }
        if ($wanted.ContainsKey($maxKey)) { $max = $wanted[$maxKey].Value }
        if ($min -gt $max) { $problems.Add("min server memory (MB) would be $min, above max server memory (MB)'s $max") }
    }
    if ($PhysicalMemoryMb -gt 0 -and $wanted.ContainsKey($maxKey) -and $wanted[$maxKey].Value -ge $PhysicalMemoryMb) {
        $notice = 'max server memory (MB) is {0}, at least the host''s {1} MB of memory, so SQL Server may leave Windows none'
        $notices.Add(($notice -f $wanted[$maxKey].Value, $PhysicalMemoryMb))
    }
    $plan.Notices = $notices.ToArray()
    $plan.Problems = $problems.ToArray()
    if ($problems.Count -gt 0) { return $plan }

    $found = [System.Collections.Generic.List[object]]::new()
    $restart = [System.Collections.Generic.List[string]]::new()
    foreach ($lower in @($wanted.Keys | Sort-Object)) {
        $row = $wanted[$lower].Row
        $value = $wanted[$lower].Value
        $configured = [long]$row.value
        $inUse = [long]$row.value_in_use
        $dynamic = [bool]$row.is_dynamic
        $valueInUse = Test-MssqlConfigValueInUse -Name $row.name -Value $value -InUse $inUse
        $text = ''
        if ($configured -ne $value) {
            $text = "set '$($row.name)' to $value (was $configured)"
            if (-not $dynamic) { $text += ', which takes effect when the engine restarts' }
        }
        elseif ($dynamic -and -not $valueInUse) {
            $text = "put '$($row.name)' = $value in use with RECONFIGURE (in use: $inUse)"
        }
        if ($text) {
            $found.Add(@{
                    Name = [string]$row.name; Value = $value; Was = $configured; Dynamic = $dynamic; Advanced = [bool]$row.is_advanced
                    Description = $text
                })
        }
        if (-not $dynamic -and -not $valueInUse) { $restart.Add([string]$row.name) }
    }

    # Max server memory first when it rises, min first when max falls.
    $memoryNames = @('max server memory (MB)', 'min server memory (MB)')
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($found | Where-Object { $memoryNames -notcontains $_.Name })) { $ordered.Add($item) }
    $maxItems = @($found | Where-Object { $_.Name -eq 'max server memory (MB)' })
    $minItems = @($found | Where-Object { $_.Name -eq 'min server memory (MB)' })
    $memoryItems = @($maxItems) + @($minItems)
    if ($maxItems.Count -gt 0 -and $maxItems[0].Value -lt $maxItems[0].Was) { $memoryItems = @($minItems) + @($maxItems) }
    foreach ($item in $memoryItems) { $ordered.Add($item) }

    # 'show advanced options': on for the advanced changes (or when asked
    # for), and off again at the end when it must end off.
    $showKey = 'show advanced options'
    $showValue = 0
    $showInUse = 0
    if ($rows.ContainsKey($showKey)) {
        $showValue = [long]$rows[$showKey].value
        $showInUse = [long]$rows[$showKey].value_in_use
    }
    $showAsked = $wanted.ContainsKey($showKey)
    $showFinal = $showValue
    if ($showAsked) { $showFinal = $wanted[$showKey].Value }
    $showOn = $showValue -eq 1 -and $showInUse -eq 1
    $showOff = $showValue -eq 0 -and $showInUse -eq 0
    $needAdvanced = @($ordered | Where-Object { $_.Advanced -and $_.Name -ne $showKey }).Count -gt 0
    $plan.AdvancedOn = (-not $showOn) -and ($needAdvanced -or ($showAsked -and $showFinal -eq 1))
    $plan.AdvancedOff = $showFinal -eq 0 -and ($plan.AdvancedOn -or ($showAsked -and -not $showOff))
    $plan.ShowAdvancedWas = $showValue

    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($lower in @($rows.Keys | Sort-Object)) {
        if ($wanted.ContainsKey($lower)) { continue }
        $row = $rows[$lower]
        if (-not (Test-MssqlConfigValueInUse -Name $row.name -Value $row.value -InUse $row.value_in_use)) {
            $pending.Add(@{ Name = [string]$row.name; Value = [long]$row.value; InUse = [long]$row.value_in_use; Dynamic = [bool]$row.is_dynamic })
        }
    }
    $plan.Changes = $ordered.ToArray()
    $plan.Restart = $restart.ToArray()
    $plan.Pending = $pending.ToArray()
    $plan
}

Function Get-MssqlConfigurationBatch {
    <#
    .SYNOPSIS
    Builds the T-SQL batch that makes a configuration plan's changes
    (Get-MssqlConfigurationPlan): 'show advanced options' on when AdvancedOn
    says so, each change through sp_configure followed by RECONFIGURE, then
    'show advanced options' off when AdvancedOff says so. When a statement
    fails, the batch puts back the option it was setting and 'show advanced
    options', then fails with the option's name and SQL Server's message.
    Names and values go in as parameters (@name0, @value0, @was0, ...,
    @show_was), never as text. Returns Text and Parameters, or $null when the
    plan changes nothing.
    #>
    [CmdletBinding()]
    param ([hashtable]$Plan)

    $items = @($Plan.Changes | Where-Object { $_.Name -ne 'show advanced options' })
    if ($items.Count -eq 0 -and -not $Plan.AdvancedOn -and -not $Plan.AdvancedOff) { return $null }
    $parameters = @{ show_was = [int]$Plan.ShowAdvancedWas }
    $show = "EXEC sys.sp_configure @configname = N'show advanced options', @configvalue = {0};"
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('SET NOCOUNT ON;')
    $lines.Add('DECLARE @step int = -1;')
    $lines.Add('BEGIN TRY')
    if ($Plan.AdvancedOn) {
        $lines.Add('    ' + ($show -f 1))
        $lines.Add('    RECONFIGURE;')
    }
    for ($i = 0; $i -lt $items.Count; $i++) {
        $parameters["name$i"] = [string]$items[$i].Name
        $parameters["value$i"] = [int]$items[$i].Value
        $parameters["was$i"] = [int]$items[$i].Was
        $lines.Add("    SET @step = $i;")
        $lines.Add("    EXEC sys.sp_configure @configname = @name$i, @configvalue = @value$i;")
        $lines.Add('    RECONFIGURE;')
    }
    $lines.Add('    SET @step = -1;')
    if ($Plan.AdvancedOff) {
        $lines.Add('    ' + ($show -f 0))
        $lines.Add('    RECONFIGURE;')
    }
    $lines.Add('END TRY')
    $lines.Add('BEGIN CATCH')
    $lines.Add('    DECLARE @message nvarchar(2048) = ERROR_MESSAGE();')
    $lines.Add("    DECLARE @failed nvarchar(128) = N'';")
    $lines.Add('    BEGIN TRY')
    for ($i = 0; $i -lt $items.Count; $i++) {
        $lines.Add("        IF @step = $i")
        $lines.Add('        BEGIN')
        $lines.Add("            SET @failed = @name$i;")
        $lines.Add("            EXEC sys.sp_configure @configname = @name$i, @configvalue = @was$i;")
        $lines.Add('            RECONFIGURE;')
        $lines.Add('        END;')
    }
    if ($Plan.AdvancedOn -or $Plan.AdvancedOff) {
        $lines.Add("        EXEC sys.sp_configure @configname = N'show advanced options', @configvalue = @show_was;")
        $lines.Add('        RECONFIGURE;')
    }
    $lines.Add('    END TRY')
    $lines.Add('    BEGIN CATCH')
    $lines.Add('        SET @step = -1;')
    $lines.Add('    END CATCH;')
    $lines.Add("    IF @failed <> N'' SET @message = N'sp_configure option ''' + @failed + N''': ' + @message;")
    $lines.Add('    THROW 50000, @message, 1;')
    $lines.Add('END CATCH;')
    @{ Text = $lines -join "`r`n"; Parameters = $parameters }
}

Function Get-MssqlTempdbProblem {
    <#
    .SYNOPSIS
    Returns what's wrong with the tempdb values asked for ('' when nothing
    is): file_count and the sizes start at 1, the growth at 0 (no growth).
    Desired holds FileCount, FileSizeMb, FileGrowthMb, LogSizeMb and
    LogGrowthMb, each $null when not asked for.
    #>
    [CmdletBinding()]
    param ([hashtable]$Desired)

    $least = [ordered]@{ FileCount = 1; FileSizeMb = 1; LogSizeMb = 1; FileGrowthMb = 0; LogGrowthMb = 0 }
    $options = @{
        FileCount = 'file_count'; FileSizeMb = 'file_size_mb'; LogSizeMb = 'log_size_mb'; FileGrowthMb = 'file_growth_mb'; LogGrowthMb = 'log_growth_mb'
    }
    foreach ($key in $least.Keys) {
        $value = $Desired[$key]
        if ($null -ne $value -and [long]$value -lt $least[$key]) {
            return ('tempdb.{0} must be {1} or more, got {2}' -f $options[$key], $least[$key], $value)
        }
    }
    ''
}

Function Get-MssqlTempdbPlan {
    <#
    .SYNOPSIS
    Compares tempdb's files with the sizes, growth and number of data files
    asked for. Returns Changes (each an ALTER DATABASE Statement and its
    Description, in order) and Notices for what it leaves alone. It grows a
    file below the size asked for but never shrinks one, sets each file's
    growth in MB, and adds data files (temp<N> in tempdb_mssql_<N>.ndf
    beside the first data file, as setup names them) but never removes one.
    SQL Server grows a file only past its current size, so a file that has
    grown past the size asked for keeps the size tempdb starts with until a
    restart shrinks it back.
    .PARAMETER Files
    tempdb's files from sys.master_files (database_id 2): file_id, name, type
    (ROWS or LOG), path, size_mb (the size tempdb starts with),
    current_size_mb (from tempdb.sys.database_files), growth_mb ($null when
    it grows by a percentage) and growth_percent.
    .PARAMETER Desired
    FileCount, FileSizeMb, FileGrowthMb, LogSizeMb and LogGrowthMb; one that
    is $null is left alone.
    #>
    [CmdletBinding()]
    param ([object[]]$Files, [hashtable]$Desired)

    $changes = [System.Collections.Generic.List[object]]::new()
    $notices = [System.Collections.Generic.List[string]]::new()
    $data = @($Files | Where-Object { [string]$_.type -eq 'ROWS' } | Sort-Object -Property { [int]$_.file_id })
    $logs = @($Files | Where-Object { [string]$_.type -eq 'LOG' } | Sort-Object -Property { [int]$_.file_id })
    $groups = @(
        @{ Files = $data; Kind = 'data'; Size = $Desired.FileSizeMb; Growth = $Desired.FileGrowthMb; Option = 'file_size_mb' }
        @{ Files = $logs; Kind = 'log'; Size = $Desired.LogSizeMb; Growth = $Desired.LogGrowthMb; Option = 'log_size_mb' }
    )
    foreach ($group in $groups) {
        foreach ($file in $group.Files) {
            $nameLiteral = ConvertTo-MssqlStringLiteral $file.name
            $label = "tempdb $($group.Kind) file '$($file.name)'"
            if ($null -ne $group.Size) {
                $size = [long]$group.Size
                $startSize = [long]$file.size_mb
                $currentSize = [long]$file.current_size_mb
                if ($startSize -gt $size) {
                    $notices.Add(('{0} is set to {1} MB, more than {2}''s {3} MB: the module never shrinks tempdb' -f $label, $startSize, $group.Option, $size))
                }
                elseif ($startSize -lt $size -and $currentSize -ge $size) {
                    $notice = ("{0} has grown to {1} MB, so SQL Server won't set its size to {2}'s {3} MB: it stays at {4} MB, " +
                        'the size a restart brings it back to; run again after one') -f $label, $currentSize, $group.Option, $size, $startSize
                    $notices.Add($notice)
                }
                elseif ($startSize -lt $size) {
                    $changes.Add(@{
                            Statement = "ALTER DATABASE [tempdb] MODIFY FILE (NAME = $nameLiteral, SIZE = ${size}MB);"
                            Description = "grow $label to $size MB (was $startSize MB)"
                        })
                }
            }
            if ($null -ne $group.Growth) {
                $growth = [long]$group.Growth
                $was = '{0} MB' -f $file.growth_mb
                if ($null -eq $file.growth_mb) { $was = '{0}%' -f $file.growth_percent }
                if ($null -eq $file.growth_mb -or [long]$file.growth_mb -ne $growth) {
                    $changes.Add(@{
                            Statement = "ALTER DATABASE [tempdb] MODIFY FILE (NAME = $nameLiteral, FILEGROWTH = ${growth}MB);"
                            Description = "set the growth of $label to $growth MB (was $was)"
                        })
                }
            }
        }
    }

    if ($null -ne $Desired.FileCount -and $data.Count -gt 0) {
        $count = [long]$Desired.FileCount
        if ($data.Count -gt $count) {
            $notices.Add(('tempdb has {0} data files, more than file_count''s {1}: the module never removes one' -f $data.Count, $count))
        }
        elseif ($data.Count -lt $count) {
            $first = $data[0]
            $firstPath = [string]$first.path
            $directory = $firstPath.Substring(0, $firstPath.LastIndexOf('\') + 1)
            $size = [long]$first.size_mb
            if ($null -ne $Desired.FileSizeMb) { $size = [long]$Desired.FileSizeMb }
            $growth = '{0}MB' -f $first.growth_mb
            if ($null -eq $first.growth_mb) { $growth = '{0}%' -f $first.growth_percent }
            if ($null -ne $Desired.FileGrowthMb) { $growth = '{0}MB' -f $Desired.FileGrowthMb }
            $names = @($Files | ForEach-Object { [string]$_.name })
            $paths = @($Files | ForEach-Object { [string]$_.path })
            $number = 2
            for ($added = $data.Count; $added -lt $count; $added++) {
                while ($names -contains "temp$number" -or $paths -contains ('{0}tempdb_mssql_{1}.ndf' -f $directory, $number)) { $number++ }
                $fileName = "temp$number"
                $filePath = '{0}tempdb_mssql_{1}.ndf' -f $directory, $number
                $fileLiteral = ConvertTo-MssqlStringLiteral $fileName
                $pathLiteral = ConvertTo-MssqlStringLiteral $filePath
                $changes.Add(@{
                        Statement = "ALTER DATABASE [tempdb] ADD FILE (NAME = $fileLiteral, FILENAME = $pathLiteral, SIZE = ${size}MB, FILEGROWTH = $growth);"
                        Description = "add tempdb data file '$fileName' ($filePath, $size MB)"
                    })
                $number++
            }
        }
    }
    @{ Changes = $changes.ToArray(); Notices = $notices.ToArray() }
}

Function Read-MssqlErrorLog {
    <#
    .SYNOPSIS
    Reads an errorlog, which SQL Server holds open, as its lines; none when
    there's no such file. Reads only.
    #>
    [CmdletBinding()]
    param ([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $stream = New-Object -TypeName System.IO.FileStream -ArgumentList @(
        $Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList @($stream, [System.Text.Encoding]::Unicode, $true)
        $text = $reader.ReadToEnd()
    }
    finally {
        $stream.Dispose()
    }
    @($text -split "`r?`n")
}

Function Get-MssqlErrorLogTail {
    <#
    .SYNOPSIS
    Returns an errorlog's last lines that aren't blank, joined by ' | ', for
    a failure message. Reads only.
    #>
    [CmdletBinding()]
    param ([string]$Path, [int]$Count = 12)

    (@(Read-MssqlErrorLog $Path | Where-Object { $_.Trim() }) | Select-Object -Last $Count) -join ' | '
}

Function Get-MssqlServiceStateText {
    <#
    .SYNOPSIS
    Returns a service's state in lower case (running, stopped, ...), or ''
    when there's no such service. Reads only.
    #>
    [CmdletBinding()]
    param ([string]$Name)

    $state = (Get-MssqlServiceState -Name $Name)[$Name]
    if ($null -eq $state) { return '' }
    ([string]$state.State).ToLowerInvariant()
}

Function Get-MssqlEngineStartTime {
    <#
    .SYNOPSIS
    Returns when a running engine's process started (UTC), or $null when it
    isn't running. Reads only.
    #>
    [CmdletBinding()]
    param ([string]$ServiceName)

    $filter = "Name='{0}'" -f ($ServiceName -replace "'", "''")
    $service = Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction SilentlyContinue
    if ($null -eq $service -or [string]$service.State -ne 'Running' -or -not $service.ProcessId) { return $null }
    $process = Get-Process -Id $service.ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    $process.StartTime.ToUniversalTime()
}

Function Restart-MssqlEngine {
    <#
    .SYNOPSIS
    Restarts an instance's engine and waits for "ready for client
    connections" in the new process's errorlog, then starts the services
    that stopped with it (SQL Server Agent depends on the engine) and an
    Agent set to start automatically. Throws when the engine doesn't come
    back within Timeout seconds. An Agent that won't start, or stops again,
    comes back in Notices, since the change itself is done: under strict
    encryption SQL Server 2022's Agent retries for about 16 seconds and then
    stops, so Strict watches it longer.
    #>
    [CmdletBinding()]
    param ([string]$EngineName, [string]$AgentName, [string]$ErrorLogPath, [bool]$Strict, [int]$Timeout = 300)

    $notices = [System.Collections.Generic.List[string]]::new()
    $engineService = Get-Service -Name $EngineName -ErrorAction Stop
    $dependents = @($engineService.DependentServices | Where-Object { [string]$_.Status -eq 'Running' } | ForEach-Object { $_.Name })
    $agent = (Get-MssqlServiceState -Name $AgentName)[$AgentName]
    $toStart = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $dependents) { $toStart.Add($name) }
    if ($null -ne $agent -and [string]$agent.StartMode -eq 'Auto' -and -not $toStart.Contains($AgentName)) { $toStart.Add($AgentName) }

    Restart-Service -Name $EngineName -Force -ErrorAction Stop
    # The new process's own errorlog: SQL Server starts a new one, and names
    # its process ID near the top.
    $filter = "Name='{0}'" -f ($EngineName -replace "'", "''")
    $deadline = (Get-Date).AddSeconds($Timeout)
    $log = $null
    $current = $false
    do {
        Start-Sleep -Seconds 2
        $service = Get-CimInstance -ClassName Win32_Service -Filter $filter -ErrorAction Stop
        $processId = [int]$service.ProcessId
        $log = Get-MssqlErrorLogFact -Lines (Read-MssqlErrorLog $ErrorLogPath)
        $current = $processId -ne 0 -and $log.ProcessId -eq $processId
    } until (($current -and $log.Ready) -or [string]$service.State -eq 'Stopped' -or (Get-Date) -gt $deadline)
    if ((Get-MssqlServiceStateText $EngineName) -ne 'running') {
        throw "SQL Server ($EngineName) didn't start again after the change. Its errorlog ends: $(Get-MssqlErrorLogTail $ErrorLogPath)"
    }
    if (-not ($current -and $log.Ready)) {
        throw ("SQL Server ($EngineName) didn't get to ""ready for client connections"" within $Timeout seconds of " +
            "its restart. Its errorlog ends: $(Get-MssqlErrorLogTail $ErrorLogPath)")
    }

    foreach ($name in $toStart) {
        try {
            Start-Service -Name $name -ErrorAction Stop
        }
        catch {
            $notices.Add("$name didn't start again after $EngineName restarted: $($_.Exception.Message)")
            continue
        }
        # A service that can't reach SQL Server can start and then stop.
        $window = 10
        if ($Strict) { $window = 40 }
        $watchEnd = (Get-Date).AddSeconds($window)
        do {
            Start-Sleep -Seconds 2
            $state = Get-MssqlServiceStateText $name
        } until ($state -ne 'running' -or (Get-Date) -gt $watchEnd)
        if ($state -ne 'running') { $notices.Add("$name stopped again after it started (state: $state); its log says why") }
    }
    @{ Notices = $notices.ToArray() }
}

$exportFunctions = @(
    'ConvertTo-MssqlConfigValue'
    'ConvertTo-MssqlEditionId'
    'ConvertTo-MssqlEncryptionMode'
    'ConvertTo-MssqlFeatureName'
    'ConvertTo-MssqlInstanceFact'
    'ConvertTo-MssqlStartMode'
    'ConvertTo-MssqlStringLiteral'
    'ConvertTo-MssqlThumbprint'
    'ConvertTo-MssqlVersionName'
    'Format-MssqlSetupArgument'
    'Get-MssqlAccountProblem'
    'Get-MssqlCertificateNameNotice'
    'Get-MssqlCertificateProblem'
    'Get-MssqlChecksumHash'
    'Get-MssqlConfigurationBatch'
    'Get-MssqlConfigurationPlan'
    'Get-MssqlConnectionString'
    'Get-MssqlEditionPlan'
    'Get-MssqlEngineStartTime'
    'Get-MssqlErrorLogFact'
    'Get-MssqlErrorLogPath'
    'Get-MssqlErrorLogTail'
    'Get-MssqlFirewallRuleDifference'
    'Get-MssqlFirewallRuleSpec'
    'Get-MssqlInstalledFeature'
    'Get-MssqlInstanceNameProblem'
    'Get-MssqlInstancePlan'
    'Get-MssqlInstanceRegistry'
    'Get-MssqlMediaInfo'
    'Get-MssqlMediaSource'
    'Get-MssqlNetworkPlan'
    'Get-MssqlPidEdition'
    'Get-MssqlRebootPendingReason'
    'Get-MssqlRebootState'
    'Get-MssqlRegistryValue'
    'Get-MssqlServiceName'
    'Get-MssqlServiceSidName'
    'Get-MssqlServiceState'
    'Get-MssqlServiceStateText'
    'Get-MssqlSetupArgument'
    'Get-MssqlSetupArgumentProblem'
    'Get-MssqlSetupBootstrap'
    'Get-MssqlSetupHint'
    'Get-MssqlSetupSummary'
    'Get-MssqlStrictNotice'
    'Get-MssqlTempdbPlan'
    'Get-MssqlTempdbProblem'
    'Get-MssqlThumbprintProblem'
    'Get-MssqlVersionInfo'
    'Invoke-MssqlNonQuery'
    'Invoke-MssqlQuery'
    'ConvertTo-MssqlSetupArgument'
    'Read-MssqlErrorLog'
    'Restart-MssqlEngine'
    'Test-MssqlConfigValueInUse'
    'Test-MssqlReadRight'
    'Test-MssqlRestartPending'
)
Export-ModuleMember -Function $exportFunctions
