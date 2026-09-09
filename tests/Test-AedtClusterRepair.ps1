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
    Assert-True 'AnsoftCOM 連接埠範圍固定' ($network.networkSettings.ANSYSEM_LISTEN_PORT_RANGE.target -eq '55000:55499')
    Assert-True 'Intel MPI 連接埠範圍固定' ($network.networkSettings.I_MPI_PORT_RANGE.target -eq '55500:55999')
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
