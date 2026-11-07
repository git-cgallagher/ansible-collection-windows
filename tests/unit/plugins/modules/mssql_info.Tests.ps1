# Pester 5 unit tests for mssql_info's wiring to plugins/module_utils/
# _MssqlCommon.psm1, whose readers and conversions _MssqlCommon.Tests.ps1
# tests. The module's behaviour against SQL Server is its integration target
# (tests/integration/targets/mssql_info). Run with Invoke-Pester -Path
# tests/unit.

BeforeAll {
    $script:repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../../..')).Path
    $script:modulePath = Join-Path $script:repoRoot 'plugins/modules/mssql_info.ps1'
    $script:util = Import-Module (Join-Path $script:repoRoot 'plugins/module_utils/_MssqlCommon.psm1') -Force -PassThru
    $script:text = Get-Content -LiteralPath $script:modulePath -Raw
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:modulePath, [ref]$null, [ref]$null)
    $script:defined = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
            ForEach-Object { $_.Name })
}

AfterAll {
    Remove-Module _MssqlCommon -ErrorAction SilentlyContinue
}

Describe 'mssql_info''s wiring' {
    It 'loads the shared util' {
        $script:text | Should -Match '(?m)^#AnsibleRequires -PowerShell \.\.module_utils\._MssqlCommon$'
    }

    It 'defines none of the util''s functions itself' {
        foreach ($name in $script:util.ExportedFunctions.Keys) {
            $script:defined | Should -Not -Contain $name
        }
    }

    It 'reads instances the way mssql_setup does' {
        $script:text | Should -Match 'Get-MssqlInstanceRegistry'
        $script:text | Should -Match 'ConvertTo-MssqlInstanceFact -Registry \$entry'
        $script:text | Should -Match 'Get-MssqlConnectionString -InstanceName'
    }

    It 'never reports a change' {
        $script:text | Should -Match '\$module\.Result\.changed = \$false'
        $script:text | Should -Not -Match '\$module\.Result\.changed = \$true'
    }
}
