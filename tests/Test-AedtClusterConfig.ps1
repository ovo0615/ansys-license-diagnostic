#Requires -Version 5.1
<#
.SYNOPSIS
    New-AedtClusterConfig.ps1 的測試。

.DESCRIPTION
    產生器吃 .node.json、輸出文字檔，完全不碰真實機器，所以可以在任何平台測。

    重點在「產出的東西拿去用會不會出事」：
      - .cmd 必須全 ASCII，百分號必須跳脫
      - 求解命令必須是註解掉的（選項拼法未經實機驗證）
      - 沒過檢查的機器不可以偷偷被列進機器清單

.EXAMPLE
    .\tests\Test-AedtClusterConfig.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir  = Split-Path -Parent $TestsDir
$Tool     = Join-Path $RepoDir 'New-AedtClusterConfig.ps1'

if (-not (Test-Path -LiteralPath $Tool)) {
    Write-Host ('找不到受測腳本：' + $Tool) -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0

. (Join-Path $TestsDir '_NodeFixture.ps1')

function Assert-True {
    param([string] $Case, [bool] $Condition, [string] $Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Case) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Case + $(if ($Detail) { ' — ' + $Detail } else { '' })) -ForegroundColor Red
    }
}

function Invoke-Generator {
    <#
        把節點物件寫成 .node.json，跑一次產生器，回傳輸出目錄的內容。
        目錄由呼叫端負責刪。
    #>
    param([object[]] $Nodes, [hashtable] $ExtraArgs = @{})

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('aedtcfg-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $nodeDir = Join-Path $dir 'nodes'
    $outDir  = Join-Path $dir 'out'
    New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null

    $i = 0
    foreach ($n in $Nodes) {
        $i++
        $n | ConvertTo-Json -Depth 10 |
            Out-File -FilePath (Join-Path $nodeDir ('n' + $i + '.node.json')) -Encoding utf8 -Force
    }

    # 一定要用 hashtable splat。陣列 splat 不會把 "-CoresPerNode" 這種字串
    # 重新當成參數名，會被當成前一個陣列參數的值吞掉。
    $splat = @{ From = $nodeDir; OutDir = $outDir }
    foreach ($k in $ExtraArgs.Keys) { $splat[$k] = $ExtraArgs[$k] }
    & $Tool @splat *> $null
    $rc = $LASTEXITCODE

    $read = {
        param([string] $Name)
        $p = Join-Path $outDir $Name
        if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) }
        return $null
    }

    return [pscustomobject]@{
        ExitCode = $rc
        Dir      = $dir
        OutDir   = $outDir
        Machines = (& $read 'machines.txt')
        RunBatch = (& $read 'run-batch.cmd')
        Verify   = (& $read 'verify-batchoptions.cmd')
        Todo     = (& $read '待辦清單.txt')
        RunBytes = $(
            $p = Join-Path $outDir 'run-batch.cmd'
            if (Test-Path -LiteralPath $p) { [System.IO.File]::ReadAllBytes($p) } else { $null }
        )
    }
}

Write-Host ''
Write-Host 'New-AedtClusterConfig.ps1 測試' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 1：兩台都正常' -ForegroundColor White
$r = Invoke-Generator @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02')
)
Assert-True '離開代碼為 0' ($r.ExitCode -eq 0) ('實際 ' + $r.ExitCode)
Assert-True 'machines.txt 含兩台' (($r.Machines -match 'WS01') -and ($r.Machines -match 'WS02'))
Assert-True 'machines.txt 一行一台' (@($r.Machines -split "`r?`n" | Where-Object { $_ }).Count -eq 2)
Assert-True '有產生 run-batch.cmd' ($null -ne $r.RunBatch)
Assert-True '有產生 verify-batchoptions.cmd' ($null -ne $r.Verify)
Assert-True '有產生待辦清單' ($null -ne $r.Todo)

# 這是整支工具最重要的一條：選項拼法沒在實機驗證過，命令就不能是可執行狀態。
$solveLines = @($r.RunBatch -split "`r?`n" | Where-Object { $_ -match '-BatchSolve' })
Assert-True '有寫出求解命令' ($solveLines.Count -gt 0)
$allCommented = $true
foreach ($l in $solveLines) { if ($l -notmatch '^\s*REM\s') { $allCommented = $false } }
Assert-True '求解命令全部是註解掉的' $allCommented ('未註解：' + (($solveLines | Where-Object { $_ -notmatch '^\s*REM\s' }) -join ' | '))

