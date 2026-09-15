#Requires -Version 5.1
<#
.SYNOPSIS
    Test-AedtCluster.ps1 彙整模式的測試。

.DESCRIPTION
    彙整模式吃的是 .node.json，不碰真實機器，所以可以完全用合成資料測。
    這也是這支工具唯一能離開 Windows 驗證的部分——節點收集那一半必須在
    真的工作站上跑。

    測試針對「該講的有沒有講、不該講的有沒有閉嘴」，不是逐字比對報告內容。

.EXAMPLE
    .\tests\Test-AedtClusterMerge.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir  = Split-Path -Parent $TestsDir
$Tool     = Join-Path $RepoDir 'Test-AedtCluster.ps1'

if (-not (Test-Path -LiteralPath $Tool)) {
    Write-Host ('找不到受測腳本：' + $Tool) -ForegroundColor Red
    exit 1
}

$script:Pass = 0
$script:Fail = 0

. (Join-Path $TestsDir '_NodeFixture.ps1')


function Invoke-Merge {
    <#
        把節點物件寫成 .node.json，跑一次彙整，回傳 findings 陣列。
        用 -Json 拿結構化輸出，不去刮報告的文字——刮文字的測試改個標點就壞。
    #>
    param([object[]] $Nodes)

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('aedtclu-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $nodeDir = Join-Path $dir 'nodes'
    $outDir  = Join-Path $dir 'out'
    New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null

    $i = 0
    foreach ($n in $Nodes) {
        $i++
        $f = Join-Path $nodeDir ('n' + $i + '.node.json')
        $n | ConvertTo-Json -Depth 10 | Out-File -FilePath $f -Encoding utf8 -Force
    }

    & $Tool -Merge $nodeDir -OutDir $outDir -Json *> $null

    $jf = Get-ChildItem -LiteralPath $outDir -Filter '*.findings.json' -ErrorAction SilentlyContinue |
          Select-Object -First 1
    $result = @()
    if ($jf) {
        $result = @((Get-Content -LiteralPath $jf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).findings)
    }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return $result
}

function Assert-Finding {
    param(
        [string] $Case,
        [object[]] $Findings,
        [string] $TitleLike,
        [string] $Level,
        [string] $DetailLike,
        [string] $FixAction,
        # 修復建議要給得出可執行的指令，不能只說「請調整某某設定」。
        # 這一項讓那個要求變成可以被測的東西。
        [string] $FixLike,
        [switch] $Absent
    )
    $hits = @($Findings | Where-Object {
        $_.title -like ('*' + $TitleLike + '*') -and (-not $Level -or $_.level -eq $Level) -and
        (-not $DetailLike -or ([string]$_.detail) -like ('*' + $DetailLike + '*')) -and
        (-not $FixAction -or ([string]$_.fixAction) -eq $FixAction) -and
        (-not $FixLike -or ([string]$_.fixText) -like ('*' + $FixLike + '*'))
    })
    $want  = if ($Absent) { '不該出現' } else { '應出現' }
    $what  = if ($TitleLike) { '「' + $TitleLike + '」' } else { '任何 ' + $Level + ' 結論' }
    if ($DetailLike) { $what += '（說明含「' + $DetailLike + '」）' }
    if ($FixAction) { $what += '（修復動作為「' + $FixAction + '」）' }
    if ($FixLike) { $what += '（處理方式含「' + $FixLike + '」）' }
    $ok    = if ($Absent) { $hits.Count -eq 0 } else { $hits.Count -gt 0 }
    if ($ok) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Case + ' — ' + $want + $what) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Case + ' — ' + $want + $what) -ForegroundColor Red
        foreach ($f in $Findings) { Write-Host ('         實際：[' + $f.level + '] ' + $f.title) -ForegroundColor DarkGray }
    }
}

function Assert-Equal {
    param([string] $Case, $Actual, $Expected)
    if ([string]$Actual -eq [string]$Expected) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Case + ' = ' + $Expected) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Case + ' = ' + $Actual + '，應為 ' + $Expected) -ForegroundColor Red
    }
}

