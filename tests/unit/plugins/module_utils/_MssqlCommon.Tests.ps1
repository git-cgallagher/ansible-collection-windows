# Pester 5 unit tests for plugins/module_utils/_MssqlCommon.psm1, the logic
# mssql_setup and mssql_info share. No SQL Server, no Ansible: run them with
#   Invoke-Pester -Path tests/unit
# (the powershell CI job does). Windows PowerShell 5.1 or pwsh.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_MssqlCommon.psm1') -Force

    # The two files of the SQL Server 2022 Developer ISO
    # (SQLServer2022-x64-ENU-Dev.iso, SHA-256 80d2cd75...daffd) the modules
    # read: MediaInfo.xml as UTF-8 with its BOM, and x64\DefaultSetup.ini.
    $script:mediaInfo2022 = [string][char]0xFEFF + @'
<?xml version="1.0" encoding="UTF-8"?>
<MediaInfo>
  <Properties xmlns="">
    <Property Id="MediaLayout" Value="Full" />
    <Property Id="BaselineVersion" Value="16.0.1000.6" />
    <Property Id="SupportSku" Value="1" />
    <Property Id="ReleaseTrain" Value="BASELINE" />
  </Properties>
</MediaInfo>
'@
    $script:defaultSetup2022 = ";SQL Server 2022 Configuration File`r`n[OPTIONS]`r`nPID=`"22222-00000-00000-00000-00000`"`r`n"

    # An installed instance as ConvertTo-MssqlInstanceFact returns it.
    function script:New-Installed {
        param([string]$Version = '2022', [string]$EditionId = 'enterprise_developer', [string[]]$Features = @('SQLEngine'),
            [bool]$FeaturesKnown = $true, [string]$Collation = 'SQL_Latin1_General_CP1_CI_AS')
        @{
            id = 'MSSQL16.MSSQLSERVER'
            version = $Version
            version_number = '16.0.1000.6'
            edition = 'Developer Edition'
            edition_id = $EditionId
            features = $Features
            features_known = $FeaturesKnown
            collation = $Collation
        }
    }

    function script:New-Desired {
        param([string]$State = 'present', [string[]]$Features = @('SQLEngine'), [string]$Collation = '')
        @{ State = $State; Version = '2022'; Edition = 'enterprise_developer'; Features = $Features; Collation = $Collation }
    }
}

AfterAll {
    Remove-Module _MssqlCommon -ErrorAction SilentlyContinue
}

Describe 'Versions' {
    It 'knows 2022 and 2025 by major version and folder' {
        (Get-MssqlVersionInfo '2022').Major | Should -Be 16
        (Get-MssqlVersionInfo '2022').Folder | Should -Be '160'
        (Get-MssqlVersionInfo '2025').Major | Should -Be 17
        Get-MssqlVersionInfo '2019' | Should -BeNullOrEmpty
    }

    It 'names a version from an instance ID, a version number or a major version' {
        ConvertTo-MssqlVersionName 'MSSQL16.MSSQLSERVER' | Should -Be '2022'
        ConvertTo-MssqlVersionName 'MSSQL17.INST1' | Should -Be '2025'
        ConvertTo-MssqlVersionName '16.0.1000.6' | Should -Be '2022'
        ConvertTo-MssqlVersionName '17' | Should -Be '2025'
        ConvertTo-MssqlVersionName 'MSSQL15.MSSQLSERVER' | Should -Be ''
        ConvertTo-MssqlVersionName '' | Should -Be ''
    }

    It 'finds an installed version''s own setup.exe and setup''s logs' {
        $bootstrap = Get-MssqlSetupBootstrap -Version '2022' -ProgramFiles 'C:\Program Files\'
        $bootstrap.Setup | Should -Be 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\SQL2022\setup.exe'
        $bootstrap.Log | Should -Be 'C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log'
        (Get-MssqlSetupBootstrap -Version '2025' -ProgramFiles 'C:\Program Files').Setup | Should -Match '\\170\\Setup Bootstrap\\SQL2025\\setup\.exe$'
        Get-MssqlSetupBootstrap -Version '2019' -ProgramFiles 'C:\Program Files' | Should -BeNullOrEmpty
    }
}

Describe 'Get-MssqlMediaInfo' {
    It 'reads the 2022 Developer ISO as 2022, Enterprise Developer' {
        $info = Get-MssqlMediaInfo -MediaInfoXml $script:mediaInfo2022 -DefaultSetupIni $script:defaultSetup2022
        $info.Build | Should -Be '16.0.1000.6'
        $info.Version | Should -Be '2022'
        $info.ProductId | Should -Be '22222-00000-00000-00000-00000'
        $info.Edition | Should -Be 'enterprise_developer'
    }

    It 'reads media without a DefaultSetup.ini key as Evaluation' {
        (Get-MssqlMediaInfo -MediaInfoXml $script:mediaInfo2022 -DefaultSetupIni '').Edition | Should -Be 'evaluation'
    }

    It 'reads a paid key as licensed, and the 2025 Standard Developer key as standard_developer' {
        (Get-MssqlMediaInfo -DefaultSetupIni 'PID="ABCDE-12345-ABCDE-12345-ABCDE"').Edition | Should -Be 'licensed'
        (Get-MssqlMediaInfo -DefaultSetupIni 'PID="33333-00000-00000-00000-00000"').Edition | Should -Be 'standard_developer'
    }
}

Describe 'Get-MssqlEditionPlan' {
    It 'refuses Standard Developer on 2022, which has none' {
        (Get-MssqlEditionPlan -Version '2022' -Edition 'standard_developer').Problem | Should -Match 'no Standard Developer'
        (Get-MssqlEditionPlan -Version '2025' -Edition 'standard_developer').Problem | Should -Be ''
    }

    It 'refuses a product key for a Developer edition or Evaluation' {
        (Get-MssqlEditionPlan -Version '2022' -Edition 'enterprise_developer' -ProductKey 'K').Problem | Should -Match 'takes no product key'
        (Get-MssqlEditionPlan -Version '2022' -Edition 'evaluation' -ProductKey 'K').Problem | Should -Match 'takes no product key'
    }

    It 'passes the Developer key, and accepts Developer or Evaluation media for it' {
        foreach ($media in '', 'enterprise_developer', 'evaluation') {
            $plan = Get-MssqlEditionPlan -Version '2022' -Edition 'enterprise_developer' -MediaEdition $media
            $plan.ProductId | Should -Be '22222-00000-00000-00000-00000'
            $plan.Problem | Should -Be ''
        }
        (Get-MssqlEditionPlan -Version '2025' -Edition 'standard_developer').ProductId | Should -Be '33333-00000-00000-00000-00000'
    }

    It 'refuses Developer from media for another edition' {
        (Get-MssqlEditionPlan -Version '2025' -Edition 'enterprise_developer' -MediaEdition 'standard_developer').Problem |
            Should -Match 'media is for edition standard_developer'
        (Get-MssqlEditionPlan -Version '2022' -Edition 'enterprise_developer' -MediaEdition 'licensed').Problem | Should -Match 'licensed'
    }

    It 'installs Evaluation only from media without a key' {
        $plan = Get-MssqlEditionPlan -Version '2022' -Edition 'evaluation' -MediaEdition 'evaluation'
        $plan.ProductId | Should -Be ''
        $plan.Problem | Should -Be ''
        (Get-MssqlEditionPlan -Version '2022' -Edition 'evaluation' -MediaEdition 'enterprise_developer').Problem | Should -Match 'not Evaluation'
    }

    It 'passes a paid edition''s key, or takes the media''s own' {
        (Get-MssqlEditionPlan -Version '2022' -Edition 'enterprise' -ProductKey 'K').ProductId | Should -Be 'K'
        $plan = Get-MssqlEditionPlan -Version '2022' -Edition 'standard' -MediaEdition 'licensed'
        $plan.ProductId | Should -Be ''
        $plan.Problem | Should -Be ''
        (Get-MssqlEditionPlan -Version '2022' -Edition 'enterprise' -MediaEdition 'enterprise_developer').Problem | Should -Match 'needs product_key'
        # Before the media is read, nothing to refuse yet.
        (Get-MssqlEditionPlan -Version '2022' -Edition 'enterprise').Problem | Should -Be ''
    }
}

Describe 'ConvertTo-MssqlEditionId' {
    It 'names each edition string setup and SERVERPROPERTY use' {
        ConvertTo-MssqlEditionId 'Developer Edition' | Should -Be 'enterprise_developer'
        ConvertTo-MssqlEditionId 'Developer Edition (64-bit)' | Should -Be 'enterprise_developer'
        ConvertTo-MssqlEditionId 'Enterprise Developer Edition (64-bit)' | Should -Be 'enterprise_developer'
        ConvertTo-MssqlEditionId 'Standard Developer Edition (64-bit)' | Should -Be 'standard_developer'
        ConvertTo-MssqlEditionId 'Enterprise Evaluation Edition (64-bit)' | Should -Be 'evaluation'
        ConvertTo-MssqlEditionId 'Enterprise Edition: Core-based Licensing (64-bit)' | Should -Be 'enterprise'
        ConvertTo-MssqlEditionId 'Standard Edition (64-bit)' | Should -Be 'standard'
        ConvertTo-MssqlEditionId 'Express Edition (64-bit)' | Should -Be ''
    }
}

Describe 'Get-MssqlChecksumHash' {
    It 'takes sha256: and 64 hex digits, in lower case' {
        Get-MssqlChecksumHash ('sha256:' + 'AB' * 32) | Should -Be ('ab' * 32)
    }

    It 'returns nothing for anything else' {
        Get-MssqlChecksumHash ('ab' * 32) | Should -Be ''
        Get-MssqlChecksumHash ('sha1:' + 'ab' * 20) | Should -Be ''
        Get-MssqlChecksumHash 'sha256:abc' | Should -Be ''
    }
}

Describe 'Get-MssqlMediaSource' {
    It 'stages a URL into the cache, named after its last segment' {
        $source = Get-MssqlMediaSource -Path 'https://download.example.com/sql/SQLServer2022%20Dev.iso?x=1' -CacheDir 'C:\Cache\'
        $source.Kind | Should -Be 'url'
        $source.FileName | Should -Be 'SQLServer2022 Dev.iso'
        $source.LocalPath | Should -Be 'C:\Cache\SQLServer2022 Dev.iso'
        $source.Problem | Should -Be ''
    }

    It 'stages a UNC path into the cache' {
        $source = Get-MssqlMediaSource -Path '\\files.example.com\media\sql\SQL2022.iso' -CacheDir 'C:\Cache'
        $source.Kind | Should -Be 'unc'
        $source.LocalPath | Should -Be 'C:\Cache\SQL2022.iso'
    }

    It 'reads a local path where it is' {
        $source = Get-MssqlMediaSource -Path 'D:\media\SQL2022.ISO' -CacheDir 'C:\Cache'
        $source.Kind | Should -Be 'local'
        $source.LocalPath | Should -Be 'D:\media\SQL2022.ISO'
    }

    It 'refuses a relative path and a file that is not an ISO' {
        (Get-MssqlMediaSource -Path 'media\SQL2022.iso' -CacheDir 'C:\Cache').Problem | Should -Match 'local path'
        (Get-MssqlMediaSource -Path '\\server\share\setup.exe' -CacheDir 'C:\Cache').Problem | Should -Match '\.iso file'
        (Get-MssqlMediaSource -Path 'https://example.com/' -CacheDir 'C:\Cache').Problem | Should -Not -Be ''
    }
}

Describe 'Features' {
    It 'names a feature from any case of it' {
        ConvertTo-MssqlFeatureName 'sqlengine' | Should -Be 'SQLEngine'
        ConvertTo-MssqlFeatureName 'FULLTEXT' | Should -Be 'FullText'
        ConvertTo-MssqlFeatureName 'SQL' | Should -Be ''
    }

    It 'reads an instance''s features from ConfigurationState first' {
        $state = @{ SQL_Engine_Core_Inst = 1; SQL_Replication_Core_Inst = 1; SQL_FullText_Adv = 0 }
        $installed = Get-MssqlInstalledFeature -ConfigurationState $state -FeatureList 'SQL_FullText_Adv=3' -HasFullTextService $true
        $installed.Features | Should -Be @('SQLEngine', 'Replication')
        $installed.Known | Should -BeTrue
        $installed.Source | Should -Be 'ConfigurationState'
    }

    It 'falls back to Setup\FeatureList' {
        $list = 'SQL_Engine_Core_Inst=3 SQL_FullText_Adv=3 SQL_Replication_Core_Inst=0'
        $installed = Get-MssqlInstalledFeature -ConfigurationState @{ Other = 1 } -FeatureList $list
        $installed.Features | Should -Be @('SQLEngine', 'FullText')
        $installed.Source | Should -Be 'FeatureList'
    }

    It 'falls back to the services, and says it can''t tell Replication' {
        $installed = Get-MssqlInstalledFeature -HasFullTextService $true
        $installed.Features | Should -Be @('SQLEngine', 'FullText')
        $installed.Known | Should -BeFalse
        (Get-MssqlInstalledFeature).Features | Should -Be @('SQLEngine')
    }
}

Describe 'Get-MssqlInstancePlan' {
    It 'installs a missing instance and leaves an absent one alone' {
        (Get-MssqlInstancePlan -InstanceName 'X' -Desired (New-Desired) -Installed $null).Action | Should -Be 'install'
        (Get-MssqlInstancePlan -InstanceName 'X' -Desired (New-Desired -State 'absent') -Installed $null).Action | Should -Be 'none'
    }

    It 'uninstalls an instance asked to be absent' {
        (Get-MssqlInstancePlan -InstanceName 'X' -Desired (New-Desired -State 'absent') -Installed (New-Installed)).Action | Should -Be 'uninstall'
    }

    It 'does nothing for an instance that matches' {
        $plan = Get-MssqlInstancePlan -InstanceName 'X' -Desired (New-Desired -Collation 'SQL_Latin1_General_CP1_CI_AS') -Installed (New-Installed)
        $plan.Action | Should -Be 'none'
        $plan.Notices.Count | Should -Be 0
    }

    It 'adds missing features and reports unlisted ones without removing them' {
        $installed = New-Installed -Features @('SQLEngine', 'Replication')
        $plan = Get-MssqlInstancePlan -InstanceName 'X' -Desired (New-Desired -Features @('SQLEngine', 'FullText')) -Installed $installed
        $plan.Action | Should -Be 'add_features'
        $plan.AddFeatures | Should -Be @('FullText')
        $plan.Notices | Should -HaveCount 1
        $plan.Notices[0] | Should -Match 'Replication.*never removed'
    }

    It 'reports, never reinstalls, a different version, edition or collation' {
        $installed = New-Installed -Version '' -EditionId 'standard' -Collation 'Latin1_General_CI_AS'
        $desired = New-Desired -Features @('SQLEngine', 'FullText') -Collation 'SQL_Latin1_General_CP1_CI_AS'
        $plan = Get-MssqlInstancePlan -InstanceName 'X' -Desired $desired -Installed $installed
        $plan.Action | Should -Be 'none'
        ($plan.Notices -join "`n") | Should -Match 'never reinstalled or upgraded'
        ($plan.Notices -join "`n") | Should -Match 'edition is never changed'
        ($plan.Notices -join "`n") | Should -Match 'set at install only'
        ($plan.Notices -join "`n") | Should -Match "lacks FullText, which 2022 media can't add"
    }

    It 'adds nothing when it can''t tell which features are there' {
        $installed = New-Installed -Features @('SQLEngine') -FeaturesKnown $false
        $plan = Get-MssqlInstancePlan -InstanceName 'X' -Desired (New-Desired -Features @('SQLEngine', 'Replication')) -Installed $installed
        $plan.Action | Should -Be 'none'
        $plan.Notices[0] | Should -Match "Can't tell"
    }
}

