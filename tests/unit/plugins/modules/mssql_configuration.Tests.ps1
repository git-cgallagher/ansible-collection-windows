# Pester 5 unit tests for mssql_configuration's wiring to
# plugins/module_utils/_MssqlCommon.psm1, whose decisions (the sp_configure
# plan and batch, the tempdb plan, the value checks) _MssqlCommon.Tests.ps1
# tests. The module's behaviour against SQL Server is its integration target
# (tests/integration/targets/mssql_configuration). Run with Invoke-Pester
# -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/mssql_configuration.ps1'
    $script:util = Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_MssqlCommon.psm1') -Force -PassThru
    $script:text = Get-Content -LiteralPath $script:modulePath -Raw
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
    $script:defined = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
}

AfterAll {
    Remove-Module _MssqlCommon -ErrorAction SilentlyContinue
}

Describe 'mssql_configuration''s wiring' {
    It 'loads the shared util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._MssqlCommon$'
    }

    It 'defines none of the util''s functions itself' {
        foreach ($name in $script:util.ExportedFunctions.Keys) {
            $script:defined | Should -Not -Contain $name
        }
    }

    # A util function the util doesn't export fails only on a real host.
    It 'calls only util functions the util exports' {
        $called = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -like '*-Mssql*' } | Sort-Object -Unique)
        $called.Count | Should -BeGreaterThan 5
        foreach ($name in $called) {
            @($script:util.ExportedFunctions.Keys) | Should -Contain $name
        }
    }

    It 'plans with the util, and refuses before the first write' {
        $plan = $script:text.IndexOf('Get-MssqlConfigurationPlan -Current $state.Rows')
        $tempdb = $script:text.IndexOf('Get-MssqlTempdbPlan -Files $state.Files')
        $settings = $script:text.IndexOf('lacks ALTER SETTINGS')
        $alter = $script:text.IndexOf('lacks ALTER on tempdb')
        $write = $script:text.IndexOf('Invoke-MssqlNonQuery')
        foreach ($index in $plan, $tempdb, $settings, $alter) {
            $index | Should -BeGreaterThan 0
            $write | Should -BeGreaterThan $index
        }
    }

    It 'writes only outside check mode' {
        $script:text | Should -Match 'if \(-not \$checkMode\) \{ Invoke-MssqlNonQuery -ConnectionString \$connection -Query \$batch\.Text'
        @([regex]::Matches($script:text, 'Invoke-MssqlNonQuery')).Count | Should -Be 2
    }

    It 'restarts through the util, with the timeout asked for' {
        $script:text | Should -Match 'Restart-MssqlEngine -EngineName \$engineName'
        $script:text | Should -Match '-Timeout \$params\.restart_timeout'
    }

    It 'says strict encryption is why it can''t connect' {
        $script:text | Should -Match 'uses strict encryption \(Force Strict Encryption\)'
    }

    # Variable names ignore case, so a $change or $description inside a script
    # block that Invoke-Change runs would read Invoke-Change's own parameters.
    It 'never hands Invoke-Change a script block that reads its parameters'' names' {
        $calls = @($script:ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Change'
                }, $true))
        $calls.Count | Should -BeGreaterThan 1
        foreach ($call in $calls) {
            $names = @($call.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                    ForEach-Object { $_.VariablePath.UserPath.ToLowerInvariant() })
            $names | Should -Not -Contain 'change'
            $names | Should -Not -Contain 'description'
        }
    }
}
