#Requires -Version 5.1
<#
.SYNOPSIS
    依串機檢查結果產生機器清單與批次求解命令 —— 虎門科技股份有限公司

.DESCRIPTION
    吃 Test-AedtCluster.ps1 產生的 .node.json，輸出可以直接用的：

      machines.txt              -MachineList file= 用的機器清單
      run-batch.cmd             批次分散求解的命令列
      verify-batchoptions.cmd   第一次使用前的選項驗證步驟
      待辦清單.txt              還缺什麼才能真的跑起來

    本工具唯讀，只產生檔案，不碰任何機器、也不會送出任何求解。

    產生的 run-batch.cmd 預設是**註解掉的**。這不是保守，是因為 AEDT 命令列
    選項的確切拼法在各版本之間有差異，本工具依公開文件產生但**尚未在實機驗證**。
    請先跑 verify-batchoptions.cmd 對照該版本實際支援的選項，確認後再解開註解。

    猜錯選項產出的批次檔會直接失敗，比沒有還糟——所以寧可多一步。

.PARAMETER From
    節點報告所在的資料夾（或多個 .node.json 路徑）。與 Test-AedtCluster.ps1
    的 -Merge 吃同一批檔案。

.PARAMETER Project
    要批次求解的 .aedt 專案檔路徑。未指定時產生的命令列會留成 <專案檔路徑>
    佔位字串，由使用者自己填。

.PARAMETER TasksPerNode
    每台機器要跑幾個 task，預設 1。

.PARAMETER CoresPerNode
    每台機器要用幾個核心。未指定時取各節點回報的實體核心數。

.PARAMETER Ratio
    每台機器的資源使用上限百分比，預設 90。

.PARAMETER IncludeUnready
    連檢查未過的機器也一起列進去。預設會排除，並在待辦清單說明原因。

.PARAMETER OutDir
    輸出目錄，預設為腳本所在目錄下的 cluster-config\。

.EXAMPLE
    .\New-AedtClusterConfig.ps1 -From .\reports
    依節點報告產生設定，專案檔留待填寫。

.EXAMPLE
    .\New-AedtClusterConfig.ps1 -From .\reports -Project D:\work\ant.aedt -CoresPerNode 16

.NOTES
    虎門科技股份有限公司 Taiwan Auto-Design Co.
    技術支援：cae-support@cadmen.com

    命令列選項的依據見 docs\AEDT串機工具設計.md 第三節與第七節。
    .acf（分析組態檔）本工具不產生，理由見輸出的待辦清單。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $From,
    [string]   $Project,
    [int]      $TasksPerNode = 1,
    [int]      $CoresPerNode = 0,
    [int]      $Ratio = 90,
    [switch]   $IncludeUnready,
    [string]   $OutDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$TOOL_NAME    = 'AEDT 串機設定產生器'
$TOOL_VERSION = '0.1.0'
$VENDOR_NAME  = '虎門科技股份有限公司'
$VENDOR_MAIL  = 'cae-support@cadmen.com'
$NODE_SCHEMA  = 1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $ScriptDir 'cluster-config' }

Write-Host ''
Write-Host ('  ' + $TOOL_NAME + '  v' + $TOOL_VERSION) -ForegroundColor White
Write-Host ('  ' + $VENDOR_NAME) -ForegroundColor DarkGray
Write-Host '  本工具唯讀，只產生檔案，不會送出任何求解。' -ForegroundColor Green
Write-Host ''

# ---------------------------------------------------------------------------
#  讀取節點報告
# ---------------------------------------------------------------------------
$files = @()
foreach ($p in $From) {
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if (Test-Path -LiteralPath $p -PathType Container) {
        $files += @(Get-ChildItem -LiteralPath $p -Filter '*.node.json' -File -ErrorAction SilentlyContinue |
                    ForEach-Object { $_.FullName })
    } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
        $files += $p
    } else {
        Write-Host ('  找不到：' + $p) -ForegroundColor Yellow
    }
}
$files = @($files | Select-Object -Unique)

if ($files.Count -eq 0) {
    Write-Host '  沒有找到任何 .node.json。' -ForegroundColor Red
    Write-Host '  請先在每台機器上執行 Test-AedtCluster.ps1，把報告收到同一個資料夾。' -ForegroundColor Yellow
    Write-Host ''
    exit 2
}

