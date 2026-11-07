# Pester 5 unit tests for mssql_network's wiring to plugins/module_utils/
# _MssqlCommon.psm1, whose decisions (the registry plan, the certificate
# checks, the errorlog, the firewall rules) _MssqlCommon.Tests.ps1 tests.
# The module's behaviour against SQL Server is its integration target
# (tests/integration/targets/mssql_network). Run with Invoke-Pester -Path
# tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/mssql_network.ps1'
    $script:util = Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_MssqlCommon.psm1') -Force -PassThru
    $script:text = Get-Content -LiteralPath $script:modulePath -Raw
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
    $script:defined = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
}

AfterAll {
    Remove-Module _MssqlCommon -ErrorAction SilentlyContinue
}

Describe 'mssql_network''s wiring' {
    It 'loads the shared util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._MssqlCommon$'
    }

    It 'defines none of the util''s functions itself' {
        foreach ($name in $script:util.ExportedFunctions.Keys) {
            $script:defined | Should -Not -Contain $name
        }
    }

    It 'plans the registry writes with the util, after checking the certificate' {
        $check = $script:text.IndexOf('Get-MssqlCertificateProblem -Certificate $certificate')
        $plan = $script:text.IndexOf('Get-MssqlNetworkPlan -Current $registry.Current')
        $check | Should -BeGreaterThan 0
        $plan | Should -BeGreaterThan $check
    }

    It 'requires a certificate for mandatory and strict' {
        $script:text | Should -Match "@\('encryption', 'mandatory', @\('certificate_thumbprint'\)\)"
        $script:text | Should -Match "@\('encryption', 'strict', @\('certificate_thumbprint'\)\)"
    }

    # Variable names ignore case, so a $change or $description inside a script
    # block that Invoke-Change runs would read Invoke-Change's own parameters.
    It 'never hands Invoke-Change a script block that reads its parameters'' names' {
        $calls = @($script:ast.FindAll({
                    param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Change'
                }, $true))
        $calls.Count | Should -BeGreaterThan 3
        foreach ($call in $calls) {
            $names = @($call.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                    ForEach-Object { $_.VariablePath.UserPath.ToLowerInvariant() })
            $names | Should -Not -Contain 'change'
            $names | Should -Not -Contain 'description'
        }
    }
}