function Get-ToolFunctionSource {
    <#
        從受測腳本裡把指定函式的原始碼挖出來。

        腳本本身一被載入就會開始收集本機資料，不能直接 dot-source；
        用 AST 只取需要的函式定義，才測得到那些純計算的部分。

        回傳的是文字，由呼叫端在腳本層 dot-source——在這個函式裡面直接
        dot-source 的話，函式只會定義在它自己的範圍裡，出去就不見了。
    #>
    param([string[]] $Names)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Tool, [ref]$null, [ref]$null)
    $sb  = New-Object System.Text.StringBuilder
    foreach ($n in $Names) {
        $f = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $n
        }, $true)
        if (-not $f) { throw ('受測腳本裡找不到函式 ' + $n) }
        $null = $sb.AppendLine($f.Extent.Text)
    }
    return $sb.ToString()
}

Write-Host ''
Write-Host 'Test-AedtCluster.ps1 彙整模式測試' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 0：純計算函式' -ForegroundColor White
. ([scriptblock]::Create((Get-ToolFunctionSource @('Get-NetworkKey', 'Get-HpcCoreTotal', 'ConvertTo-ReleaseLabel'))))

# 網段計算。早期版本寫成 [uint32]0xFFFFFFFF -shl n，PowerShell 會把 0xFFFFFFFF
# 當成 int 的 -1，轉型直接爆掉又被 catch 吃掉，結果是網段偵測整個靜默失效。
Assert-Equal '網段 192.168.10.13/24' (Get-NetworkKey -IPv4 '192.168.10.13' -PrefixLen 24).Key '192.168.10.0/24'
Assert-Equal '網段 10.1.2.200/22'    (Get-NetworkKey -IPv4 '10.1.2.200'    -PrefixLen 22).Key '10.1.0.0/22'
Assert-Equal '網段 172.20.5.1/20'    (Get-NetworkKey -IPv4 '172.20.5.1'    -PrefixLen 20).Key '172.20.0.0/20'
Assert-Equal '網段 1.2.3.4/32'       (Get-NetworkKey -IPv4 '1.2.3.4'       -PrefixLen 32).Key '1.2.3.4/32'
Assert-Equal '遮罩未知時推測 /24'    (Get-NetworkKey -IPv4 '192.168.1.5' -PrefixLen $null).Key '192.168.1.0/24'
Assert-Equal '遮罩未知要標示為推測'  (Get-NetworkKey -IPv4 '192.168.1.5' -PrefixLen $null).Guessed 'True'
Assert-Equal '非法 IP 回傳 null'     $(if ($null -eq (Get-NetworkKey -IPv4 'bogus' -PrefixLen 24)) { 'null' } else { '有值' }) 'null'

# HPC Pack 是倍增：2 * 4^n 再加上授權內含的 4 個 unit。
# 原廠文件的例子：2 台各 2 個 pack = 72 核，4 台各 1 個 = 48 核。
Assert-Equal 'HPC 0 pack'  (Get-HpcCoreTotal -Packs 0) 4
Assert-Equal 'HPC 1 pack'  (Get-HpcCoreTotal -Packs 1) 12
Assert-Equal 'HPC 2 pack'  (Get-HpcCoreTotal -Packs 2) 36
Assert-Equal 'HPC 3 pack'  (Get-HpcCoreTotal -Packs 3) 132
Assert-Equal '2 台各 2 pack 合計' ((Get-HpcCoreTotal -Packs 2) * 2) 72
Assert-Equal '4 台各 1 pack 合計' ((Get-HpcCoreTotal -Packs 1) * 4) 48