Describe 'Setup arguments' {
    BeforeAll {
        $script:installOptions = @{
            InstanceName = 'MSSQLSERVER'
            Features = @('SQLEngine', 'Replication')
            ProductId = '22222-00000-00000-00000-00000'
            EngineAccount = 'EXAMPLE\svc-sqldb'
            EnginePassword = 'Example-not-secret-1'
            AgentAccount = 'EXAMPLE\gmsa-sqlagt$'
            AgentStartup = 'automatic'
            Sysadmins = @('EXAMPLE\GG-SQL-Admins', 'EXAMPLE\svc-ansible')
            Collation = 'SQL_Latin1_General_CP1_CI_AS'
            InstantFileInit = $true
            Paths = @{ data = 'D:\Data'; backup = 'B:\Backup\'; log = '' }
            Tempdb = @{ file_count = 2; file_size_mb = 64 }
        }
    }

    It 'installs an instance with every setting, values quoted' {
        $arguments = Get-MssqlSetupArgument -Action 'Install' -Options $script:installOptions
        $expected = @(
            '/Q /ACTION="Install" /IACCEPTSQLSERVERLICENSETERMS /FEATURES="SQLENGINE,REPLICATION" /INSTANCENAME="MSSQLSERVER"'
            '/UpdateEnabled="False" /PID="22222-00000-00000-00000-00000" /SQLSVCACCOUNT="EXAMPLE\svc-sqldb"'
            '/SQLSVCPASSWORD="Example-not-secret-1" /SQLSVCSTARTUPTYPE="Automatic" /AGTSVCACCOUNT="EXAMPLE\gmsa-sqlagt$"'
            '/AGTSVCSTARTUPTYPE="Automatic" /SQLSYSADMINACCOUNTS="EXAMPLE\GG-SQL-Admins" "EXAMPLE\svc-ansible"'
            '/SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS" /SQLSVCINSTANTFILEINIT="True" /TCPENABLED="1" /SQLUSERDBDIR="D:\Data"'
            '/SQLBACKUPDIR="B:\Backup\\" /SQLTEMPDBFILECOUNT="2" /SQLTEMPDBFILESIZE="64"'
        ) -join ' '
        Format-MssqlSetupArgument -Arguments $arguments | Should -Be $expected
    }

    It 'redacts the passwords and the product key' {
        $line = Format-MssqlSetupArgument -Arguments (Get-MssqlSetupArgument -Action 'Install' -Options $script:installOptions) -Redact
        $line | Should -Not -Match 'Example-not-secret-1'
        $line | Should -Not -Match '22222'
        $line | Should -Match '/SQLSVCPASSWORD="\*{8}"'
        $line | Should -Match '/PID="\*{8}"'
    }

    It 'adds features with only what setup needs, and a CU folder when given' {
        $options = @{ InstanceName = 'INST1'; Features = @('FullText'); UpdateSource = 'C:\Updates'; EnginePassword = 'x' }
        $expected = '/Q /ACTION="Install" /IACCEPTSQLSERVERLICENSETERMS /FEATURES="FULLTEXT" /INSTANCENAME="INST1" ' +
        '/UpdateEnabled="True" /UpdateSource="C:\Updates"'
        Format-MssqlSetupArgument -Arguments (Get-MssqlSetupArgument -Action 'AddFeatures' -Options $options) | Should -Be $expected
    }

    It 'uninstalls an instance''s features' {
        $options = @{ InstanceName = 'INST1'; Features = @('SQLEngine', 'FullText') }
        Format-MssqlSetupArgument -Arguments (Get-MssqlSetupArgument -Action 'Uninstall' -Options $options) |
            Should -Be '/Q /ACTION="Uninstall" /FEATURES="SQLENGINE,FULLTEXT" /INSTANCENAME="INST1"'
    }

    It 'refuses a double quote in a value without showing it' {
        $options = $script:installOptions.Clone()
        $options.EnginePassword = 'pa"ss'
        $problem = Get-MssqlSetupArgumentProblem -Arguments (Get-MssqlSetupArgument -Action 'Install' -Options $options)
        $problem | Should -Match 'SQLSVCPASSWORD'
        $problem | Should -Not -Match 'pa"ss'
        Get-MssqlSetupArgumentProblem -Arguments (Get-MssqlSetupArgument -Action 'Install' -Options $script:installOptions) | Should -Be ''
    }
}

Describe 'Names, accounts and connections' {
    It 'names the default and a named instance''s services' {
        Get-MssqlServiceName -InstanceName 'MSSQLSERVER' -Service engine | Should -Be 'MSSQLSERVER'
        Get-MssqlServiceName -InstanceName 'mssqlserver' -Service agent | Should -Be 'SQLSERVERAGENT'
        Get-MssqlServiceName -InstanceName 'INST1' -Service engine | Should -Be 'MSSQL$INST1'
        Get-MssqlServiceName -InstanceName 'INST1' -Service agent | Should -Be 'SQLAgent$INST1'
        Get-MssqlServiceName -InstanceName 'INST1' -Service fulltext | Should -Be 'MSSQLFDLauncher$INST1'
    }

    It 'connects over shared memory to the instance on this host' {
        Get-MssqlConnectionString -InstanceName 'MSSQLSERVER' -HostName 'SQL01' | Should -Match '^Data Source=lpc:SQL01;Integrated Security=SSPI;'
        Get-MssqlConnectionString -InstanceName 'INST1' -HostName 'SQL01' | Should -Match '^Data Source=lpc:SQL01\\INST1;'
    }

    It 'takes the instance names setup takes' {
        foreach ($name in 'MSSQLSERVER', 'mssqlserver', 'INST1', '_A$1', 'ABCDEFGHIJKLMNOP') {
            Get-MssqlInstanceNameProblem $name | Should -Be ''
        }
        foreach ($name in '1INST', 'ABCDEFGHIJKLMNOPQ', 'Default', 'IN ST', '') {
            Get-MssqlInstanceNameProblem $name | Should -Not -Be ''
        }
    }

    It 'wants a password for an account, and none for a gMSA or built-in account' {
        Get-MssqlAccountProblem -Option 'engine' -Account '' -HasPassword $false | Should -Be ''
        Get-MssqlAccountProblem -Option 'engine' -Account '' -HasPassword $true | Should -Match 'without engine_account'
        Get-MssqlAccountProblem -Option 'engine' -Account 'EXAMPLE\svc' -HasPassword $true | Should -Be ''
        Get-MssqlAccountProblem -Option 'engine' -Account 'EXAMPLE\svc' -HasPassword $false | Should -Match 'needs engine_password'
        Get-MssqlAccountProblem -Option 'agent' -Account 'EXAMPLE\gmsa$' -HasPassword $false | Should -Be ''
        Get-MssqlAccountProblem -Option 'agent' -Account 'EXAMPLE\gmsa$' -HasPassword $true | Should -Match 'takes no password'
        Get-MssqlAccountProblem -Option 'agent' -Account 'NT SERVICE\SQLSERVERAGENT' -HasPassword $false | Should -Be ''
    }
}

Describe 'Get-MssqlRebootPendingReason' {
    It 'lists nothing when no marker is set, and each marker that is' {
        @(Get-MssqlRebootPendingReason -State @{}).Count | Should -Be 0
        $all = @{ ComponentBasedServicing = $true; WindowsUpdate = $true; FileRenames = $true; ComputerRename = $true }
        @(Get-MssqlRebootPendingReason -State $all).Count | Should -Be 4
    }
}

Describe 'Get-MssqlSetupSummary' {
    It 'reads the result, the exit message and every failed feature and rule' {
        $text = @'
Overall summary:
  Final result:                  Failed: see details below
  Exit code (Decimal):           -2068643839
  Exit message:                  Wait on the Database Engine recovery handle failed.
  Start time:                    2026-11-06 10:00:00

Feature:                       Database Engine Services
  Status:                        Failed
  Reason for failure:            An error occurred during the setup process of the feature.
  Error description:             Wait on the Database Engine recovery handle failed.
Feature:                       Replication
  Status:                        Passed

Rules with failures or warnings:
  Rule name:                     RebootRequiredCheck
  Result:                        Failed
  Message/Corrective Action:     A computer restart is required.
'@
        $summary = Get-MssqlSetupSummary -Text $text
        $summary.FinalResult | Should -Be 'Failed: see details below'
        $summary.ExitMessage | Should -Be 'Wait on the Database Engine recovery handle failed.'
        $summary.Failures | Should -Be @(
            'Database Engine Services: Wait on the Database Engine recovery handle failed.'
            'RebootRequiredCheck: A computer restart is required.'
        )
    }
}

Describe 'ConvertTo-MssqlInstanceFact' {
    It 'turns the registry and services into the modules'' facts' {
        $registry = @{
            Name = 'MSSQLSERVER'
            Id = 'MSSQL16.MSSQLSERVER'
            Setup = @{
                Edition = 'Developer Edition'
                Version = '16.0.1000.6'
                PatchLevel = '16.0.4135.4'
                Collation = 'SQL_Latin1_General_CP1_CI_AS'
                SQLDataRoot = 'C:\SQL'
            }
            ConfigurationState = @{ SQL_Engine_Core_Inst = 1; SQL_Replication_Core_Inst = 1 }
            Tcp = @{ Enabled = 1 }
            TcpAll = @{ TcpPort = '1433'; TcpDynamicPorts = '' }
            SuperSocketNetLib = @{ ForceEncryption = 0; Certificate = '' }
            Cluster = $null
        }
        $services = @{
            MSSQLSERVER = @{ State = 'Running'; StartMode = 'Auto'; Account = 'EXAMPLE\svc-sqldb' }
            SQLSERVERAGENT = @{ State = 'Stopped'; StartMode = 'Manual'; Account = 'EXAMPLE\gmsa-sqlagt$' }
        }
        $fact = ConvertTo-MssqlInstanceFact -Registry $registry -Services $services
        $fact.version | Should -Be '2022'
        $fact.version_number | Should -Be '16.0.4135.4'
        $fact.edition_id | Should -Be 'enterprise_developer'
        $fact.features | Should -Be @('SQLEngine', 'Replication')
        $fact.features_known | Should -BeTrue
        $fact.paths.data_root | Should -Be 'C:\SQL'
        $fact.clustered | Should -BeFalse
        $fact.tcp.enabled | Should -BeTrue
        $fact.tcp.port | Should -Be '1433'
        $fact.encryption.force_encryption | Should -BeFalse
        $fact.services.engine.state | Should -Be 'running'
        $fact.services.agent.start_mode | Should -Be 'manual'
        $fact.services.agent.account | Should -Be 'EXAMPLE\gmsa-sqlagt$'
        $fact.services.fulltext | Should -BeNullOrEmpty
    }

    It 'reads a missing key as empty, not as an error' {
        $fact = ConvertTo-MssqlInstanceFact -Registry @{ Name = 'INST1'; Id = 'MSSQL17.INST1' } -Services @{}
        $fact.version | Should -Be '2025'
        $fact.edition | Should -Be ''
        $fact.features | Should -Be @('SQLEngine')
        $fact.features_known | Should -BeFalse
        $fact.tcp.enabled | Should -BeFalse
    }
}
