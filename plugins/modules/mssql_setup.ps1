#!powershell

# Copyright: (c) 2026, Chris Gallagher (@git-cgallagher)
# MIT License (see LICENSE or https://opensource.org/licenses/MIT)

#AnsibleRequires -CSharpUtil Ansible.Basic
#AnsibleRequires -PowerShell ..module_utils._MssqlCommon

# Installs a standalone SQL Server instance from an ISO, adds features to an
# installed one, or (with allow_remove) uninstalls one. Get-MssqlInstancePlan
# (plugins/module_utils/_MssqlCommon.psm1) decides what setup does; this file
# reads the host, checks what setup will need, stages the ISO (a UNC path or
# URL is copied into a cache, kept for the next run), mounts it, runs
# setup.exe and reads back what it did.
#
# Check mode reports the plan and runs every check that only reads: a pending
# reboot, the sysadmins, the accounts, the volumes and the media (its
# checksum, unless it's a URL not yet cached). It stages, mounts and runs
# nothing, so the media's version and edition are checked by a real run only.

$spec = @{
    options = @{
        instance_name = @{ type = 'str'; default = 'MSSQLSERVER' }
        state = @{ type = 'str'; default = 'present'; choices = @('present', 'absent') }
        allow_remove = @{ type = 'bool'; default = $false }
        version = @{ type = 'str'; choices = @('2022', '2025') }
        edition = @{ type = 'str'; choices = @('enterprise', 'standard', 'enterprise_developer', 'standard_developer', 'evaluation') }
        product_key = @{ type = 'str'; no_log = $true }
        features = @{ type = 'list'; elements = 'str'; default = @('SQLEngine'); choices = @('SQLEngine', 'Replication', 'FullText') }
        collation = @{ type = 'str' }
        media = @{
            type = 'dict'
            options = @{
                path = @{ type = 'str'; required = $true }
                checksum = @{ type = 'str'; required = $true }
            }
        }
        media_cache_dir = @{ type = 'str'; default = 'C:\ProgramData\mssql-iac\media' }
        update_source = @{ type = 'str' }
        engine_account = @{ type = 'str' }
        engine_password = @{ type = 'str'; no_log = $true }
        agent_account = @{ type = 'str' }
        agent_password = @{ type = 'str'; no_log = $true }
        agent_startup = @{ type = 'str'; default = 'automatic'; choices = @('automatic', 'manual', 'disabled') }
        sysadmins = @{ type = 'list'; elements = 'str' }
        instant_file_init = @{ type = 'bool'; default = $true }
        paths = @{
            type = 'dict'
            options = @{
                instance_dir = @{ type = 'str' }
                data_root = @{ type = 'str' }
                data = @{ type = 'str' }
                log = @{ type = 'str' }
                backup = @{ type = 'str' }
                tempdb_data = @{ type = 'str' }
                tempdb_log = @{ type = 'str' }
            }
        }
        tempdb = @{
            type = 'dict'
            options = @{
                file_count = @{ type = 'int' }
                file_size_mb = @{ type = 'int' }
                file_growth_mb = @{ type = 'int' }
                log_size_mb = @{ type = 'int' }
                log_growth_mb = @{ type = 'int' }
            }
        }
        pending_reboot = @{ type = 'str'; default = 'fail'; choices = @('fail', 'report') }
    }
    required_if = @(
        , @('state', 'present', @('version', 'edition', 'media', 'sysadmins'))
    )
    supports_check_mode = $true
}

$module = [Ansible.Basic.AnsibleModule]::Create($args, $spec)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$params = $module.Params
$instanceName = [string]$params.instance_name
$state = [string]$params.state
$checkMode = $module.CheckMode
$features = @($params.features | ForEach-Object { ConvertTo-MssqlFeatureName $_ } | Select-Object -Unique)
$paths = @{}
if ($null -ne $params.paths) { foreach ($k in @($params.paths.Keys)) { $paths[[string]$k] = $params.paths[$k] } }
$tempdb = @{}
if ($null -ne $params.tempdb) { foreach ($k in @($params.tempdb.Keys)) { $tempdb[[string]$k] = $params.tempdb[$k] } }
# The secrets, so they can be blanked out of any text the module returns.
$secrets = @($params.product_key, $params.engine_password, $params.agent_password | Where-Object { $_ })

$actions = [System.Collections.Generic.List[string]]::new()
$notices = [System.Collections.Generic.List[string]]::new()
$script:instance = $null
$script:media = $null
$script:setup = $null
$script:preflight = @{}
$script:rebootRequired = $false

