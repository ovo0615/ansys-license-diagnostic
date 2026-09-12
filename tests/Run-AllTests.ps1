#Requires -Version 5.1
<#
.SYNOPSIS
    跑完本版本庫所有測試。

.DESCRIPTION
    CI 跑的是同一支，所以本機過了 CI 就會過。

    這裡的測試都不碰真實機器、不需要 Ansys、不需要 Windows——
    刻意設計成這樣，才能在每次提交時真的跑。

    **沒有被測到的部分**（只能在真的 Windows 工作站上驗）：
      - Check-AnsysLicense.ps1 的全部
      - Test-AedtCluster.ps1 的節點收集模式
    見 docs\AEDT串機工具設計.md 第七節。

.EXAMPLE
    .\tests\Run-AllTests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$suites = @(
    'Test-AedtClusterMerge.ps1',
    'Test-AedtClusterConfig.ps1',
    'Test-Anonymization.ps1',
    'Test-AedtClusterRepair.ps1',
    'Test-Gui.ps1',
    'Test-OneClickCluster.ps1',
    # 偵測器自己也要被測。Check-Ps51Compat.ps1 若永遠回綠燈，它就只是個
    # 假保險——曾經真的這樣過：?. 的偵測在 5.1 上是死的，但檢查照樣全過。
    'Test-Ps51Compat.ps1'
)

$failed = @()

foreach ($s in $suites) {
    $p = Join-Path $TestsDir $s
    if (-not (Test-Path -LiteralPath $p)) {
        Write-Host ('找不到測試：' + $s) -ForegroundColor Red
        $failed += $s
        continue
    }
    try {
        $global:LASTEXITCODE = 0
        & $p
        $suiteExitCode = $LASTEXITCODE
        if ($suiteExitCode -ne 0) { $failed += $s }
    } catch {
        Write-Host ('測試發生例外：' + $s) -ForegroundColor Red
        Write-Host ('  ' + $_.Exception.Message) -ForegroundColor Red
        $failed += $s
    }
}

Write-Host ('=' * 60) -ForegroundColor White
if ($failed.Count -eq 0) {
    Write-Host ('  ' + $suites.Count + ' 組測試全部通過。') -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host ('  以下測試失敗：' + ($failed -join '、')) -ForegroundColor Red
Write-Host ''
exit 1