Assert-Equal '版本代號 v242'      (ConvertTo-ReleaseLabel 'v242')        '2024 R2'
Assert-Equal '版本代號 V251'      (ConvertTo-ReleaseLabel 'V251')        '2025 R1'
Assert-Equal '舊式 AnsysEM19.2'   (ConvertTo-ReleaseLabel 'AnsysEM19.2') '2019 R2'
Assert-Equal '認不出來就原樣回傳' (ConvertTo-ReleaseLabel 'Win64')       'Win64'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 1：三台完全一致，只該報正常' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Ip '192.168.10.11' -Peers @(
        [pscustomobject]@{ target='WS02'; resolved=@('192.168.10.12'); tcpOk=$true; tcpReason=''; sameSubnet=$true; port=32958 }))
    (New-Node -Name 'WS02' -Ip '192.168.10.12' -Peers @(
        [pscustomobject]@{ target='WS01'; resolved=@('192.168.10.11'); tcpOk=$true; tcpReason=''; sameSubnet=$true; port=32958 }))
    (New-Node -Name 'WS03' -Ip '192.168.10.13' -Peers @(
        [pscustomobject]@{ target='WS01'; resolved=@('192.168.10.11'); tcpOk=$true; tcpReason=''; sameSubnet=$true; port=32958 }))
)
Assert-Finding -Case '案例1' -Findings $f -TitleLike '每台都有的版本' -Level 'OK'
Assert-Finding -Case '案例1' -Findings $f -TitleLike 'temp 目錄各機一致' -Level 'OK'
Assert-Finding -Case '案例1' -Findings $f -TitleLike '所有做過的連線測試都通' -Level 'OK'
Assert-Finding -Case '案例1' -Findings $f -TitleLike '' -Level 'CONFIRMED' -Absent
Assert-Finding -Case '案例1' -Findings $f -TitleLike '' -Level 'SUSPECT' -Absent

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 2：版本不一致時，temp 與安裝路徑的差異仍然要講' -ForegroundColor White
# 這是實作上踩過的坑：早期版本把這兩項放在「有共通版本」的分支裡，
# 版本一不同就整段跳過，客戶統一版本後才會撞到第二個問題。
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Release '2024 R2' -TempDir 'C:\Temp'      -Root 'C:\Program Files\AnsysEM\v242\Win64')
    (New-Node -Name 'WS02' -Release '2025 R1' -TempDir 'D:\AnsysTemp' -Root 'D:\AnsysEM\v251\Win64')
)
Assert-Finding -Case '案例2' -Findings $f -TitleLike '沒有任何一個 AEDT 版本是每台機器都有的' -Level 'CONFIRMED'
Assert-Finding -Case '案例2' -Findings $f -TitleLike 'temp 目錄各機路徑不同' -Level 'CONFIRMED'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 3：同版本但安裝路徑不同' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Root 'C:\Program Files\AnsysEM\v242\Win64')
    (New-Node -Name 'WS02' -Root 'D:\AnsysEM\v242\Win64')
)
Assert-Finding -Case '案例3' -Findings $f -TitleLike '安裝路徑各機不同' -Level 'CONFIRMED'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 4：RSM 停掉、hydra 停掉，動作要指到出問題的那一台' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02' -RsmRunning $false -MpiRunning $false)
)
Assert-Finding -Case '案例4' -Findings $f -TitleLike 'WS02 的 RSM 服務沒有執行' -Level 'CONFIRMED'
Assert-Finding -Case '案例4' -Findings $f -TitleLike 'WS02 的 hydra_service 沒有執行' -Level 'CONFIRMED'
$rsmFix = @($f | Where-Object { $_.title -like '*WS02 的 RSM*' })[0]
if ($rsmFix.fixOn -eq 'WS02') {
    $script:Pass++; Write-Host '  [PASS] 案例4 — RSM 修復動作指向 WS02' -ForegroundColor Green
} else {
    $script:Fail++; Write-Host ('  [FAIL] 案例4 — RSM 修復動作指向 ' + $rsmFix.fixOn + '，應為 WS02') -ForegroundColor Red
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 5：一台有 Hyper-V 介面不該亮【可疑】，兩張實體網卡才該亮' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -VirtualNics 1)
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例5a' -Findings $f -TitleLike '多張實體網卡' -Absent
Assert-Finding -Case '案例5a' -Findings $f -TitleLike '虛擬或 VPN 介面' -Level 'INFO'

$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -RealNics 2)
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例5b' -Findings $f -TitleLike '多張實體網卡' -Level 'SUSPECT'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 6：MPI 各機不同種' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Mpi 'IntelMPI')
    (New-Node -Name 'WS02' -Mpi 'MSMPI')
)
Assert-Finding -Case '案例6' -Findings $f -TitleLike '沒有任何一種 MPI 是每台都有的' -Level 'CONFIRMED'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 7：Intel MPI 版本不一致' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -MpiVersion '2021.8.0')
    (New-Node -Name 'WS02' -MpiVersion '2021.11.0')
)
Assert-Finding -Case '案例7' -Findings $f -TitleLike 'hydra_service 版本各機不同' -Level 'SUSPECT'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 8：某台完全沒有 AEDT' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02' -NoAedt $true)
)
Assert-Finding -Case '案例8' -Findings $f -TitleLike 'WS02 上沒有偵測到 AEDT' -Level 'CONFIRMED'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 9：沒設 tempdirectory 要報【需人工】，不能報「不同」' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -NoTempDir $true)
    (New-Node -Name 'WS02' -NoTempDir $true)
)
Assert-Finding -Case '案例9' -Findings $f -TitleLike 'temp 目錄讀不到設定' -Level 'MANUAL'
Assert-Finding -Case '案例9' -Findings $f -TitleLike 'temp 目錄各機路徑不同' -Absent

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 10：案件編號混到別批機器' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -CaseId 'A-001')
    (New-Node -Name 'WS02' -CaseId 'B-002')
)
Assert-Finding -Case '案例10' -Findings $f -TitleLike '案件編號不一致' -Level 'MANUAL'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 11：只有一台的資料，要說清楚比對不了' -ForegroundColor White
$f = Invoke-Merge @( (New-Node -Name 'WS01') )
Assert-Finding -Case '案例11' -Findings $f -TitleLike '只有一台機器的資料' -Level 'MANUAL'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 12：schema 版本不符要擋掉，不能拿舊格式硬比' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02' -Schema 99)
)
Assert-Finding -Case '案例12' -Findings $f -TitleLike '節點報告版本不符' -Level 'MANUAL'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 13：沒有連通性資料時要講，不能默默當作沒問題' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例13' -Findings $f -TitleLike '沒有任何連通性測試資料' -Level 'MANUAL'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 14：temp 路徑差異來自 8.3 短檔名時要提醒，其他情況要閉嘴' -ForegroundColor White
# 開發機上實際遇到的：同一台的 v251 寫 C:/Profiles/EXAMPL~1.USR/...、v241 寫
# C:/Profiles/example.user/...，指的是同一個目錄。判定仍是【確定】（AEDT 比的是
# 路徑字串），但要讓看報告的人知道有這個可能，不然他會去找一個不存在的差異。
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -TempDir 'C:\Profiles\EXAMPL~1.USR\AppData\Local\Temp')
    (New-Node -Name 'WS02' -TempDir 'C:\Profiles\example.user\AppData\Local\Temp')
)
Assert-Finding -Case '案例14' -Findings $f -TitleLike 'temp 目錄各機路徑不同' -Level 'CONFIRMED'
Assert-Finding -Case '案例14' -Findings $f -TitleLike 'temp 目錄各機路徑不同' -DetailLike '長短檔名'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 15：作業系統版本不一致要攔截' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Os 'Microsoft Windows 11 Pro' -OsVersion '10.0.26100' -OsBuild '26100')
    (New-Node -Name 'WS02' -Os 'Microsoft Windows 10 Pro' -OsVersion '10.0.19045' -OsBuild '19045')
)
Assert-Finding -Case '案例15' -Findings $f -TitleLike '作業系統版本各機不同' `
    -Level 'CONFIRMED' -FixAction 'align-os-version'

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 16：Windows 產品相同但更新層級不同，只列疑點' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Os 'Microsoft Windows 11 Pro' -OsVersion '10.0.26100' -OsBuild '26100')
    (New-Node -Name 'WS02' -Os 'Microsoft Windows 11 Pro' -OsVersion '10.0.26200' -OsBuild '26200')
)
Assert-Finding -Case '案例16' -Findings $f -TitleLike 'Windows 更新層級各機不同' `
    -Level 'SUSPECT' -FixAction 'align-os-version'