$nodes = @()
foreach ($f in $files) {
    try {
        $obj = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host ('  讀取失敗（略過）：' + (Split-Path -Leaf $f)) -ForegroundColor Yellow
        continue
    }
    if (-not $obj.node) {
        Write-Host ('  不是節點報告（略過）：' + (Split-Path -Leaf $f)) -ForegroundColor Yellow
        continue
    }
    if ($obj.schemaVersion -ne $NODE_SCHEMA) {
        Write-Host ('  schema 版本不符（略過）：' + $obj.node.computerName) -ForegroundColor Yellow
        continue
    }
    $nodes += $obj
}

if ($nodes.Count -eq 0) {
    Write-Host '  沒有可用的節點報告。' -ForegroundColor Red
    Write-Host ''
    exit 2
}

$caseId = @($nodes | ForEach-Object { $_.caseId } | Select-Object -Unique)[0]

# ---------------------------------------------------------------------------
#  逐台判斷可不可以列進機器清單
#
#  只擋「這台一定跑不起來」的硬條件。跨機一致性（版本、路徑、temp）的判斷
#  留給 Test-AedtCluster.ps1 -Merge，不在這裡重做一遍。
# ---------------------------------------------------------------------------
$entries = @()
foreach ($n in $nodes) {
    $name    = [string]$n.node.computerName
    $blocked = @()

    if (-not $n.node.aedt -or @($n.node.aedt).Count -eq 0) { $blocked += '沒有偵測到 AEDT' }
    if (-not $n.node.rsm.running) { $blocked += 'RSM 服務未執行' }

    $mpiRunning = @($n.node.mpi.detected | Where-Object { $_.running })
    if (@($n.node.mpi.detected).Count -eq 0) {
        $blocked += '沒有偵測到 MPI'
    } elseif ($mpiRunning.Count -eq 0) {
        $blocked += 'MPI 服務未執行'
    }

    $cores = $CoresPerNode
    if ($cores -le 0) {
        $cores = [int]$n.node.physicalCores
        if ($cores -le 0) { $cores = [int]$n.node.logicalCores }
    }
    if ($cores -le 0) {
        $blocked += '讀不到核心數，無法決定要配幾核'
        $cores = 0
    }

    $entries += [pscustomobject]@{
        Name    = $name
        Cores   = $cores
        Tasks   = $TasksPerNode
        Ready   = ($blocked.Count -eq 0)
        Blocked = $blocked
    }
}

$ready   = @($entries | Where-Object { $_.Ready })
$unready = @($entries | Where-Object { -not $_.Ready })
$use     = if ($IncludeUnready) { $entries } else { $ready }

foreach ($e in $entries) {
    if ($e.Ready) {
        Write-Host ('  可用  ' + $e.Name.PadRight(16) + $e.Cores + ' 核 / ' + $e.Tasks + ' task') -ForegroundColor Green
    } else {
        Write-Host ('  排除  ' + $e.Name.PadRight(16) + ($e.Blocked -join '、')) -ForegroundColor Yellow
    }
}
Write-Host ''