# .cmd 只要有一個非 ASCII 位元組，chcp 65001 下就會吃字
Assert-True 'run-batch.cmd 全 ASCII' (@($r.RunBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
$vBytes = [System.Text.Encoding]::UTF8.GetBytes($r.Verify)
Assert-True 'verify-batchoptions.cmd 全 ASCII' (@($vBytes | Where-Object { $_ -gt 127 }).Count -eq 0)

# 百分號沒跳脫的話，"90%,WS02:..." 會被 cmd 當成變數展開而靜默變成 "90"
$listLine = @($r.RunBatch -split "`r?`n" | Where-Object { $_ -match 'MachineList list=' })[0]
Assert-True 'list= 的百分號有跳脫成 %%' ($listLine -match '90%%') ('實際：' + $listLine)
# 只檢查 list= 的引號內容。同一行的 %AEDT% 與 %PROJECT% 是正當的變數展開，
# 拿整行去比對單一百分號會誤判。
$listValue = ''
if ($listLine -match 'list="([^"]*)"') { $listValue = $Matches[1] }
Assert-True 'list= 的值裡沒有落單的百分號' `
    (($listValue.Length -gt 0) -and ($listValue -notmatch '(?<!%)%(?!%)')) ('實際：' + $listValue)
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 2：沒過檢查的機器要被排除，不能偷偷列進去' -ForegroundColor White
$r = Invoke-Generator @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02' -RsmRunning $false)
    (New-Node -Name 'WS03' -Mpi '')
)
Assert-True 'machines.txt 只有 WS01' ($r.Machines -match 'WS01')
Assert-True 'RSM 沒跑的 WS02 被排除' ($r.Machines -notmatch 'WS02')
Assert-True '沒有 MPI 的 WS03 被排除' ($r.Machines -notmatch 'WS03')
Assert-True '待辦清單說明 WS02 被排除的原因' ($r.Todo -match 'WS02' -and $r.Todo -match 'RSM')
Assert-True '待辦清單說明 WS03 被排除的原因' ($r.Todo -match 'WS03' -and $r.Todo -match 'MPI')
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 3：-IncludeUnready 才會把沒過的也列進去' -ForegroundColor White
$r = Invoke-Generator @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02' -RsmRunning $false)
) -ExtraArgs @{ IncludeUnready = $true }
Assert-True 'WS02 被列入' ($r.Machines -match 'WS02')
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 4：全部都沒過時不產生設定，並回非 0' -ForegroundColor White
$r = Invoke-Generator @(
    (New-Node -Name 'WS01' -RsmRunning $false)
    (New-Node -Name 'WS02' -NoAedt $true)
)
Assert-True '離開代碼非 0' ($r.ExitCode -ne 0) ('實際 ' + $r.ExitCode)
Assert-True '沒有產生 machines.txt' ($null -eq $r.Machines)
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 5：核心數與使用率參數' -ForegroundColor White
$r = Invoke-Generator @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02')
) -ExtraArgs @{ CoresPerNode = 8; TasksPerNode = 2; Ratio = 75 }
$listLine = @($r.RunBatch -split "`r?`n" | Where-Object { $_ -match 'MachineList list=' })[0]
Assert-True 'list= 反映指定的 task/核心/比率' ($listLine -match 'WS01:2:8:75%%') ('實際：' + $listLine)
Assert-True '待辦清單顯示合計核心數 16' ($r.Todo -match '合計 16 核')
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 6：未指定 -Project 時要留佔位字串並在待辦清單提醒' -ForegroundColor White
$r = Invoke-Generator @( (New-Node -Name 'WS01') )
Assert-True 'PROJECT 是佔位字串' ($r.RunBatch -match 'set "PROJECT=<')
Assert-True '待辦清單提醒要填專案檔' ($r.Todo -match 'PROJECT')
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '案例 7：指定 -Project 時要帶進去' -ForegroundColor White
$r = Invoke-Generator @( (New-Node -Name 'WS01') ) -ExtraArgs @{ Project = 'D:\work\ant.aedt' }
Assert-True 'PROJECT 帶入指定路徑' ($r.RunBatch -match 'set "PROJECT=D:\\work\\ant\.aedt"')
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 8：待辦清單要說明為什麼沒有產生 .acf' -ForegroundColor White
$r = Invoke-Generator @( (New-Node -Name 'WS01') )
Assert-True '待辦清單提到 .acf' ($r.Todo -match '\.acf')
Assert-True '沒有產生 .acf 檔' (@(Get-ChildItem -LiteralPath $r.OutDir -Filter '*.acf' -ErrorAction SilentlyContinue).Count -eq 0)
Remove-Item -LiteralPath $r.Dir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