Assert-Finding -Case '案例16' -Findings $f -TitleLike '作業系統版本各機不同' `
    -Level 'CONFIRMED' -Absent

# 沒有短檔名時不可以講這一句——不該講的要閉嘴，否則提醒就變成雜訊。
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -TempDir 'C:\Temp')
    (New-Node -Name 'WS02' -TempDir 'D:\AnsysTemp')
)
Assert-Finding -Case '案例14' -Findings $f -TitleLike 'temp 目錄各機路徑不同' -Level 'CONFIRMED'
Assert-Finding -Case '案例14' -Findings $f -TitleLike 'temp 目錄各機路徑不同' -DetailLike '長短檔名' -Absent

# ---------------------------------------------------------------------------
# 實機遇到的：兩台都是 2026 R1，但一台 2026.1.0、一台 2026.1.4。
# 只比到 release 會說「每台都有的版本：2026 R1」然後放行——
# 但那是不同的執行檔，而 Ansys 要求各節點同版。
# 列【可疑】不列【確定】：修補版不同會不會真的出事要看情況，講死就超出證據。
Write-Host ''
Write-Host '案例 17：同一個 release 但修補版號不同，要列疑點' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Release '2026 R1' -FileVersion '2026.1.0')
    (New-Node -Name 'WS02' -Release '2026 R1' -FileVersion '2026.1.4')
)
Assert-Finding -Case '案例17' -Findings $f -TitleLike '2026 R1 的修補版號各機不同' `
    -Level 'SUSPECT' -FixAction 'align-aedt-version'
