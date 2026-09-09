#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $testsDir
$guiSourcePath = Join-Path $rootDir 'MpiToolkit-GUI.ps1'
$launcherPath = Join-Path $rootDir 'Run-MpiToolkit-GUI.bat'
$guidePath = Join-Path $rootDir 'docs\AEDT_2026R1_Two_PC_Setup_Guide.html'
$mpiCredentialPath = Join-Path $rootDir 'Register-IntelMpiCredential.ps1'

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

Write-Host ''
Write-Host 'GUI 靜態與相容性測試' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray
$source = Get-Content -LiteralPath $guiSourcePath -Raw -Encoding UTF8
$launcher = Get-Content -LiteralPath $launcherPath -Raw
$guide = Get-Content -LiteralPath $guidePath -Raw -Encoding UTF8
$mpiCredential = Get-Content -LiteralPath $mpiCredentialPath -Raw -Encoding UTF8
$guiBytes = [IO.File]::ReadAllBytes($guiSourcePath)
$tokens = $null
$parseErrors = $null
[Management.Automation.Language.Parser]::ParseFile($guiSourcePath, [ref]$tokens, [ref]$parseErrors) | Out-Null

Assert-True '無 EXE 的 GUI 腳本已產生' (Test-Path -LiteralPath $guiSourcePath -PathType Leaf)
Assert-True 'GUI 腳本可由 PowerShell 5.1 解析' ($parseErrors.Count -eq 0)
Assert-True 'GUI 腳本是 UTF-8 with BOM' ($guiBytes.Length -gt 3 -and $guiBytes[0] -eq 0xEF -and $guiBytes[1] -eq 0xBB -and $guiBytes[2] -eq 0xBF)
Assert-True '有節點檢查頁' ($source -match '① 節點檢查')
Assert-True '有彙整報告頁' ($source -match '② 彙整報告')
Assert-True '有建立串機設定頁' ($source -match '③ 建立串機設定')
Assert-True '有套用與驗證頁' ($source -match '④ 套用與驗證')
Assert-True '有連線修復頁' ($source -match '⑤ 連線修復')
Assert-True '資料夾輸入提供瀏覽按鈕' ($source -match 'FolderBrowserDialog')
Assert-True 'AEDT 專案提供檔案選取器' ($source -match 'OpenFileDialog')
Assert-True 'GUI 顯示本機電腦名稱' ($source -match '\$env:COMPUTERNAME')
Assert-True '會檢查 Ansys 路徑為 ASCII' ($source -match 'Test-AsciiPath')
Assert-True '節點檢查仍呼叫既有核心' ($source -match "Start-ToolProcess 'Test-AedtCluster\.ps1'")
Assert-True '設定產生仍呼叫既有核心' ($source -match "Start-ToolProcess 'New-AedtClusterConfig\.ps1'")
Assert-True '可從 GUI 執行命令選項驗證' ($source -match 'verify-batchoptions\.cmd')
Assert-True '可從 GUI 複製 Machine List 參數' ($source -match "Clipboard\]::SetText\('-MachineList file=")
Assert-True '可從 GUI 開啟完整操作說明' ($source -match 'START_HERE\.html')
Assert-True '可從 GUI 以管理員權限執行本機修復' ($source -match "Start-ElevatedRepair" -and $source -match "Repair-AedtClusterNode\.ps1" -and $source -match 'Verb RunAs')
Assert-True 'GUI 可套用固定連接埠與防火牆修復' ($source -match 'ConfigureNetworkPorts' -and $source -match '完整修復')
Assert-True 'GUI 修復不會改 hosts' ($source -match '不會改 hosts')
Assert-True 'GUI 有 Intel MPI 帳密註冊與驗證按鈕' ($source -match '註冊 MPI 帳密並驗證' -and $source -match 'Register-IntelMpiCredential\.ps1')
Assert-True 'MPI 密碼不放進命令列' ($mpiCredential -match 'RedirectStandardInput' -and $mpiCredential -notmatch "Arguments\s*=.*-password")
Assert-True 'MPI 密碼使用 SecureString 並清除記憶體' ($mpiCredential -match 'SecureStringToBSTR' -and $mpiCredential -match 'ZeroFreeBSTR')
Assert-True 'MPI 註冊會送出密碼與確認密碼' ($mpiCredential -match 'InputLines' -and $mpiCredential -match '\$plainPassword,\s*\$plainPassword')
Assert-True 'MPI 註冊失敗會顯示 GUI 訊息' ($mpiCredential -match 'trap\s*\{' -and $mpiCredential -match 'MessageBox')
Assert-True 'MPI 註冊後會驗證對端' ($mpiCredential -match "-validate -host")
Assert-True '主視窗有即時響應式重排' ($source -match 'Update-ResponsiveLayout' -and $source -match 'Add_Resize')
Assert-True '主頁籤與日誌會隨視窗伸縮' ($source -match '\$tabs\.Anchor.*Right' -and $source -match '\$logBox\.Anchor.*Bottom')
Assert-True '縮小視窗時分頁可捲動' ($source -match 'AutoScrollMinSize')
Assert-True '路徑欄位會水平延展' ($source -match '\$box\.Anchor.*Right' -and $source -match '\$browse\.Anchor.*Right')
Assert-True '同事版說明沒有 PowerShell 指令' ($guide -notmatch '(?i)powershell|<pre>|Set-Location|Get-Service')
Assert-True '同事版說明完整涵蓋四個 GUI 頁面' ($guide -match '① 節點檢查' -and $guide -match '② 彙整報告' -and $guide -match '③ 建立串機設定' -and $guide -match '④ 套用與驗證')
Assert-True '同事版說明包含 GUI ⑤ 連線修復' ($guide -match 'GUI ⑤：TEMP 不一致或求解卡住時修復' -and $guide -match 'C:\\AnsysWork\\AedtTemp')
Assert-True '同事版說明包含固定連接埠與防火牆範圍' ($guide -match '55000.*55499' -and $guide -match '55500.*55999' -and $guide -match '32958')
Assert-True '同事版說明已納入 MPI 帳密註冊' ($guide -match '註冊 MPI 帳密並驗證' -and $guide -match 'Domain\\user' -and $guide -notmatch '不要直接沿用舊 SOP')
Assert-True 'GUI 第三步是主流程獨立章節' ($guide -match '<section id="s5">\s*<h2[^>]*><span[^>]*>5</span>GUI ③：建立串機設定')
$step3Index = $guide.IndexOf('GUI ③：建立串機設定')
$step4Index = $guide.IndexOf('GUI ④：套用到 AEDT 並驗證')
$solveIndex = $guide.IndexOf('跑兩次小模型')
Assert-True '操作順序為 GUI ③、GUI ④、實際求解' ($step3Index -ge 0 -and $step4Index -gt $step3Index -and $solveIndex -gt $step4Index)
Assert-True '執行期間禁止關閉 GUI' ($source -match '工具仍在執行，完成後才能關閉')
Assert-True '啟動器改用無 EXE GUI' ($launcher -match 'MpiToolkit-GUI\.ps1' -and $launcher -notmatch 'MpiToolkitGui\.exe')
Assert-True '啟動器不要求使用者輸入命令' ($launcher -match '-WindowStyle Hidden' -and $launcher -match '-Sta')
$launcherBytes = [IO.File]::ReadAllBytes($launcherPath)
Assert-True '啟動器全 ASCII' (@($launcherBytes | Where-Object { $_ -gt 127 }).Count -eq 0)

Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
