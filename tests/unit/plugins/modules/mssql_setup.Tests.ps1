# Pester 5 unit tests for mssql_setup's wiring to plugins/module_utils/
# _MssqlCommon.psm1, whose decisions (the plan, editions, media, setup's
# command line) _MssqlCommon.Tests.ps1 tests. The module's behaviour against
# SQL Server is its integration target (tests/integration/targets/
# mssql_setup). Run with Invoke-Pester -Path tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/mssql_setup.ps1'
    $script:util = Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_MssqlCommon.psm1') -Force -PassThru
    $script:text = Get-Content -LiteralPath $script:modulePath -Raw
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
    $script:defined = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
}

AfterAll {
    Remove-Module _MssqlCommon -ErrorAction SilentlyContinue
}

Describe 'mssql_setup''s wiring' {
    It 'loads the shared util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._MssqlCommon$'
    }

    It 'defines none of the util''s functions itself' {
        foreach ($name in $script:util.ExportedFunctions.Keys) {
            $script:defined | Should -Not -Contain $name
        }
    }

    It 'plans with Get-MssqlInstancePlan and builds setup''s command line with the util' {
        $script:text | Should -Match 'Get-MssqlInstancePlan -InstanceName \$instanceName -Desired \$desired -Installed \$installed'
        $script:text | Should -Match 'Get-MssqlSetupArgument -Action'
        $script:text | Should -Match 'Format-MssqlSetupArgument -Arguments \$Arguments -Redact'
    }

    It 'offers exactly the features the util knows' {
        $choices = [regex]::Match($script:text, "features = @\{[^}]*choices = @\(([^)]*)\)").Groups[1].Value -replace "[' ]", ''
        $known = & $script:util { $script:MssqlFeatures.Keys -join ',' }
        $choices | Should -Be $known
    }

    It 'never returns or prints a secret option' {
        foreach ($option in 'product_key', 'engine_password', 'agent_password') {
            $script:text | Should -Match "$option = @\{ type = 'str'; no_log = \`$true \}"
        }
        $script:text | Should -Match '\$module\.FailJson\(\(Hide-Secret \$msg\), \$_\)'
    }
}