Assert-Finding -Case '案例17' -Findings $f -TitleLike '2026 R1 的修補版號各機不同' -DetailLike '2026.1.4'
# 共通版本還是要照講，不能因為修補版不同就說沒有共通版本
Assert-Finding -Case '案例17' -Findings $f -TitleLike '每台都有的版本' -Level 'OK'
Assert-Finding -Case '案例17' -Findings $f -TitleLike '沒有任何一個 AEDT 版本是每台機器都有的' -Absent

# 修補版號一樣時要閉嘴——不該講的講了就變雜訊。
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -Release '2026 R1' -FileVersion '2026.1.4')
    (New-Node -Name 'WS02' -Release '2026 R1' -FileVersion '2026.1.4')
)
Assert-Finding -Case '案例17' -Findings $f -TitleLike '修補版號各機不同' -Absent

# ---------------------------------------------------------------------------
# 實機事故：NB 那一台沒有 ANSYS_EM_EXEC_DIR，因為它沒跑過修復。
# 症狀不是報錯，是求解卡在「Determining memory availability on distributed
# machines」不動——完全看不出跟環境變數有關，查了很久才發現。
# 這一項是修復步驟會設的東西，沒設就等於那台沒被整備過。
Write-Host ''
Write-Host '案例 18：有機器沒設 ANSYS_EM_EXEC_DIR，要當成確定問題' -ForegroundColor White
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02' -ExecDir '')
)
Assert-Finding -Case '案例18' -Findings $f -TitleLike 'WS02 沒有設定 ANSYS_EM_EXEC_DIR' `
    -Level 'CONFIRMED' -FixAction 'set-ansys-em-exec-dir'
Assert-Finding -Case '案例18' -Findings $f -TitleLike 'WS02 沒有設定 ANSYS_EM_EXEC_DIR' `
    -DetailLike 'Determining memory availability'