# Refusals that need nothing from the host.
$problems = [System.Collections.Generic.List[string]]::new()
$problems.Add((Get-MssqlInstanceNameProblem $instanceName))
if ($state -eq 'present') {
    $problems.Add((Get-MssqlAccountProblem -Option 'engine' -Account $params.engine_account -HasPassword ([bool]$params.engine_password)))
    $problems.Add((Get-MssqlAccountProblem -Option 'agent' -Account $params.agent_account -HasPassword ([bool]$params.agent_password)))
    $problems.Add((Get-MssqlEditionPlan -Version $params.version -Edition $params.edition -ProductKey $params.product_key).Problem)
    if (-not (Get-MssqlChecksumHash $params.media.checksum)) {
        $problems.Add("media.checksum must be sha256: and 64 hex digits, got '$($params.media.checksum)'")
    }
    $problems.Add((Get-MssqlMediaSource -Path $params.media.path -CacheDir $params.media_cache_dir).Problem)
    if (@($params.sysadmins | Where-Object { $_ }).Count -eq 0) { $problems.Add('sysadmins must name at least one account or group') }
    if ($features -notcontains 'SQLEngine') { $problems.Add('features must include SQLEngine: the other features are part of an instance') }
}
$problem = @($problems | Where-Object { $_ }) | Select-Object -First 1
if ($problem) { $module.FailJson($problem) }

# Text with every secret value replaced, for messages and results.
function Hide-Secret {
    param([string]$Text)
    foreach ($secret in $secrets) { $Text = $Text.Replace([string]$secret, '********') }
    $Text
}

# Record an action; carry it out unless this is a check-mode run.
function Invoke-Change {
    param([string]$Description, [scriptblock]$Change)
    $actions.Add($Description)
    if (-not $checkMode) { & $Change }
}

function Get-InstanceFact {
    $entry = @(Get-MssqlInstanceRegistry | Where-Object { $_.Name -eq $instanceName }) | Select-Object -First 1
    if ($null -eq $entry) { return $null }
    $names = @('engine', 'agent', 'fulltext' | ForEach-Object { Get-MssqlServiceName -InstanceName $entry.Name -Service $_ })
    ConvertTo-MssqlInstanceFact -Registry $entry -Services (Get-MssqlServiceState -Name $names)
}

function Resolve-AccountSid {
    param([string]$Account, [string]$Option)
    try {
        (New-Object -TypeName System.Security.Principal.NTAccount -ArgumentList $Account).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        throw "$Option names $Account, which doesn't resolve to an account or group on this host: $($_.Exception.Message)"
    }
}

