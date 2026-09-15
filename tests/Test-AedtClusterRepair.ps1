#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $testsDir
$repairScript = Join-Path $rootDir 'Repair-AedtClusterNode.ps1'
$sandbox = Join-Path $env:TEMP ('MpiToolkitRepairTest_' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([string] $Name, [bool] $Condition)
    if ($Condition) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
    }
}

function Invoke-RepairFixture {
    param(
        [string] $AedtRoot,
        [string] $TempPath,
        [string] $ReportPath,
        [switch] $NetworkPlan
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "' + $repairScript +
        '" -AedtRoot "' + $AedtRoot + '" -TempDirectory "' + $TempPath +
        '" -ReportDirectory "' + $ReportPath + '" -SkipAdminCheck -SkipServiceChanges -SkipConnectivityChecks'
    if ($NetworkPlan) { $info.Arguments += ' -ConfigureNetworkPorts -NetworkPlanOnly' }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $null = $process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -and $stderr) { Write-Host ('  子程序：' + $stderr.Trim()) -ForegroundColor DarkYellow }
    return $process.ExitCode
}


# ---------------------------------------------------------------------------
#  連接埠範圍：不能寫死
#
#  實機事故：修復把 I_MPI_PORT_RANGE 設成 55500:55999，但那台 Windows 的保留區
#  含 55414-55513，於是 55500 bind 不起來（WSAEACCES / 10013）。
#  Intel MPI 只試範圍的第一個埠，撞到就放棄不往後找，結果連本機單機都跑不起來，
#  而錯誤訊息講的是「cannot launch processes on remote host」——完全指錯方向。
#
#  這些保留區由 Hyper-V／WinNAT／WSL 產生，每台不同、重開機後還會變，
#  所以只能現查現挑。下面測的是挑選邏輯本身。
# ---------------------------------------------------------------------------
$repairSrc = Get-Content -LiteralPath $repairScript -Raw
$fnStart = $repairSrc.IndexOf('function Get-ExcludedTcpRange')
$fnEnd   = $repairSrc.IndexOf('function Get-HydraServicePort')
if ($fnStart -lt 0 -or $fnEnd -le $fnStart) {
    Write-Host '  [FAIL] 取不到連接埠挑選函式' -ForegroundColor Red
    $script:Fail++
} else {
    Invoke-Expression $repairSrc.Substring($fnStart, $fnEnd - $fnStart)

    $fake = @(
        [pscustomobject]@{ Start = 55414; End = 55513 },
        [pscustomobject]@{ Start = 49685; End = 49784 }
    )
    # 這就是實機那一組：範圍開頭落在保留區裡
    Assert-True '開頭落在保留區要判定為不可用' (-not (Test-PortRangeClear -Start 55500 -End 55999 -Excluded $fake))
    # 尾端落在保留區裡也一樣不能用
    Assert-True '尾端落在保留區要判定為不可用' (-not (Test-PortRangeClear -Start 55000 -End 55499 -Excluded $fake))
    # 保留區整段被包在中間
    Assert-True '保留區被包在中間也不可用'     (-not (Test-PortRangeClear -Start 55000 -End 55999 -Excluded $fake))
    # 完全不相交才算可用
    Assert-True '不相交才算可用'               (Test-PortRangeClear -Start 56000 -End 56499 -Excluded $fake)
    Assert-True '緊鄰但不重疊算可用'           (Test-PortRangeClear -Start 55514 -End 55999 -Excluded $fake)
    Assert-True '沒有保留區時都可用'           (Test-PortRangeClear -Start 55500 -End 55999 -Excluded @())

    # bind 檢查一律回 True，這樣測的是挑選邏輯而不是這台機器當下的通訊埠狀況
    $alwaysBindable = { param($Port) $true }
    $plan = Select-ToolkitPortPlan -Excluded $fake -BindTest $alwaysBindable
    Assert-True '撞到保留區時要換一組'         ($plan.Found -and -not $plan.IsDefault)
    Assert-True '換到的那組不會再撞'           (Test-PortRangeClear -Start ([int]($plan.MpiRange -split ':')[0]) `
                                                                   -End   ([int]($plan.MpiRange -split ':')[1]) -Excluded $fake)
    Assert-True '兩段範圍不重疊'               ([int]($plan.ComRange -split ':')[1] -lt [int]($plan.MpiRange -split ':')[0])
    Assert-True '防火牆規則用連字號格式'       ($plan.MpiRule -match '^\d+-\d+$')
    Assert-True '環境變數用冒號格式'           ($plan.MpiRange -match '^\d+:\d+$')

    # 沒有保留區時應該維持預設那一組，不要無故換
    $planDefault = Select-ToolkitPortPlan -Excluded @() -BindTest $alwaysBindable
    Assert-True '沒有衝突時維持預設範圍'       ($planDefault.Found -and $planDefault.IsDefault)

    # 保留清單查不到、但那個埠就是 bind 不起來（被別的程式占住）時也要換一組。
    # 只看保留清單是不夠的——實機就是靠真的去 bind 才發現問題。
    $firstBlockBusy = {
        param($Port)
        if ($Port -eq 55000 -or $Port -eq 55500) { return $false }
        return $true
    }
    $planBusy = Select-ToolkitPortPlan -Excluded @() -BindTest $firstBlockBusy
    Assert-True 'bind 不起來時也要換一組'       ($planBusy.Found -and -not $planBusy.IsDefault)
}

Write-Host ''
Write-Host 'AEDT 串機本機修復測試' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray

try {
    New-Item -ItemType Directory -Path $sandbox | Out-Null
    $aedtRoot = Join-Path $sandbox 'AnsysEM'
    $configDir = Join-Path $aedtRoot 'config'
    $tempPath = Join-Path $sandbox 'AedtTemp'
    $reportPath = Join-Path $sandbox 'reports'
    New-Item -ItemType Directory -Path $configDir | Out-Null
    @("`$begin 'Config'", "`ttempdirectory='C:/Users/OldUser/AppData/Local/Temp'", "`$end 'Config'") |
        Out-File -LiteralPath (Join-Path $configDir 'default.cfg') -Encoding ascii

    $exit1 = Invoke-RepairFixture -AedtRoot $aedtRoot -TempPath $tempPath -ReportPath $reportPath
    $cfg = Get-Content -LiteralPath (Join-Path $configDir 'default.cfg') -Raw
    $reports = @(Get-ChildItem -LiteralPath $reportPath -Filter '*.json' -File | Sort-Object LastWriteTime)
    $first = Get-Content -LiteralPath $reports[-1].FullName -Raw | ConvertFrom-Json
    Assert-True '第一次修復成功' ($exit1 -eq 0)
    Assert-True 'tempdirectory 已改成指定的 ASCII 本機路徑' ($cfg -match [regex]::Escape($tempPath.Replace('\','/')))
    Assert-True '共同 TEMP 已建立' (Test-Path -LiteralPath $tempPath -PathType Container)
    Assert-True '原始 default.cfg 已備份' (Test-Path -LiteralPath $first.backupPath -PathType Leaf)
    Assert-True '報告確認設定有效' ($first.configVerified -eq $true)

    Start-Sleep -Milliseconds 1100
    $exit2 = Invoke-RepairFixture -AedtRoot $aedtRoot -TempPath $tempPath -ReportPath $reportPath
    $reports = @(Get-ChildItem -LiteralPath $reportPath -Filter '*.json' -File | Sort-Object LastWriteTime)
    $second = Get-Content -LiteralPath $reports[-1].FullName -Raw | ConvertFrom-Json
    Assert-True '重複執行仍成功' ($exit2 -eq 0)
    Assert-True '重複執行不會再次改寫設定' ($second.configChanged -eq $false)
    Assert-True '每次執行都保留獨立備份' ($first.backupPath -ne $second.backupPath)

    Start-Sleep -Milliseconds 1100
    $exitNetwork = Invoke-RepairFixture -AedtRoot $aedtRoot -TempPath $tempPath -ReportPath $reportPath -NetworkPlan
    $reports = @(Get-ChildItem -LiteralPath $reportPath -Filter '*.json' -File | Sort-Object LastWriteTime)
    $network = Get-Content -LiteralPath $reports[-1].FullName -Raw | ConvertFrom-Json
    Assert-True '網路修復規劃模式不變更系統且成功' ($exitNetwork -eq 0 -and $network.networkPlanOnly -eq $true)
    # 範圍不再寫死——會避開 Windows 保留埠，所以只能驗格式與一致性，不能驗特定數字。
    $comTarget = [string]$network.networkSettings.ANSYSEM_LISTEN_PORT_RANGE.target
    $mpiTarget = [string]$network.networkSettings.I_MPI_PORT_RANGE.target
    Assert-True 'AnsoftCOM 連接埠範圍格式正確' ($comTarget -match '^\d+:\d+$')
    Assert-True 'Intel MPI 連接埠範圍格式正確' ($mpiTarget -match '^\d+:\d+$')
    Assert-True '兩段連接埠範圍不重疊' `
        ([int]($comTarget -split ':')[1] -lt [int]($mpiTarget -split ':')[0])
    # 防火牆規則開的必須就是環境變數設的那一段，否則規則開了也沒用
    $comRule = @($network.firewallRules | Where-Object { $_.displayName -match 'AnsoftCOM' })[0]
    $mpiRule = @($network.firewallRules | Where-Object { $_.displayName -match 'Intel MPI' })[0]
    Assert-True '防火牆開的就是環境變數那一段（AnsoftCOM）' `
        ([string]$comRule.localPort -eq ($comTarget -replace ':', '-'))
    Assert-True '防火牆開的就是環境變數那一段（Intel MPI）' `
        ([string]$mpiRule.localPort -eq ($mpiTarget -replace ':', '-'))
    Assert-True 'RSM MPI 執行目錄指向 AEDT 安裝目錄' ($network.networkSettings.ANSYS_EM_EXEC_DIR.target -eq $aedtRoot)
    Assert-True '包含 RSM、Hydra、AnsoftCOM 與 MPI 防火牆規則' (@($network.firewallRules).Count -eq 4)
    Assert-True '防火牆規則只允許網域／私人設定檔與本機子網路' (
        @($network.firewallRules | Where-Object { $_.Profiles -ne 'Domain,Private' -or $_.RemoteAddress -ne 'LocalSubnet' }).Count -eq 0)

    $aedtRoot2 = Join-Path $sandbox 'AnsysEM_NoTempLine'
    $configDir2 = Join-Path $aedtRoot2 'config'
    $tempPath2 = Join-Path $sandbox 'AedtTemp2'
    $reportPath2 = Join-Path $sandbox 'reports2'
    New-Item -ItemType Directory -Path $configDir2 | Out-Null
    @("`$begin 'Config'", "`$end 'Config'") | Out-File -LiteralPath (Join-Path $configDir2 'default.cfg') -Encoding ascii
    $exit3 = Invoke-RepairFixture -AedtRoot $aedtRoot2 -TempPath $tempPath2 -ReportPath $reportPath2
    $cfg2 = Get-Content -LiteralPath (Join-Path $configDir2 'default.cfg') -Raw
    Assert-True '沒有 tempdirectory 時會安全加入設定' ($exit3 -eq 0 -and $cfg2 -match 'tempdirectory=' -and $cfg2 -match '\$end ''Config''')

    $bad = Invoke-RepairFixture -AedtRoot $aedtRoot -TempPath (Join-Path $sandbox '中文') -ReportPath $reportPath
    Assert-True '中文 Ansys TEMP 路徑會被拒絕' ($bad -ne 0)
} finally {
    $resolved = [IO.Path]::GetFullPath($sandbox)
    $tempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -like 'MpiToolkitRepairTest_*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