# 兩台都設好就要說正常，不要製造雜訊
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例18' -Findings $f -TitleLike '每台都設好了 ANSYS_EM_EXEC_DIR' -Level 'OK'
Assert-Finding -Case '案例18' -Findings $f -TitleLike '沒有設定 ANSYS_EM_EXEC_DIR' -Absent

# ---------------------------------------------------------------------------
# 實機事故：AEDT 把 Hyper-V 虛擬網卡的位址（172.21.96.1）寫進遠端引擎的命令列，
# 叫引擎回連。對端沒有那個網段的路由，於是引擎永遠連不回來，
# 求解卡在「Determining memory availability on distributed machines」不動。
#
# 原本只有「有虛擬介面」這條【可疑】，但有虛擬介面本身不會出事——
# 排在實體介面前面才會。Metric 越小越優先。
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 19：虛擬網卡優先權高於實體網卡，要當成確定問題' -ForegroundColor White
# 就是實機那一組：vEthernet Metric 15、乙太網路 Metric 25
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -VirtualNics 1 -RealMetric 25 -VirtualMetric 15)
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例19' -Findings $f -TitleLike 'WS01 的虛擬網卡優先權高於實體網卡' `
    -Level 'CONFIRMED' -FixAction 'fix-network-topology'
Assert-Finding -Case '案例19' -Findings $f -TitleLike 'WS01 的虛擬網卡優先權高於實體網卡' `
    -DetailLike 'Determining memory availability'
# 處理指令要直接給，不要只說「請調整優先權」
Assert-Finding -Case '案例19' -Findings $f -TitleLike 'WS01 的虛擬網卡優先權高於實體網卡' `
    -FixLike 'Set-NetIPInterface'

# 虛擬介面排在後面是常態，不可以亮確定燈——不然幾乎每台都會亮，燈就不值錢了
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -VirtualNics 1 -RealMetric 25 -VirtualMetric 40)
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例19' -Findings $f -TitleLike '虛擬網卡優先權高於實體網卡' -Absent
Assert-Finding -Case '案例19' -Findings $f -TitleLike '虛擬或 VPN 介面'

# 完全沒有虛擬介面時兩條都不該出現
$f = Invoke-Merge @(
    (New-Node -Name 'WS01')
    (New-Node -Name 'WS02')
)
Assert-Finding -Case '案例19' -Findings $f -TitleLike '虛擬網卡優先權高於實體網卡' -Absent

# 舊版報告沒有 metric 欄位時要說「讀不到」，不能猜
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -VirtualNics 1 -RealMetric $null -VirtualMetric $null)
    (New-Node -Name 'WS02' -RealMetric $null)
)
Assert-Finding -Case '案例19' -Findings $f -TitleLike '讀不到網路介面的優先權' -Level 'MANUAL'
Assert-Finding -Case '案例19' -Findings $f -TitleLike '虛擬網卡優先權高於實體網卡' -Absent

# 路徑不同只列疑點：可能是安裝位置不同但版本相同，不能斷定一定不行
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -ExecDir 'C:\Program Files\ANSYS Inc\v261\AnsysEM')
    (New-Node -Name 'WS02' -ExecDir 'D:\Ansys\v261\AnsysEM')
)
Assert-Finding -Case '案例18' -Findings $f -TitleLike 'ANSYS_EM_EXEC_DIR 各機路徑不同' -Level 'SUSPECT'

# 舊版報告沒有這個欄位時要說「比不了」，不能當成「沒設定」
$f = Invoke-Merge @(
    (New-Node -Name 'WS01' -NoClusterEnv $true)
    (New-Node -Name 'WS02' -NoClusterEnv $true)
)
Assert-Finding -Case '案例18' -Findings $f -TitleLike '節點報告沒有串機環境變數資料' -Level 'MANUAL'
Assert-Finding -Case '案例18' -Findings $f -TitleLike '沒有設定 ANSYS_EM_EXEC_DIR' -Absent

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