function Get-FileSha256 {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# What setup needs before it runs, read in check mode too: no pending reboot;
# for a new instance, the account this runs as among the sysadmins (or it
# couldn't manage the instance afterwards), the service accounts and the
# paths' volumes; and the update folder.
function Test-Preflight {
    param([bool]$NewInstance)
    $reasons = @(Get-MssqlRebootPendingReason -State (Get-MssqlRebootState))
    $script:preflight.reboot_pending = $reasons.Count -gt 0
    $script:preflight.reboot_pending_reasons = $reasons
    if ($reasons.Count -gt 0 -and $params.pending_reboot -eq 'fail') {
        throw ("A reboot is pending ({0}), and setup won't run until it's done. Reboot first (the mssql role does " +
            'when mssql_allow_reboot is true).') -f ($reasons -join '; ')
    }
    if ($NewInstance) {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $script:preflight.connection_account = $identity.Name
        $sids = @($identity.User.Value) + @($identity.Groups | ForEach-Object { $_.Value })
        $matched = @($params.sysadmins | Where-Object { $sids -contains (Resolve-AccountSid -Account $_ -Option 'sysadmins') })
        $script:preflight.sysadmin_match = $matched
        if ($matched.Count -eq 0) {
            throw ("None of sysadmins ({0}) is {1}, the account this runs as, or a group it's in, so it couldn't manage the instance " +
                'after setup. Add it or one of its groups (with become, the become user).') -f ($params.sysadmins -join ', '), $identity.Name
        }
        foreach ($option in 'engine_account', 'agent_account') {
            $account = [string]$params[$option]
            # A virtual account (NT SERVICE\...) exists only once its service does.
            if ($account -and $account -notmatch '^NT SERVICE\\') { $null = Resolve-AccountSid -Account $account -Option $option }
        }
        foreach ($key in @($paths.Keys | Sort-Object)) {
            $value = [string]$paths[$key]
            if (-not $value) { continue }
            $root = [System.IO.Path]::GetPathRoot($value)
            if (-not $root -or -not (Test-Path -LiteralPath $root)) { throw "paths.$key is $value, on a volume this host doesn't have" }
        }
    }
    if ($params.update_source -and -not (Test-Path -LiteralPath $params.update_source -PathType Container)) {
        throw "update_source $($params.update_source) isn't a folder this host can read"
    }
}

# Where the ISO is read from, and whether it must be staged first: a local
# path is used where it is; a UNC path or URL is copied into
# media_cache_dir, unless the copy there already has the checksum.
function Get-MediaPlan {
    $source = Get-MssqlMediaSource -Path $params.media.path -CacheDir $params.media_cache_dir
    $expected = Get-MssqlChecksumHash $params.media.checksum
    $script:media = @{
        path = $params.media.path
        kind = $source.Kind
        local_path = $source.LocalPath
        staged = $false
        sha256 = ''
        build = ''
        version = ''
        edition = ''
    }
    if ($source.Kind -eq 'local') {
        if (-not (Test-Path -LiteralPath $source.LocalPath -PathType Leaf)) { throw "media.path $($source.LocalPath) doesn't exist" }
        $hash = Get-FileSha256 $source.LocalPath
        if ($hash -ne $expected) { throw "media.path $($source.LocalPath) has SHA-256 $hash, not $expected" }
        $script:media.sha256 = $hash
        return @{ Source = $source; Stage = $false; Expected = $expected }
    }
    if (Test-Path -LiteralPath $source.LocalPath -PathType Leaf) {
        $hash = Get-FileSha256 $source.LocalPath
        if ($hash -eq $expected) {
            $script:media.sha256 = $hash
            return @{ Source = $source; Stage = $false; Expected = $expected }
        }
    }
    if ($source.Kind -eq 'unc') {
        if (-not (Test-Path -LiteralPath $params.media.path -PathType Leaf)) {
            throw ("media.path $($params.media.path) doesn't exist, or {0} can't read it (a share needs become, or the double hop " +
                'leaves the WinRM logon without credentials)') -f [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        # Check mode proves the share's copy matches; a real run checks its
        # own copy instead.
        if ($checkMode) {
            $hash = Get-FileSha256 $params.media.path
            if ($hash -ne $expected) { throw "media.path $($params.media.path) has SHA-256 $hash, not $expected" }
        }
    }
    else {
        $request = [System.Net.WebRequest]::Create($params.media.path)
        $request.Method = 'HEAD'
        $request.Timeout = 60000
        try {
            $response = $request.GetResponse()
            $response.Close()
        }
        catch {
            throw "media.path $($params.media.path) didn't answer: $($_.Exception.Message)"
        }
    }
    @{ Source = $source; Stage = $true; Expected = $expected }
}

function Invoke-Stage {
    param($Plan)
    $target = $Plan.Source.LocalPath
    $partial = $target + '.partial'
    if (-not (Test-Path -LiteralPath $params.media_cache_dir)) { $null = New-Item -ItemType Directory -Path $params.media_cache_dir -Force }
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    if ($Plan.Source.Kind -eq 'url') {
        $client = New-Object -TypeName System.Net.WebClient
        try {
            $client.DownloadFile($params.media.path, $partial)
        }
        finally {
            $client.Dispose()
        }
    }
    else {
        Copy-Item -LiteralPath $params.media.path -Destination $partial -Force
    }
    $hash = Get-FileSha256 $partial
    if ($hash -ne $Plan.Expected) {
        Remove-Item -LiteralPath $partial -Force
        throw "The media from $($params.media.path) has SHA-256 $hash, not $($Plan.Expected)"
    }
    Move-Item -LiteralPath $partial -Destination $target -Force
    $script:media.staged = $true
    $script:media.sha256 = $hash
}

# Mounts the ISO read-only and returns its root (D:\), and whether this run
# mounted it (so it dismounts only what it mounted).
function Mount-Media {
    param([string]$Path)
    $mounted = $false
    if (-not (Get-DiskImage -ImagePath $Path).Attached) {
        $null = Mount-DiskImage -ImagePath $Path -StorageType ISO -Access ReadOnly
        $mounted = $true
    }
    $letter = ''
    $deadline = (Get-Date).AddSeconds(60)
    do {
        $letter = [string](Get-DiskImage -ImagePath $Path | Get-Volume).DriveLetter
        if ($letter) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    if (-not $letter) {
        if ($mounted) { $null = Dismount-DiskImage -ImagePath $Path }
        throw "The ISO $Path mounted without a drive letter"
    }
    @{ Root = $letter + ':\'; Mounted = $mounted }
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    [System.IO.File]::ReadAllText($Path)
}

# Runs setup.exe and waits for it. Its output is read (so it can't block on
# a full pipe) but returned only on failure, without secrets. Exit code 3010
# is success with a reboot required. On failure, setup's Summary.txt says
# why.
function Invoke-Setup {
    param([string]$SetupPath, [object[]]$Arguments, [string]$LogRoot, [string]$Action)
    $script:setup = @{
        action = $Action
        command = '"{0}" {1}' -f $SetupPath, (Format-MssqlSetupArgument -Arguments $Arguments -Redact)
        exit_code = $null
        summary_path = $LogRoot + '\Summary.txt'
        log_dir = ''
    }
    $started = Get-Date
    $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $SetupPath
    $startInfo.Arguments = Format-MssqlSetupArgument -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $script:setup.exit_code = $exitCode
    $runDir = @(Get-ChildItem -LiteralPath $LogRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.CreationTime -ge $started.AddMinutes(-1) } | Sort-Object CreationTime) | Select-Object -Last 1
    if ($null -ne $runDir) { $script:setup.log_dir = $runDir.FullName }
    if ($exitCode -eq 3010) { $script:rebootRequired = $true }
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        $summary = Get-MssqlSetupSummary -Text (Read-TextFile $script:setup.summary_path)
        # The innermost exception usually names the cause, so it comes first.
        $chain = @($summary.Exceptions)
        [array]::Reverse($chain)
        $details = @(@($summary.ExitMessage) + @($summary.Failures) + @($chain) | Where-Object { $_ } | Select-Object -Unique)
        if ($details.Count -eq 0) {
            $output = @(($stdout.Result + "`n" + $stderr.Result) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 15
            $details = @($output)
        }
        $hint = Get-MssqlSetupHint -Details $details -Account ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
        if ($hint) { $details = @($details) + @($hint) }
        throw (Hide-Secret ('SQL Server setup failed with exit code {0} ({1}): {2} See {3}' -f
                $exitCode, $summary.FinalResult, ($details -join ' '), $script:setup.summary_path))
    }
}

# Installs the instance, or adds features to it: stage, mount, check the
# media is the version and edition asked for, run setup, dismount.
function Invoke-Install {
    param([string]$Action, [string[]]$Features)
    Test-Preflight -NewInstance ($Action -eq 'Install')
    $mediaPlan = Get-MediaPlan
    if ($mediaPlan.Stage) {
        Invoke-Change "stage media $($params.media.path) to $($mediaPlan.Source.LocalPath)" { Invoke-Stage $mediaPlan }
    }
    $description = 'install SQL Server {0} ({1}) instance {2} with features {3}' -f $params.version, $params.edition, $instanceName, ($Features -join ', ')
    if ($Action -eq 'AddFeatures') { $description = 'add features {0} to instance {1}' -f ($Features -join ', '), $instanceName }
    $actions.Add($description)
    if ($checkMode) { return }

    $iso = $mediaPlan.Source.LocalPath
    $mount = Mount-Media $iso
    try {
        $info = Get-MssqlMediaInfo -MediaInfoXml (Read-TextFile ($mount.Root + 'MediaInfo.xml')) `
            -DefaultSetupIni (Read-TextFile ($mount.Root + 'x64\DefaultSetup.ini'))
        $script:media.build = $info.Build
        $script:media.version = $info.Version
        $script:media.edition = $info.Edition
        if ($info.Version -ne $params.version) {
            throw "The media is SQL Server build '$($info.Build)', not $($params.version) (its MediaInfo.xml)"
        }
        $edition = Get-MssqlEditionPlan -Version $params.version -Edition $params.edition -ProductKey $params.product_key -MediaEdition $info.Edition
        if ($edition.Problem) { throw $edition.Problem }
        $options = @{
            InstanceName = $instanceName
            Features = $Features
            ProductId = $edition.ProductId
            UpdateSource = $params.update_source
            EngineAccount = $params.engine_account
            EnginePassword = $params.engine_password
            AgentAccount = $params.agent_account
            AgentPassword = $params.agent_password
            AgentStartup = $params.agent_startup
            Sysadmins = @($params.sysadmins)
            Collation = $params.collation
            InstantFileInit = [bool]$params.instant_file_init
            Paths = $paths
            Tempdb = $tempdb
        }
        $arguments = Get-MssqlSetupArgument -Action $Action -Options $options
        $argumentProblem = Get-MssqlSetupArgumentProblem -Arguments $arguments
        if ($argumentProblem) { throw $argumentProblem }
        $logRoot = (Get-MssqlSetupBootstrap -Version $params.version -ProgramFiles $env:ProgramFiles).Log
        Invoke-Setup -SetupPath ($mount.Root + 'setup.exe') -Arguments $arguments -LogRoot $logRoot -Action $Action
    }
    finally {
        if ($mount.Mounted) { $null = Dismount-DiskImage -ImagePath $iso }
    }

    $after = Get-InstanceFact
    if ($null -eq $after) {
        throw "Setup exited with $($script:setup.exit_code), but the registry lists no instance $instanceName. See $($script:setup.summary_path)"
    }
    if ($Action -eq 'Install' -and $after.edition_id -ne $params.edition) {
        throw "Setup installed edition '$($after.edition)' for instance $instanceName, not $($params.edition)"
    }
}

# Uninstalls the instance's features with the copy of setup.exe its version
# keeps, which needs no media.
function Invoke-Uninstall {
    param($Installed)
    if (-not $params.allow_remove) {
        throw "state=absent would uninstall instance $instanceName, and its databases with it; set allow_remove to let it"
    }
    $bootstrap = Get-MssqlSetupBootstrap -Version $Installed.version -ProgramFiles $env:ProgramFiles
    if ($null -eq $bootstrap) { throw "Instance $instanceName is version $($Installed.version_number), which this module doesn't uninstall" }
    if (-not (Test-Path -LiteralPath $bootstrap.Setup -PathType Leaf)) { throw "Can't uninstall instance ${instanceName}: $($bootstrap.Setup) doesn't exist" }
    Test-Preflight -NewInstance $false
    $installedFeatures = @($Installed.features)
    Invoke-Change "uninstall instance $instanceName (features $($installedFeatures -join ', '))" {
        $arguments = Get-MssqlSetupArgument -Action 'Uninstall' -Options @{ InstanceName = $instanceName; Features = $installedFeatures }
        Invoke-Setup -SetupPath $bootstrap.Setup -Arguments $arguments -LogRoot $bootstrap.Log -Action 'Uninstall'
        if ($null -ne (Get-InstanceFact)) { throw "Setup exited with $($script:setup.exit_code), but instance $instanceName is still installed" }
    }
}

function Invoke-Main {
    $installed = Get-InstanceFact
    $script:instance = $installed
    $desired = @{
        State = $state
        Version = $params.version
        Edition = $params.edition
        Features = $features
        Collation = $params.collation
    }
    $plan = Get-MssqlInstancePlan -InstanceName $instanceName -Desired $desired -Installed $installed
    foreach ($notice in $plan.Notices) {
        $notices.Add($notice)
        $module.Warn($notice)
    }
    switch ($plan.Action) {
        'install' { Invoke-Install -Action 'Install' -Features $features }
        'add_features' { Invoke-Install -Action 'AddFeatures' -Features $plan.AddFeatures }
        'uninstall' { Invoke-Uninstall -Installed $installed }
    }
    if ($actions.Count -gt 0 -and -not $checkMode) { $script:instance = Get-InstanceFact }
}

function Set-ModuleResult {
    $module.Result.instance = $script:instance
    $module.Result.media = $script:media
    $module.Result.setup = $script:setup
    $module.Result.preflight = $script:preflight
    $module.Result.reboot_required = $script:rebootRequired
    $module.Result.notices = $notices.ToArray()
    $module.Result.actions = $actions.ToArray()
    # In check mode an action that would be taken is a change, as for a real run.
    $module.Result.changed = $actions.Count -gt 0
    $module.Diff.prepared = ($actions -join "`n")
}

# FailJson exits through an exception, so it is only called outside the try
# block, from the catch.
try {
    Invoke-Main
}
catch {
    Set-ModuleResult
    $msg = '{0} (at line {1}: {2})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()
    $module.FailJson((Hide-Secret $msg), $_)
}

Set-ModuleResult
$module.ExitJson()