if ($use.Count -eq 0) {
    Write-Host '  沒有任何一台通過基本檢查，不產生設定檔。' -ForegroundColor Red
    Write-Host '  請先跑 Test-AedtCluster.ps1 -Merge 看完整的原因與處理方式。' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$projectArg = if ([string]::IsNullOrWhiteSpace($Project)) { '<專案檔路徑.aedt>' } else { $Project }

# ---------------------------------------------------------------------------
#  machines.txt
#
#  檔案格式在官方文件裡是明確的：一行一台機器名稱或位址。
#  這是本工具唯一有把握的輸出格式，所以 run-batch 預設用 file= 而不是 list=。
# ---------------------------------------------------------------------------
$machinesPath = Join-Path $OutDir 'machines.txt'
$ml = New-Object System.Text.StringBuilder
foreach ($e in $use) { $null = $ml.AppendLine($e.Name) }
$ml.ToString() | Out-File -FilePath $machinesPath -Encoding ascii -Force

# ---------------------------------------------------------------------------
#  verify-batchoptions.cmd
#
#  這一步不能省。AEDT 的命令列選項在版本之間有差異，本工具依公開文件產生，
#  沒有辦法在這裡驗證客戶那個版本的實際拼法。
# ---------------------------------------------------------------------------
$aedtRoot = ''
foreach ($n in $nodes) {
    foreach ($a in @($n.node.aedt)) {
        if ($a.root) { $aedtRoot = [string]$a.root; break }
    }
    if ($aedtRoot) { break }
}
if (-not $aedtRoot) { $aedtRoot = 'C:\Program Files\AnsysEM\v242\Win64' }

$verifyPath = Join-Path $OutDir 'verify-batchoptions.cmd'
$vb = New-Object System.Text.StringBuilder
$null = $vb.AppendLine('@echo off')
$null = $vb.AppendLine('REM ==========================================================================')
$null = $vb.AppendLine('REM  Step 1 - verify the command line option spellings for THIS AEDT version.')
$null = $vb.AppendLine('REM  Taiwan Auto-Design Co.   cae-support@cadmen.com')
$null = $vb.AppendLine('REM')
$null = $vb.AppendLine('REM  This file must stay ASCII-only, including comments.')
$null = $vb.AppendLine('REM')
$null = $vb.AppendLine('REM  Option names differ between AEDT releases. run-batch.cmd was generated')
$null = $vb.AppendLine('REM  from public documentation and is NOT verified against your version.')
$null = $vb.AppendLine('REM  Run this first, compare the listed options with run-batch.cmd, then')
$null = $vb.AppendLine('REM  uncomment the command in run-batch.cmd.')
$null = $vb.AppendLine('REM')
$null = $vb.AppendLine('REM  Note: -Batchoptions opens a GUI dialog. Read it, do not expect stdout.')
$null = $vb.AppendLine('REM ==========================================================================')
$null = $vb.AppendLine('')
$null = $vb.AppendLine('set "AEDT=' + $aedtRoot + '\ansysedt.exe"')
$null = $vb.AppendLine('')
$null = $vb.AppendLine('if not exist "%AEDT%" (')
$null = $vb.AppendLine('    echo [ERROR] ansysedt.exe not found at "%AEDT%"')
$null = $vb.AppendLine('    echo         Edit this file and set AEDT to the correct path.')
$null = $vb.AppendLine('    pause')
$null = $vb.AppendLine('    exit /b 1')
$null = $vb.AppendLine(')')
$null = $vb.AppendLine('')
$null = $vb.AppendLine('echo Opening the AEDT batch option list...')
$null = $vb.AppendLine('echo Check that these options exist and are spelled the same way:')
$null = $vb.AppendLine('echo     -BatchSolve   -Distributed   -MachineList   -ng   -Auto')
$null = $vb.AppendLine('echo And check the accepted -MachineList forms: list= / file= / num=')
$null = $vb.AppendLine('echo.')
$null = $vb.AppendLine('"%AEDT%" -Batchoptions')
$null = $vb.AppendLine('')
$null = $vb.AppendLine('pause')
$vb.ToString() | Out-File -FilePath $verifyPath -Encoding ascii -Force

# ---------------------------------------------------------------------------
#  run-batch.cmd —— 預設註解掉，驗證過才解開
# ---------------------------------------------------------------------------
# 百分號在 .cmd 裡必須寫成 %%。不跳脫的話 "90%,WS02:1:16:90%" 會被 cmd 當成
# 變數 %,WS02:1:16:90% 去展開，變數不存在就換成空字串——參數被靜默改成 "90"，
# 不會有任何錯誤訊息。這種錯只會表現成「求解結果怪怪的」。
$listSpec = (@($use | ForEach-Object {
    $_.Name + ':' + $_.Tasks + ':' + $_.Cores + ':' + $Ratio + '%%'
}) -join ',')
$totalCores = 0
foreach ($e in $use) { $totalCores += [int]$e.Cores }

$runPath = Join-Path $OutDir 'run-batch.cmd'
$rb = New-Object System.Text.StringBuilder
$null = $rb.AppendLine('@echo off')
$null = $rb.AppendLine('REM ==========================================================================')
$null = $rb.AppendLine('REM  AEDT distributed batch solve')
$null = $rb.AppendLine('REM  Generated by ' + $TOOL_NAME + ' v' + $TOOL_VERSION)
$null = $rb.AppendLine('REM  Taiwan Auto-Design Co.   cae-support@cadmen.com')
$null = $rb.AppendLine('REM  Case: ' + $caseId)
$null = $rb.AppendLine('REM')
$null = $rb.AppendLine('REM  This file must stay ASCII-only, including comments.')
$null = $rb.AppendLine('REM')
$null = $rb.AppendLine('REM  !! THE SOLVE COMMAND BELOW IS COMMENTED OUT ON PURPOSE !!')
$null = $rb.AppendLine('REM')
$null = $rb.AppendLine('REM  Option spellings differ between AEDT releases. They were taken from')
$null = $rb.AppendLine('REM  public documentation and are NOT verified against your version.')
$null = $rb.AppendLine('REM  Run verify-batchoptions.cmd first, compare, then remove the REM')
$null = $rb.AppendLine('REM  from the line that starts with REM "%AEDT%".')
$null = $rb.AppendLine('REM')
$null = $rb.AppendLine('REM  Machines: ' + (@($use | ForEach-Object { $_.Name }) -join ' '))
$null = $rb.AppendLine('REM  Total cores requested: ' + $totalCores)
$null = $rb.AppendLine('REM ==========================================================================')
$null = $rb.AppendLine('')
$null = $rb.AppendLine('setlocal')
$null = $rb.AppendLine('cd /d "%~dp0"')
$null = $rb.AppendLine('')
$null = $rb.AppendLine('set "AEDT=' + $aedtRoot + '\ansysedt.exe"')
$null = $rb.AppendLine('set "PROJECT=' + $projectArg + '"')
$null = $rb.AppendLine('set "MACHINES=%~dp0machines.txt"')
$null = $rb.AppendLine('')
$null = $rb.AppendLine('if not exist "%AEDT%" (')
$null = $rb.AppendLine('    echo [ERROR] ansysedt.exe not found at "%AEDT%"')
$null = $rb.AppendLine('    pause')
$null = $rb.AppendLine('    exit /b 1')
$null = $rb.AppendLine(')')
$null = $rb.AppendLine('if not exist "%PROJECT%" (')
$null = $rb.AppendLine('    echo [ERROR] Project file not found: "%PROJECT%"')
$null = $rb.AppendLine('    echo         Edit this file and set PROJECT to your .aedt file.')
$null = $rb.AppendLine('    pause')
$null = $rb.AppendLine('    exit /b 1')
$null = $rb.AppendLine(')')
$null = $rb.AppendLine('')
$null = $rb.AppendLine('REM --- Form A: machine list from file (one host per line) ---')
$null = $rb.AppendLine('REM "%AEDT%" -ng -BatchSolve -Distributed -MachineList file="%MACHINES%" "%PROJECT%"')
$null = $rb.AppendLine('')
$null = $rb.AppendLine('REM --- Form B: explicit list with tasks:cores:ratio per host ---')
$null = $rb.AppendLine('REM   host:TASKS_PER_NODE:CORES_PER_NODE:RATIO')
$null = $rb.AppendLine('REM "%AEDT%" -ng -BatchSolve -Distributed -MachineList list="' + $listSpec + '" "%PROJECT%"')
$null = $rb.AppendLine('')
$null = $rb.AppendLine('echo.')
$null = $rb.AppendLine('echo The solve command is still commented out.')
$null = $rb.AppendLine('echo Run verify-batchoptions.cmd, confirm the option names, then edit this file.')
$null = $rb.AppendLine('echo.')
$null = $rb.AppendLine('pause')
$null = $rb.AppendLine('endlocal')
$rb.ToString() | Out-File -FilePath $runPath -Encoding ascii -Force

# ---------------------------------------------------------------------------
#  待辦清單
# ---------------------------------------------------------------------------
$todoPath = Join-Path $OutDir '待辦清單.txt'
$tb = New-Object System.Text.StringBuilder
$null = $tb.AppendLine('=' * 72)
$null = $tb.AppendLine('  ' + $TOOL_NAME + '　待辦清單')
$null = $tb.AppendLine('  ' + $VENDOR_NAME + '　技術支援：' + $VENDOR_MAIL)
$null = $tb.AppendLine('  案件編號：' + $caseId)
$null = $tb.AppendLine('  產生時間：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$null = $tb.AppendLine('=' * 72)
$null = $tb.AppendLine('')
$null = $tb.AppendLine('列入機器清單的機器（' + $use.Count + ' 台，合計 ' + $totalCores + ' 核）：')
foreach ($e in $use) {
    $null = $tb.AppendLine('  ' + $e.Name.PadRight(18) + $e.Cores + ' 核 / ' + $e.Tasks + ' task / 上限 ' + $Ratio + '%')
}
$null = $tb.AppendLine('')

if ($unready.Count -gt 0 -and -not $IncludeUnready) {
    $null = $tb.AppendLine('已排除的機器：')
    foreach ($e in $unready) {
        $null = $tb.AppendLine('  ' + $e.Name.PadRight(18) + ($e.Blocked -join '、'))
    }
    $null = $tb.AppendLine('')
    $null = $tb.AppendLine('  處理方式見 Test-AedtCluster.ps1 -Merge 產生的彙整報告。')
    $null = $tb.AppendLine('  確定要照樣列進去時，加上 -IncludeUnready 重跑。')
    $null = $tb.AppendLine('')
}

$null = $tb.AppendLine('-' * 72)
$null = $tb.AppendLine('  第一次使用前必須做的事')
$null = $tb.AppendLine('-' * 72)
$null = $tb.AppendLine('')
$null = $tb.AppendLine('1. 執行 verify-batchoptions.cmd，對照該版本實際支援的選項。')
$null = $tb.AppendLine('   AEDT 的命令列選項在版本之間有差異，本工具依公開文件產生，')
$null = $tb.AppendLine('   沒有辦法替貴司的版本背書。猜錯的批次檔會直接失敗。')
$null = $tb.AppendLine('')
$null = $tb.AppendLine('2. 確認無誤後，編輯 run-batch.cmd，把要用的那一行前面的 REM 拿掉。')
$null = $tb.AppendLine('   Form A（file=）是機器清單檔，格式在官方文件裡是明確的，建議先試這個。')
$null = $tb.AppendLine('   Form B（list=）可以逐台指定 task 數與核心數，但拼法要先驗證過。')
$null = $tb.AppendLine('')
if ([string]::IsNullOrWhiteSpace($Project)) {
    $null = $tb.AppendLine('3. 編輯 run-batch.cmd，把 PROJECT 設成實際的 .aedt 檔路徑。')
    $null = $tb.AppendLine('   （產生時沒有指定 -Project，所以留成佔位字串。）')
    $null = $tb.AppendLine('')
}
$null = $tb.AppendLine('-' * 72)
$null = $tb.AppendLine('  為什麼沒有產生 .acf')
$null = $tb.AppendLine('-' * 72)
$null = $tb.AppendLine('')
$null = $tb.AppendLine('.acf 是 AEDT 的分析組態檔，可以把整組 HPC 設定匯入 GUI，比逐格填快很多。')
$null = $tb.AppendLine('本工具不產生它，因為它的實際欄位結構沒有公開規格可以依循，')
$null = $tb.AppendLine('猜出來的檔案匯入後可能靜默套用錯誤的設定——那比沒有 acf 更難查。')
$null = $tb.AppendLine('')
$null = $tb.AppendLine('建議做法（一次性）：')
$null = $tb.AppendLine('  1. 在其中一台的 AEDT GUI 裡把 HPC and Analysis Options 設定好')
$null = $tb.AppendLine('     （machine list 分頁可以直接匯入本工具產生的 machines.txt）')
$null = $tb.AppendLine('  2. 匯出成 .acf')
$null = $tb.AppendLine('  3. 之後每台匯入同一份 .acf 即可')
$null = $tb.AppendLine('')
$null = $tb.AppendLine('若貴司願意提供一份匯出的 .acf 給我方參考，之後版本就可以自動產生。')
$null = $tb.AppendLine('')
$null = $tb.AppendLine('=' * 72)
$null = $tb.AppendLine('  本工具唯讀，只產生上述檔案，未修改任何機器的設定。')
$null = $tb.AppendLine('=' * 72)
$tb.ToString() | Out-File -FilePath $todoPath -Encoding utf8 -Force

# ---------------------------------------------------------------------------
Write-Host ('=' * 60) -ForegroundColor White
Write-Host '  設定檔已產生' -ForegroundColor Green
Write-Host ''
Write-Host ('    ' + $machinesPath)
Write-Host ('    ' + $verifyPath)
Write-Host ('    ' + $runPath)
Write-Host ('    ' + $todoPath)
Write-Host ''
Write-Host '  run-batch.cmd 裡的求解命令是刻意註解掉的。' -ForegroundColor Yellow
Write-Host '  請先跑 verify-batchoptions.cmd 對照該版本的選項拼法，確認後再解開。' -ForegroundColor Yellow
Write-Host ''
Write-Host '  本工具唯讀，未修改任何機器的設定。' -ForegroundColor Green
Write-Host ''
exit 0
