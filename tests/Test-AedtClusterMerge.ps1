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

function New-Node {
    param(
        [string] $Name,
        [string] $Release  = '2024 R2',
        [string] $Root     = 'C:\Program Files\AnsysEM\v242\Win64',
        [string] $TempDir  = 'C:\Temp',
        [bool]   $RsmRunning = $true,
        [string] $Mpi      = 'IntelMPI',
        [bool]   $MpiRunning = $true,
        [string] $MpiVersion = '2021.8.0',
        [string] $User     = 'ansys',
        [string] $Ip       = '192.168.10.10',
        [string] $Network  = '192.168.10.0/24',
        [int]    $RealNics = 1,
        [int]    $VirtualNics = 0,
        [object[]] $Peers  = @(),
        [string] $CaseId   = 'TEST-001',
        [int]    $Schema   = 1,
        [bool]   $NoAedt   = $false,
        [bool]   $NoTempDir= $false
    )

    $adapters = @()
    for ($i = 0; $i -lt $RealNics; $i++) {
        $adapters += [pscustomobject]@{
            alias = ('Ethernet' + $i); description = 'Intel Ethernet'
            ipv4 = $Ip; prefixLength = 24; gateway = '192.168.10.1'
            isVirtual = $false; network = $Network; networkGuessed = $false
        }
    }
    for ($i = 0; $i -lt $VirtualNics; $i++) {
        $adapters += [pscustomobject]@{
            alias = ('vEthernet ' + $i); description = 'Hyper-V Virtual Ethernet Adapter'
            ipv4 = '172.20.5.1'; prefixLength = 20; gateway = $null
            isVirtual = $true; network = '172.20.0.0/20'; networkGuessed = $false
        }
    }

    $aedt = @()
    if (-not $NoAedt) {
        $aedt += [pscustomobject]@{
            root = $Root; token = 'v242'; release = $Release; fileVersion = '24.2'
            sources = @('env'); cfgFound = $true
            tempDir = $(if ($NoTempDir) { $null } else { $TempDir })
            tempKind = 'local'; tempExists = $true; tempFreeGB = 400
        }
    }

    $mpiDetected = @()
    if ($Mpi) {
        $mpiDetected += [pscustomobject]@{
            vendor = $Mpi; kind = 'service'; name = 'hydra_service'
            status = $(if ($MpiRunning) { 'Running' } else { 'Stopped' })
            running = $MpiRunning; path = 'C:\x\hydra_service.exe'; version = $MpiVersion
        }
    }

    return [pscustomobject]@{
        schemaVersion = $Schema
        tool     = [pscustomobject]@{ name = 'AEDT 串機檢查工具'; version = '0.1.0' }
        caseId   = $CaseId
        generatedAt = '2026-09-07T10:00:00+08:00'
        anonymized  = $false
        facts    = [pscustomobject]@{}
        findings = @()
        actionable = @()
        notAutomatable = @()
        node = [pscustomobject]@{
            computerName = $Name; userName = $User; domain = 'WORKGROUP'
            os = 'Windows 11'; isAdmin = $true; mode = 'DDM'
            physicalCores = 16; logicalCores = 32; memoryGB = 128
            collectedAt = '2026-09-07T10:00:00+08:00'
            aedt = $aedt
            rsm  = [pscustomobject]@{
                installed = $true; running = $RsmRunning
                status = $(if ($RsmRunning) { 'Running' } else { 'Stopped' })
                services = @(); portListening = $RsmRunning; port = 32958
            }
            mpi  = [pscustomobject]@{ detected = $mpiDetected; binaries = @() }
            adapters = $adapters
            selfResolve = @($Ip)
            firewall = [pscustomobject]@{
                profiles = @(); anyProfileOff = $false; clusterRules = @()
            }
            peerProbes = $Peers
        }
    }
}

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
        [switch] $Absent
    )
    $hits = @($Findings | Where-Object {
        $_.title -like ('*' + $TitleLike + '*') -and (-not $Level -or $_.level -eq $Level)
    })
    $want  = if ($Absent) { '不該出現' } else { '應出現' }
    $what  = if ($TitleLike) { '「' + $TitleLike + '」' } else { '任何 ' + $Level + ' 結論' }
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
Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
