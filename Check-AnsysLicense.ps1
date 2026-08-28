#Requires -Version 5.1
<#
.SYNOPSIS
    Ansys License 連線診斷工具 —— 虎門科技股份有限公司

.DESCRIPTION
    在客戶端或授權伺服器上執行，自動判斷角色並找出 License 連線失敗的原因。

    本工具全程唯讀，不會修改貴司任何設定。偵測到根因時，會把修復指令列出來
    讓貴司 IT 自行判斷是否執行。

    結論分三級，工具不會假裝自己知道：
      【確定】證據可唯一解釋現象
      【可疑】有異常但無法斷言為根因
      【需人工】資料不足或架構未經驗證，請回傳報告

.PARAMETER CaseId
    案件編號。伺服器端與用戶端跑出來的兩份報告用同一個編號才對得起來。
    未指定時依序取用 expected.json 內的值、電腦名稱加時間戳。

.PARAMETER Expected
    預期組態／基線檔（JSON）。有的話會做符合性與變更比對，結論會銳利很多。
    預設自動尋找腳本旁的 expected.json。

.PARAMETER Product
    使用者打不開的產品名稱，可多個。例：-Product HFSS
    工具會查對照表找出該產品需要的所有 increment，逐一比對伺服器上是否存在、是否用完，
    並挑鑑別度最高的幾項做實際取得測試。
    這是最好用的參數——使用者只會說「HFSS 打不開」，不會說 feature 名稱。

.PARAMETER Feature
    要實際測試取得授權的 FlexNet feature（increment）名稱，可多個。
    例：-Feature ansys,anshpc
    已經知道 feature 名稱時才用；一般情況用 -Product 即可。

.PARAMETER SaveBaseline
    裝機驗收時使用。把當下的正確狀態存成基線檔，供日後故障時比對。
    此模式不做故障判定。

.PARAMETER Anonymize
    去識別化。把使用者帳號、內網 IP、第三方軟體名稱雜湊處理後才寫進報告。
    供資安要求較嚴格的單位使用。

.PARAMETER Server
    指定要測試的授權伺服器，格式 埠號@主機名稱，可多個。
    指定後會取代用戶端自己解析出來的清單，用來驗證某一台特定伺服器是否正常。
    例：-Server 1055@LICSRV01

.PARAMETER NoCheckout
    即使指定了 -Feature 也不做實際 checkout 測試，只做觀察。

.PARAMETER Json
    另外輸出一份機器可讀的 findings JSON。
    供我方的解決包產生器使用；本工具本身不會執行任何修復動作。
    未指定路徑時與報告放在同一個目錄。

.PARAMETER OutDir
    報告輸出目錄，預設為腳本所在目錄下的 reports\。

.EXAMPLE
    .\Check-AnsysLicense.ps1
    一般診斷。

.EXAMPLE
    .\Check-AnsysLicense.ps1 -CaseId TADC-2026-0042 -Feature ansys
    指定案件編號，並實際測試能不能取得 ansys 這個 feature。

.EXAMPLE
    .\Check-AnsysLicense.ps1 -SaveBaseline
    裝機驗收時建立基線。

.NOTES
    虎門科技股份有限公司 Taiwan Auto-Design Co.
    技術支援：cae-support@cadmen.com

    本工具唯讀。判定邏輯僅在 Ansys 2021 R1 以後的 Common Licensing 架構上驗證過；
    偵測到更早的 Licensing Interconnect 架構時會自動退化為純資料收集。
#>
[CmdletBinding()]
param(
    [string]   $CaseId,
    [string]   $Expected,
    [string[]] $Product,
    [string[]] $Feature,
    [string[]] $Server,
    [switch]   $SaveBaseline,
    [switch]   $Anonymize,
    [switch]   $NoCheckout,
    [switch]   $Json,
    [string]   $OutDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$TOOL_NAME    = 'Ansys License 連線診斷工具'
$TOOL_VERSION = '1.0.0'
$VENDOR_NAME  = '虎門科技股份有限公司'
$VENDOR_EN    = 'Taiwan Auto-Design Co.'
$VENDOR_MAIL  = 'cae-support@cadmen.com'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================================
#  資料模型
# ============================================================================
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Sections = New-Object System.Collections.Generic.List[object]
$script:Facts    = [ordered]@{}

# 判定等級。排序用的權重越小越前面。
$LEVEL_META = [ordered]@{
    'CONFIRMED' = @{ Label = '確定'   ; Rank = 0; Color = '#d13438' }
    'SUSPECT'   = @{ Label = '可疑'   ; Rank = 1; Color = '#c07800' }
    'MANUAL'    = @{ Label = '需人工' ; Rank = 2; Color = '#6b5bd6' }
    'OK'        = @{ Label = '正常'   ; Rank = 3; Color = '#107c10' }
    'INFO'      = @{ Label = '參考'   ; Rank = 4; Color = '#5a6270' }
}

# ----------------------------------------------------------------------------
#  產品 -> increment 對照表（feature_map.json，選用）
#  由 Ansys 原廠的 Product to License Increment Mapping 文件轉換而成。
#  沒有這個檔案時 -Product 無法使用，但其餘功能不受影響。
# ----------------------------------------------------------------------------
$script:FeatureMap = $null
$featureMapPath = Join-Path $ScriptDir 'feature_map.json'
if (Test-Path -LiteralPath $featureMapPath) {
    try {
        $script:FeatureMap = Get-Content -LiteralPath $featureMapPath -Raw -Encoding UTF8 |
                             ConvertFrom-Json
    } catch {
        $script:FeatureMap = $null
    }
}

function Find-ProductEntry {
    <#
        依使用者輸入的產品名找出對照表中的候選項目。

        重點：不要在第一個規則命中就短路回傳。同一個產品在對照表裡常有新舊兩種名稱，
        而且內容差很多——例如「Ansys HFSS」（legacy）用 hfss_solve，
        「Ansys Electronics Premium HFSS」（commercial）用 elec_solve_hfss，
        14 項與 11 項之中只有 5 項相同。挑錯邊會給出完全錯誤的診斷。

        所以這裡回傳「所有」候選，依精確度排序，由呼叫端逐一比對後用證據決定是哪一個。
    #>
    param([string] $Query)
    if ($null -eq $script:FeatureMap) { return @() }

    $names = @($script:FeatureMap.products.PSObject.Properties.Name)
    $q = $Query.Trim()
    if (-not $q) { return @() }

    $esc     = [regex]::Escape($q)
    $ranked  = New-Object System.Collections.Generic.List[object]
    $seenNm  = @{}

    function Add-Cand {
        param([string] $Name, [int] $Rank)
        if ($seenNm.ContainsKey($Name.ToLower())) { return }
        $seenNm[$Name.ToLower()] = $true
        $ranked.Add([pscustomobject]@{ Name = $Name; Rank = $Rank }) | Out-Null
    }

    foreach ($n in $names) { if ($n -ieq $q)               { Add-Cand -Name $n -Rank 0 } }
    foreach ($n in $names) { if ($n -ieq ('Ansys ' + $q))  { Add-Cand -Name $n -Rank 1 } }
    foreach ($n in $names) { if ($n -imatch ('(^|\s)' + $esc + '($|\s)')) { Add-Cand -Name $n -Rank 2 } }

    $words = @($q -split '\s+' | Where-Object { $_ })
    if ($words.Count -gt 0) {
        foreach ($n in $names) {
            $all = $true
            foreach ($w in $words) { if ($n -inotmatch [regex]::Escape($w)) { $all = $false } }
            if ($all) { Add-Cand -Name $n -Rank 3 }
        }
    }

    return @($ranked | Sort-Object Rank, Name | ForEach-Object { $_.Name })
}

function Get-IncrementInfo {
    param([string] $Name)
    if ($null -eq $script:FeatureMap) { return $null }
    $p = $script:FeatureMap.increments.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

# ----------------------------------------------------------------------------
#  修復動作目錄
#
#  這裡只是「把診斷結果標記成某一類可能的修復動作」，本工具不會執行任何動作。
#  標記的用途是讓 -Json 的輸出可以被我方的解決包產生器消費。
#
#  Tier 依「出錯時的影響半徑」分級，不是依修改難易度：
#    1 只影響 Ansys、只影響本機、可逆
#    2 動到機器層級設定，需逐項明確授權
#    3 會波及其他軟體或需跨機器協調，永不自動化
#  詳見 docs/修復工具設計.md
# ----------------------------------------------------------------------------
$ACTION_CATALOG = [ordered]@{
    'set-license-server'       = @{ Tier = 1; Label = '設定授權伺服器指向' }
    'remove-stale-env'         = @{ Tier = 1; Label = '刪除殘留的環境變數' }
    'remove-user-ini'          = @{ Tier = 1; Label = '刪除使用者層級的 ansyslmd.ini' }
    'clear-license-cache'      = @{ Tier = 1; Label = '清除本機授權快取' }
    'restart-license-manager'  = @{ Tier = 1; Label = '重新啟動 License Manager' }
    'restore-from-baseline'    = @{ Tier = 1; Label = '把設定還原成基線狀態' }
    'enable-elastic-licensing' = @{ Tier = 1; Label = '啟用雲端彈性授權' }
    'enable-elastic-service'   = @{ Tier = 1; Label = '啟用 web-elastic 授權服務' }
    'add-firewall-rules'       = @{ Tier = 2; Label = '新增防火牆例外' }
    'add-hosts-entry'          = @{ Tier = 2; Label = '新增 hosts 檔對應' }
    'install-license-file'     = @{ Tier = 2; Label = '安裝或更換 License 檔案' }
    'import-cls-credential'    = @{ Tier = 2; Label = '匯入 CLS 憑證' }
    'stop-conflicting-service' = @{ Tier = 3; Label = '停用占用連接埠的第三方服務' }
    'change-flexnet-port'      = @{ Tier = 3; Label = '變更 FlexNet 連接埠' }
    'reinstall-license-manager'= @{ Tier = 3; Label = '重新安裝 License Manager' }
}

function Add-Finding {
    param(
        [ValidateSet('CONFIRMED', 'SUSPECT', 'MANUAL', 'OK', 'INFO')]
        [string] $Level,
        [string] $Title,
        [string] $Detail = '',
        [string] $Fix = '',
        [string] $Ref = '',
        # 以下三個給 -Json 用，供解決包產生器消費。本工具不會執行任何修復。
        [string] $FixAction = '',
        [hashtable] $FixParams = $null,
        # 動作要在哪一台機器執行。從用戶端看到的伺服器問題，修復要在伺服器上做，
        # 沒有這個欄位的話，解決包產生器會把它誤放進用戶端的計畫裡。
        [ValidateSet('local', 'licenseServer')]
        [string] $FixOn = 'local'
    )
    $tier = 0
    if ($FixAction -and $ACTION_CATALOG.Contains($FixAction)) {
        $tier = $ACTION_CATALOG[$FixAction].Tier
    }
    $script:Findings.Add([pscustomobject]@{
        Level = $Level; Title = $Title; Detail = $Detail; Fix = $Fix; Ref = $Ref
        FixAction = $FixAction; FixTier = $tier; FixParams = $FixParams; FixOn = $FixOn
    }) | Out-Null
}

function Add-Section {
    param([string] $Name)
    $s = [pscustomobject]@{
        Name  = $Name
        Lines = (New-Object System.Collections.Generic.List[string])
    }
    $script:Sections.Add($s) | Out-Null
    return $s
}

function Add-Row {
    param($Section, [string] $Text = '')
    $Section.Lines.Add($Text) | Out-Null
}

# ============================================================================
#  去識別化
# ============================================================================
function Protect-Value {
    param([string] $Value, [string] $Prefix = 'X')
    if (-not $Anonymize)                   { return $Value }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    $md5   = [System.Security.Cryptography.MD5]::Create()
    $bytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLower()))
    $hex   = ''
    foreach ($b in $bytes[0..3]) { $hex += $b.ToString('x2') }
    $md5.Dispose()
    return ($Prefix + '-' + $hex)
}

function Protect-Text {
    param([string] $Text)
    if (-not $Anonymize) { return $Text }
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    # 內網 IP
    $t = [regex]::Replace($Text,
        '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b',
        { param($m) Protect-Value -Value $m.Value -Prefix 'ip' })
    # 目前使用者帳號
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $t = $t -replace [regex]::Escape($env:USERNAME), (Protect-Value -Value $env:USERNAME -Prefix 'user')
    }
    return $t
}

# ============================================================================
#  console 輸出（控制寬度，避免中文在 chcp 65001 下的雙寬字元換行問題）
# ============================================================================
function Write-Head {
    param([string] $Text)
    Write-Host ''
    Write-Host ('-' * 60) -ForegroundColor DarkGray
    Write-Host ("  " + $Text) -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray
}

function Write-Step {
    param([string] $Text)
    Write-Host ("  " + $Text) -ForegroundColor Gray
}

# ============================================================================
#  工具函式
# ============================================================================
function Get-EnvAny {
    param([string] $Name)
    $v = [Environment]::GetEnvironmentVariable($Name, 'Machine')
    if ([string]::IsNullOrWhiteSpace($v)) {
        $v = [Environment]::GetEnvironmentVariable($Name, 'User')
    }
    if ([string]::IsNullOrWhiteSpace($v)) {
        $v = [Environment]::GetEnvironmentVariable($Name, 'Process')
    }
    return $v
}

function Invoke-Exe {
    <#
        執行外部程式並回傳 stdout + stderr 合併字串。逾時就殺掉並回傳 __TIMEOUT__。

        注意：參數名稱不可叫 $Args——那是 PowerShell 的自動變數，會被覆蓋。
        也不用 Start-Job：-ArgumentList 會把陣列攤平，導致參數傳不進去，而且每次
        起一個 job 太慢。改用 Process 類別，順便拿到真正的逾時控制。
    #>
    param([string] $Path, [string[]] $Arguments, [int] $TimeoutSec = 60)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $quoted = @()
    foreach ($a in $Arguments) {
        if ($a -match '\s') { $quoted += ('"' + $a + '"') } else { $quoted += $a }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Path
    $psi.Arguments              = ($quoted -join ' ')
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return $null
    }
    if ($null -eq $proc) { return $null }

    # 先開始非同步讀取再等待結束，否則輸出量大時會因為緩衝區塞滿而死結
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        try { $proc.Dispose() } catch { }
        return '__TIMEOUT__'
    }

    $text = ''
    try { $text = $outTask.Result } catch { }
    try {
        $e = $errTask.Result
        if (-not [string]::IsNullOrWhiteSpace($e)) { $text = $text + [Environment]::NewLine + $e }
    } catch { }
    try { $proc.Dispose() } catch { }
    return $text
}

# ============================================================================
#  階段 0：環境與角色
# ============================================================================
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor White
Write-Host ("  " + $TOOL_NAME + "  v" + $TOOL_VERSION) -ForegroundColor White
Write-Host ("  " + $VENDOR_NAME) -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor White
Write-Host ''
Write-Host '  本工具全程唯讀，不會修改貴司任何設定。' -ForegroundColor Green

Write-Head '階段 0　環境與角色'

$sec0 = Add-Section '環境與角色'

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$osInfo = $null
try { $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }

$script:Facts['執行時間']       = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
$script:Facts['電腦名稱']       = $env:COMPUTERNAME
$script:Facts['作業系統']       = if ($osInfo) { $osInfo.Caption + ' (' + $osInfo.Version + ')' } else { '(查不到)' }
$script:Facts['PowerShell']     = $PSVersionTable.PSVersion.ToString()
$script:Facts['執行權限']       = if ($isAdmin) { '系統管理員' } else { '一般使用者' }
$script:Facts['工具版本']       = $TOOL_VERSION

# --- ANSYSLIC_DIR：決定哪一份 ansyslmd.ini 生效 ---
$licDir = Get-EnvAny 'ANSYSLIC_DIR'
$licDirFromEnv = $true
if ([string]::IsNullOrWhiteSpace($licDir)) {
    $licDirFromEnv = $false
    foreach ($cand in @('C:\Program Files\ANSYS Inc\Shared Files\Licensing',
                        'C:\Program Files\Ansys Inc\Shared Files\Licensing')) {
        if (Test-Path -LiteralPath $cand) { $licDir = $cand; break }
    }
}
$script:Facts['ANSYSLIC_DIR'] = if ($licDir) { $licDir } else { '(未設定且找不到預設路徑)' }

$serverWin = $null
if ($licDir) { $serverWin = Join-Path $licDir 'winx64' }

# --- 角色 ---
$hasLmgrd  = $false
$cvdSvc    = $null
if ($serverWin) { $hasLmgrd = Test-Path -LiteralPath (Join-Path $serverWin 'lmgrd.exe') }
$cvdSvc = Get-Service -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -like '*License Manager*' -or $_.Name -like '*ansyslmd*' } |
          Select-Object -First 1

$isServer = ($hasLmgrd -or ($null -ne $cvdSvc))

# 用戶端：找所有版次的 licensingclient
$clientUtils = @()
foreach ($root in @('C:\Program Files\ANSYS Inc', 'C:\Program Files\Ansys Inc')) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $clientUtils += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^v\d{3}$' } |
        ForEach-Object {
            [pscustomobject]@{
                Version = $_.Name
                Util    = (Join-Path $_.FullName 'licensingclient\winx64\ansysli_util.exe')
                LmUtil  = (Join-Path $_.FullName 'licensingclient\winx64\lmutil.exe')
            }
        })
}
# 2024 R2 及以前的 AEDT 獨立安裝樹
if (Test-Path -LiteralPath 'C:\Program Files\AnsysEM') {
    $clientUtils += @(Get-ChildItem -LiteralPath 'C:\Program Files\AnsysEM' -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^v\d{3}$' } |
        ForEach-Object {
            [pscustomobject]@{
                Version = ($_.Name + ' (AnsysEM)')
                Util    = (Join-Path $_.FullName 'Win64\licensingclient\winx64\ansysli_util.exe')
                LmUtil  = (Join-Path $_.FullName 'Win64\licensingclient\winx64\lmutil.exe')
            }
        })
}
# 去重：Windows 路徑不分大小寫，"ANSYS Inc" 與 "Ansys Inc" 是同一個目錄，
# 不去重的話每個版次都會被找到兩次，查詢也會白跑兩遍。
$seenUtil = @{}
$deduped  = New-Object System.Collections.Generic.List[object]
foreach ($c in $clientUtils) {
    if (-not (Test-Path -LiteralPath $c.Util)) { continue }
    $key = $c.Util.ToLower()
    if ($seenUtil.ContainsKey($key)) { continue }
    $seenUtil[$key] = $true
    $deduped.Add($c) | Out-Null
}
$clientUtils = @($deduped | Sort-Object Version)
$isClient = ($clientUtils.Count -gt 0)

$roleText = @()
if ($isServer) { $roleText += 'License Server' }
if ($isClient) { $roleText += 'Client' }
if ($roleText.Count -eq 0) { $roleText += '無法判定' }
$roleLabel = ($roleText -join ' + ')
$script:Facts['本機角色'] = $roleLabel

$roleTag = 'Unknown'
if ($isServer -and $isClient) { $roleTag = 'Server+Client' }
elseif ($isServer)            { $roleTag = 'Server' }
elseif ($isClient)            { $roleTag = 'Client' }

# --- 架構：CVD（2021 R1+）還是舊 Interconnect（2020 R2-）---
$isLegacy = $false
if ($serverWin) {
    $isLegacy = Test-Path -LiteralPath (Join-Path $serverWin 'ansysli_server.exe')
}
$script:Facts['授權架構'] = if ($isLegacy) {
    'Ansys Licensing Interconnect（2020 R2 及以前）'
} else {
    'Ansys Common Licensing / CVD（2021 R1 以後）'
}

Add-Row $sec0 ('電腦名稱      : ' + $env:COMPUTERNAME)
Add-Row $sec0 ('作業系統      : ' + $script:Facts['作業系統'])
Add-Row $sec0 ('PowerShell    : ' + $script:Facts['PowerShell'])
Add-Row $sec0 ('執行權限      : ' + $script:Facts['執行權限'])
Add-Row $sec0 ('本機角色      : ' + $roleLabel)
Add-Row $sec0 ('授權架構      : ' + $script:Facts['授權架構'])
Add-Row $sec0 ('ANSYSLIC_DIR  : ' + $script:Facts['ANSYSLIC_DIR'])
if (-not $licDirFromEnv -and $licDir) {
    Add-Row $sec0 '                （環境變數未設定，以上為推測的預設路徑）'
}
Add-Row $sec0 ''
Add-Row $sec0 '已安裝的授權用戶端：'
if ($clientUtils.Count -eq 0) {
    Add-Row $sec0 '  （找不到，本機可能只裝了 License Manager）'
} else {
    foreach ($c in $clientUtils) { Add-Row $sec0 ('  ' + $c.Version) }
}

Write-Step ('角色：' + $roleLabel)
Write-Step ('架構：' + $(if ($isLegacy) { '舊 Interconnect' } else { 'Common Licensing (CVD)' }))

if (-not $isAdmin) {
    Add-Finding -Level 'INFO' -Title '未以系統管理員身分執行' `
        -Detail '部分資訊（如占用連接埠的程序名稱、部分服務狀態）可能查不到。建議右鍵以系統管理員身分重跑一次。'
}

if ($isLegacy) {
    Add-Finding -Level 'MANUAL' -Title '偵測到 2020 R2 以前的舊 Licensing Interconnect 架構' `
        -Detail ('本工具的判定邏輯只在 2021 R1 以後的 Common Licensing 架構上驗證過，' +
                 '因此不對這台機器下任何根因結論，改為完整收集資料。' + [Environment]::NewLine +
                 '請將本報告回傳給技術支援。') `
        -Fix ('回傳報告至 ' + $VENDOR_MAIL)
}

if (-not $licDir) {
    Add-Finding -Level 'CONFIRMED' -Title '找不到 Ansys 授權目錄' `
        -Detail '環境變數 ANSYSLIC_DIR 未設定，也找不到預設安裝路徑。這台機器可能未安裝 Ansys 產品或 License Manager，或安裝已損毀。' `
        -Fix '請確認本機是否已安裝 Ansys 產品；若已安裝，請重新安裝 License Manager 以還原環境變數。'
}

# ============================================================================
#  階段 1：用戶端設定
# ============================================================================
Write-Head '階段 1　用戶端設定'
$sec1 = Add-Section '用戶端設定'

$activeIni = $null
if ($licDir) { $activeIni = Join-Path $licDir 'ansyslmd.ini' }

Add-Row $sec1 '【生效的設定檔】ANSYSLIC_DIR 底下這一份才算數'
if ($activeIni -and (Test-Path -LiteralPath $activeIni)) {
    Add-Row $sec1 ('  ' + $activeIni)
    $iniLines = @(Get-Content -LiteralPath $activeIni -ErrorAction SilentlyContinue)
    if ($iniLines.Count -eq 0) {
        Add-Row $sec1 '  （檔案存在但內容為空）'
        Add-Finding -FixAction 'set-license-server' -Level 'CONFIRMED' -Title 'ansyslmd.ini 是空的' `
            -Detail ($activeIni + ' 存在但沒有任何內容，用戶端不知道要找哪一台授權伺服器。') `
            -Fix '請用 Ansys Licensing Settings 重新設定授權伺服器，或向技術支援索取正確的設定內容。'
    } else {
        foreach ($l in $iniLines) { Add-Row $sec1 ('    ' + (Protect-Text $l)) }
        $hasServerLine = @($iniLines | Where-Object { $_ -match '^\s*SERVER\s*=' }).Count -gt 0
        $hasElastic    = @($iniLines | Where-Object { $_ -match '^\s*ANSYS_ELASTIC_CLS\s*=' }).Count -gt 0
        if (-not $hasServerLine -and -not $hasElastic) {
            Add-Finding -FixAction 'set-license-server' -Level 'CONFIRMED' -Title 'ansyslmd.ini 沒有 SERVER= 設定' `
                -Detail '設定檔中找不到任何 SERVER= 行，用戶端沒有指向任何授權伺服器。' `
                -Fix '請用 Ansys Licensing Settings 加入授權伺服器。'
        }
        if (-not $hasServerLine -and $hasElastic) {
            Add-Finding -Level 'INFO' -Title '本機設定為雲端彈性授權（AEC）' `
                -Detail '設定檔中只有 ANSYS_ELASTIC_CLS，沒有本地授權伺服器。本工具 v1 不診斷 AEC，請回傳報告。'
        }
    }
} else {
    Add-Row $sec1 '  >> 檔案不存在'
    if ($licDir) {
        Add-Finding -FixAction 'set-license-server' -Level 'CONFIRMED' -Title '找不到 ansyslmd.ini' `
            -Detail ('預期位置：' + $activeIni + [Environment]::NewLine +
                     '用戶端沒有這個檔案就不知道要連哪一台授權伺服器。') `
            -Fix '請用 Ansys Licensing Settings 設定授權伺服器，或從同網段一台正常的機器複製一份到相同路徑。'
    }
}

# 使用者層級設定：優先度高於全域
Add-Row $sec1 ''
Add-Row $sec1 '【使用者層級設定】優先度高於上面那份'
$userIni = Join-Path $env:APPDATA '.ansys_licensing\ansyslmd.ini'
Add-Row $sec1 ('  ' + (Protect-Text $userIni))
if (Test-Path -LiteralPath $userIni) {
    Add-Row $sec1 '  >> 存在，會覆蓋全域設定：'
    foreach ($l in @(Get-Content -LiteralPath $userIni -ErrorAction SilentlyContinue)) {
        Add-Row $sec1 ('    ' + (Protect-Text $l))
    }
    Add-Finding -FixAction 'remove-user-ini' -FixParams @{ path = $userIni } -Level 'SUSPECT' -Title '存在使用者層級的 ansyslmd.ini' `
        -Detail ('這份設定的優先度高於全域設定，會蓋掉它。' + [Environment]::NewLine +
                 '若「同一台機器只有這個使用者不能用」，這通常就是原因。' + [Environment]::NewLine +
                 '取值順序：環境變數 > 使用者層級 ini > 全域安裝設定') `
        -Fix ('確認不需要後刪除：' + [Environment]::NewLine + '  Remove-Item "' + $userIni + '"')
} else {
    Add-Row $sec1 '  不存在（目前走全域設定）'
}

# 殘留的其他 ansyslmd.ini
Add-Row $sec1 ''
Add-Row $sec1 '【其他 ansyslmd.ini】多為舊安裝樹殘留，改到這些不會生效'
$otherIniCandidates = @(
    'C:\Program Files\AnsysEM\Shared Files\Licensing\ansyslmd.ini',
    'C:\Program Files\AnsysMotorCAD\Shared Files\Licensing\ansyslmd.ini'
)
$foundOther = $false
foreach ($op in $otherIniCandidates) {
    if (-not (Test-Path -LiteralPath $op)) { continue }
    if ($activeIni -and ($op -ieq $activeIni)) { continue }
    $foundOther = $true
    $lw = (Get-Item -LiteralPath $op).LastWriteTime.ToString('yyyy-MM-dd')
    Add-Row $sec1 ('  [殘留] ' + $op + '   (最後修改 ' + $lw + ')')
    foreach ($l in @(Get-Content -LiteralPath $op -ErrorAction SilentlyContinue)) {
        Add-Row $sec1 ('      ' + (Protect-Text $l))
    }
}
if (-not $foundOther) { Add-Row $sec1 '  沒有其他殘留' }

# 環境變數
Add-Row $sec1 ''
Add-Row $sec1 '【授權相關環境變數】'
$envNames = @('ANSYSLIC_DIR', 'ANSYSLMD_LICENSE_FILE', 'ANSYSLI_SERVERS',
              'ANSYSLI_LCP', 'ANSYSLI_ELASTIC', 'FLEXLM_TIMEOUT')
foreach ($n in $envNames) {
    $v = Get-EnvAny $n
    if ([string]::IsNullOrWhiteSpace($v)) {
        Add-Row $sec1 ('  ' + $n.PadRight(24) + '未設定')
    } else {
        Add-Row $sec1 ('  ' + $n.PadRight(24) + (Protect-Text $v))
    }
}

$vLic = Get-EnvAny 'ANSYSLMD_LICENSE_FILE'
if (-not [string]::IsNullOrWhiteSpace($vLic)) {
    Add-Finding -FixAction 'remove-stale-env' -FixParams @{ names = @('ANSYSLMD_LICENSE_FILE'); currentValue = $vLic } -Level 'SUSPECT' -Title 'ANSYSLMD_LICENSE_FILE 環境變數存在' `
        -Detail ('目前值：' + (Protect-Text $vLic) + [Environment]::NewLine +
                 '這個變數會把它指定的伺服器「插到伺服器清單最前面」，不是取代。' + [Environment]::NewLine +
                 '所以症狀通常是「連到錯的伺服器」或「在無效的伺服器上卡到逾時」，而不是完全連不上。' + [Environment]::NewLine +
                 '多數情況這是舊安裝的殘留。') `
        -Fix ('確認不需要後刪除（需系統管理員）：' + [Environment]::NewLine +
              '  [Environment]::SetEnvironmentVariable(''ANSYSLMD_LICENSE_FILE'', $null, ''Machine'')')
}
$vSrv = Get-EnvAny 'ANSYSLI_SERVERS'
if ((-not [string]::IsNullOrWhiteSpace($vSrv)) -and (-not $isLegacy)) {
    Add-Finding -FixAction 'remove-stale-env' -FixParams @{ names = @('ANSYSLI_SERVERS'); currentValue = $vSrv } -Level 'SUSPECT' -Title 'ANSYSLI_SERVERS 環境變數存在，但本機是 Common Licensing 架構' `
        -Detail ('目前值：' + (Protect-Text $vSrv) + [Environment]::NewLine +
                 '2021 R1 以後的架構不再使用 Licensing Interconnect，這個變數應為舊安裝殘留。') `
        -Fix '確認不需要後刪除此環境變數。'
}

# 權威來源：實際解析到的伺服器
Add-Row $sec1 ''
Add-Row $sec1 '【實際解析到的授權伺服器】由用戶端自己回報，這是最可靠的來源'
$resolvedServers = New-Object System.Collections.Generic.List[string]
foreach ($c in $clientUtils) {
    $out = Invoke-Exe -Path $c.Util -Arguments @('-printlicpath', 'FLEXLM') -TimeoutSec 30
    if ($null -eq $out -or $out -eq '__TIMEOUT__') {
        Add-Row $sec1 ('  ' + $c.Version.PadRight(18) + '(查詢失敗或逾時)')
        continue
    }
    $path = ''
    if ($out -match 'FLEXlm Path:\s*(.+)') { $path = $Matches[1].Trim() }
    Add-Row $sec1 ('  ' + $c.Version.PadRight(18) + $(if ($path) { Protect-Text $path } else { '(空)' }))
    if ($path) {
        foreach ($entry in ($path -split ';')) {
            $e = $entry.Trim()
            if ($e -and (-not $resolvedServers.Contains($e))) { $resolvedServers.Add($e) | Out-Null }
        }
    }
}
if ($clientUtils.Count -eq 0) {
    Add-Row $sec1 '  （本機沒有安裝授權用戶端，略過）'
}

if ($resolvedServers.Count -eq 0 -and $isClient) {
    Add-Finding -FixAction 'set-license-server' -Level 'CONFIRMED' -Title '用戶端解析不到任何授權伺服器' `
        -Detail '所有已安裝版次的用戶端回報的伺服器清單都是空的。設定檔可能遺失、為空、或格式不正確。' `
        -Fix '請用 Ansys Licensing Settings 重新設定授權伺服器。'
}

# -Server 覆寫：用來驗證特定一台伺服器，不動用戶端設定
if ($Server -and $Server.Count -gt 0) {
    $resolvedServers = New-Object System.Collections.Generic.List[string]
    foreach ($s in $Server) {
        $t = $s.Trim()
        if (-not $t) { continue }
        if ($t -notmatch '@') { $t = '1055@' + $t }
        if (-not $resolvedServers.Contains($t)) { $resolvedServers.Add($t) | Out-Null }
    }
    Add-Row $sec1 ''
    Add-Row $sec1 ('【已用 -Server 參數覆寫】只測試指定的伺服器：' +
                   (Protect-Text ($resolvedServers -join ', ')))
    Add-Finding -Level 'INFO' -Title '本次執行指定了要測試的伺服器' `
        -Detail ('使用 -Server 參數覆寫，只測試 ' + (Protect-Text ($resolvedServers -join ', ')) + '。' +
                 [Environment]::NewLine + '本機用戶端實際的設定不一定與此相同。')
}

Write-Step ('解析到 ' + $resolvedServers.Count + ' 個授權伺服器設定')

# ============================================================================
#  階段 2：連線測試
# ============================================================================
Write-Head '階段 2　連線測試'
$sec2 = Add-Section '連線測試'

# 找一支可用的 lmutil
$lmutil = $null
foreach ($c in $clientUtils) {
    if (Test-Path -LiteralPath $c.LmUtil) { $lmutil = $c.LmUtil; break }
}
if ((-not $lmutil) -and $serverWin) {
    $cand = Join-Path $serverWin 'lmutil.exe'
    if (Test-Path -LiteralPath $cand) { $lmutil = $cand }
}
Add-Row $sec2 ('使用的 lmutil : ' + $(if ($lmutil) { $lmutil } else { '(找不到)' }))
Add-Row $sec2 ''

$connOk       = $false
$anyServerUp  = $false
$serverStates = New-Object System.Collections.Generic.List[object]

if ($resolvedServers.Count -eq 0) {
    Add-Row $sec2 '沒有可測試的伺服器設定，略過。'
} elseif (-not $lmutil) {
    Add-Row $sec2 '找不到 lmutil.exe，無法進行連線測試。'
    Add-Finding -Level 'MANUAL' -Title '找不到 lmutil.exe' `
        -Detail '無法執行連線測試。Ansys 安裝可能不完整。' -Fix ('請回傳報告至 ' + $VENDOR_MAIL)
} else {
    foreach ($srv in $resolvedServers) {
        $port = ''; $hostName = ''
        if ($srv -match '^(\d+)@(.+)$') { $port = $Matches[1]; $hostName = $Matches[2] }
        else { $hostName = $srv; $port = '1055' }

        Add-Row $sec2 ('=== ' + (Protect-Text $srv) + ' ===')
        Write-Step ('測試 ' + $srv)

        $state = [pscustomobject]@{
            Server = $srv; Port = $port; Host = $hostName
            Dns = $false; Tcp = $false; LmgrdUp = $false; DaemonUp = $false
            FlexErr = ''; WinSock = ''; Raw = ''
        }

        # DNS
        $ips = @()
        try {
            $ips = @([System.Net.Dns]::GetHostAddresses($hostName) |
                     Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                     ForEach-Object { $_.IPAddressToString })
        } catch { }
        if ($ips.Count -gt 0) {
            $state.Dns = $true
            Add-Row $sec2 ('  名稱解析      : 成功 -> ' + (Protect-Text ($ips -join ', ')))
        } else {
            Add-Row $sec2 '  名稱解析      : 失敗'
        }

        # TCP
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $iar = $tcp.BeginConnect($hostName, [int]$port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(5000, $false) -and $tcp.Connected) {
                $state.Tcp = $true
                $tcp.EndConnect($iar)
            }
            $tcp.Close()
        } catch { }
        Add-Row $sec2 ('  TCP ' + $port + ' 連線   : ' + $(if ($state.Tcp) { '成功' } else { '失敗' }))

        # lmstat
        $out = Invoke-Exe -Path $lmutil -Arguments @('lmstat', '-c', $srv) -TimeoutSec 60
        if ($null -eq $out) { $out = '' }
        $state.Raw = $out
        if ($out -eq '__TIMEOUT__') {
            Add-Row $sec2 '  lmstat        : 逾時（超過 60 秒無回應）'
            $state.WinSock = 'TIMEOUT'
        } else {
            if ($out -match 'license server UP')      { $state.LmgrdUp  = $true }
            if ($out -match 'ansyslmd:\s*UP')         { $state.DaemonUp = $true }
            if ($out -match '\((-\d+),(\d+)(?::(\d+))?') {
                $state.FlexErr = $Matches[1]
                if ($Matches[3]) { $state.WinSock = $Matches[3] } else { $state.WinSock = $Matches[2] }
            }
            $wsMsg = ''
            if ($out -match 'WinSock:\s*([^"]+)') { $wsMsg = $Matches[1].Trim() }

            Add-Row $sec2 ('  lmgrd         : ' + $(if ($state.LmgrdUp) { 'UP' } else { 'DOWN / 無回應' }))
            Add-Row $sec2 ('  ansyslmd      : ' + $(if ($state.DaemonUp) { 'UP' } else { 'DOWN / 無回應' }))
            if ($state.FlexErr) {
                Add-Row $sec2 ('  FlexNet 錯誤  : ' + $state.FlexErr +
                               $(if ($state.WinSock) { '  (WinSock ' + $state.WinSock + ')' } else { '' }) +
                               $(if ($wsMsg) { '  ' + $wsMsg } else { '' }))
            }
        }

        $serverStates.Add($state) | Out-Null
        if ($state.LmgrdUp -and $state.DaemonUp) { $connOk = $true; $anyServerUp = $true }
        Add-Row $sec2 ''
    }
}

# --- 連線判定 ---
if ($serverStates.Count -gt 0 -and -not $isLegacy) {
    $allBad = $true
    foreach ($st in $serverStates) {
        if ($st.LmgrdUp -and $st.DaemonUp) { $allBad = $false }
    }

    foreach ($st in $serverStates) {
        $tag = Protect-Text $st.Server

        if ($st.LmgrdUp -and $st.DaemonUp) {
            Add-Finding -Level 'OK' -Title ('授權伺服器連線正常：' + $tag) `
                -Detail 'lmgrd 與 ansyslmd 都在運作，用戶端已成功連上。'
            continue
        }

        if ($st.LmgrdUp -and (-not $st.DaemonUp)) {
            Add-Finding -FixAction 'restart-license-manager' -FixOn 'licenseServer' -Level 'CONFIRMED' -Title ('vendor daemon 未運作：' + $tag) `
                -Detail ('lmgrd 有回應，但 ansyslmd（實際發放授權的程式）沒有運作。' + [Environment]::NewLine +
                         '對應 FlexNet 錯誤 -97。授權伺服器等於半死狀態。') `
                -Fix ('請在授權伺服器上：' + [Environment]::NewLine +
                      '  1. 開啟 Ansys License Management Center（以系統管理員身分）' + [Environment]::NewLine +
                      '  2. View Status/Start/Stop License Manager -> STOP -> START' + [Environment]::NewLine +
                      '  3. 若仍失敗，查看 View FlexNet Debug Log 的錯誤原因' + [Environment]::NewLine +
                      '  （使用硬體鎖時，拔除 dongle 會造成此現象，插回後須重啟 License Manager）')
            continue
        }

        switch ($st.WinSock) {
            '11001' {
                Add-Finding -FixAction 'add-hosts-entry' -FixParams @{ hostname = $st.Host; ip = '' } -Level 'CONFIRMED' -Title ('主機名稱解析失敗：' + (Protect-Text $st.Host)) `
                    -Detail ('用戶端找不到 ' + (Protect-Text $st.Host) + ' 這台機器（WinSock 11001 Host not found）。' + [Environment]::NewLine +
                             '這是名稱解析問題，不是防火牆問題。') `
                    -Fix ('三選一：' + [Environment]::NewLine +
                          '  1. 請貴司 IT 在 DNS 建立正確的 A 記錄（建議做法）' + [Environment]::NewLine +
                          '  2. 暫時在 C:\Windows\System32\drivers\etc\hosts 加入：' + [Environment]::NewLine +
                          '       <授權伺服器IP>    ' + $st.Host + [Environment]::NewLine +
                          '  3. 確認伺服器主機名稱是否已變更；若是，請改用新名稱設定')
            }
            '10061' {
                Add-Finding -FixAction 'restart-license-manager' -FixOn 'licenseServer' -Level 'CONFIRMED' -Title ('連接埠 ' + $st.Port + ' 沒有服務在監聽：' + (Protect-Text $st.Host)) `
                    -Detail ('主機找得到也連得上，但 ' + $st.Port + ' 埠拒絕連線（WinSock 10061 Connection refused）。' + [Environment]::NewLine +
                             '代表授權伺服器主機是活的，但 lmgrd 沒有在這個埠上運作。' + [Environment]::NewLine +
                             '注意：這不是防火牆——防火牆通常是丟棄封包造成逾時，而不是明確拒絕。') `
                    -Fix ('請在授權伺服器 ' + $st.Host + ' 上：' + [Environment]::NewLine +
                          '  1. 確認 License Manager 已啟動' + [Environment]::NewLine +
                          '  2. 檢查該埠實際由誰占用：' + [Environment]::NewLine +
                          '       netstat -ano | findstr ' + $st.Port + [Environment]::NewLine +
                          '       tasklist | findstr <上一步的PID>' + [Environment]::NewLine +
                          '  3. 若占用者不是 lmgrd.exe，代表埠被其他軟體搶走' + [Environment]::NewLine +
                          '  4. 也請確認伺服器的 SERVER 行埠號與此處設定的 ' + $st.Port + ' 一致')
            }
            'TIMEOUT' {
                Add-Finding -FixAction 'add-firewall-rules' -FixOn 'licenseServer' -Level 'SUSPECT' -Title ('連線逾時：' + $tag) `
                    -Detail ('60 秒內沒有任何回應。封包被丟棄（而非拒絕）通常代表防火牆阻擋，' +
                             '但也可能是網路路由問題或伺服器負載過高。' + [Environment]::NewLine +
                             '本工具無法區分這幾種情況，因此不下定論。') `
                    -Fix ('請依序確認：' + [Environment]::NewLine +
                          '  1. 授權伺服器的防火牆是否放行 TCP ' + $st.Port + [Environment]::NewLine +
                          '  2. 授權伺服器的防火牆是否已將 lmgrd.exe 與 ansyslmd.exe 設為例外' + [Environment]::NewLine +
                          '  3. 兩台機器之間是否有網段間的防火牆或 VPN' + [Environment]::NewLine +
                          '  4. 網路品質不佳時可設定系統環境變數 FLEXLM_TIMEOUT = 1500000')
            }
            default {
                $ws = $st.WinSock
                if ($ws -eq '10060') {
                    Add-Finding -FixAction 'add-firewall-rules' -FixOn 'licenseServer' -Level 'SUSPECT' -Title ('連線逾時（WinSock 10060）：' + $tag) `
                        -Detail '封包送出後沒有回應，通常是防火牆丟棄封包。也可能是網路不通。' `
                        -Fix ('請確認授權伺服器防火牆已放行 TCP ' + $st.Port + '，並將 lmgrd.exe、ansyslmd.exe 設為例外。')
                } elseif ($ws -eq '10051' -or $ws -eq '10065' -or $ws -eq '10032') {
                    Add-Finding -Level 'CONFIRMED' -Title ('網路不可達：' + $tag) `
                        -Detail ('作業系統回報無法路由到目的地（WinSock ' + $ws + '）。' + [Environment]::NewLine +
                                 '這是網路層問題，與 Ansys 設定無關。') `
                        -Fix ('請貴司 IT 確認本機到 ' + (Protect-Text $st.Host) + ' 的網路連通性（路由、VLAN、VPN）。')
                } else {
                    Add-Finding -Level 'SUSPECT' -Title ('無法連上授權伺服器：' + $tag) `
                        -Detail ('FlexNet 錯誤 ' + $st.FlexErr + '，WinSock ' + $ws + '。' + [Environment]::NewLine +
                                 '本工具無法從這個組合唯一判定根因。') `
                        -Fix ('請回傳本報告至 ' + $VENDOR_MAIL)
                }
            }
        }
    }
}

# ============================================================================
#  階段 3：授權可用性
# ============================================================================
Write-Head '階段 3　授權可用性'
$sec3 = Add-Section '授權可用性'

$featureTable = @{}

if (-not $connOk) {
    Add-Row $sec3 '因為沒有任何授權伺服器連線成功，略過本階段。'
    Write-Step '略過（沒有可用的伺服器連線）'
} elseif (-not $lmutil) {
    Add-Row $sec3 '找不到 lmutil.exe，略過。'
} else {
    $upServer = $null
    foreach ($st in $serverStates) {
        if ($st.LmgrdUp -and $st.DaemonUp) { $upServer = $st; break }
    }

    Write-Step '取得 feature 清單'
    $outA = Invoke-Exe -Path $lmutil -Arguments @('lmstat', '-c', $upServer.Server, '-a') -TimeoutSec 120
    if ($outA -and $outA -ne '__TIMEOUT__') {
        $total = 0; $exhausted = New-Object System.Collections.Generic.List[string]
        foreach ($line in ($outA -split "`r?`n")) {
            if ($line -match 'Users of ([^:]+):\s*\(Total of (\d+) licenses? issued;\s*Total of (\d+) licenses? in use\)') {
                $fn = $Matches[1].Trim(); $iss = [int]$Matches[2]; $inuse = [int]$Matches[3]
                $featureTable[$fn] = @{ Issued = $iss; InUse = $inuse }
                $total++
                if ($iss -gt 0 -and $inuse -ge $iss) { $exhausted.Add($fn) | Out-Null }
            }
        }
        Add-Row $sec3 ('伺服器 ' + (Protect-Text $upServer.Server) + ' 共有 ' + $total + ' 個 feature')
        Add-Row $sec3 ''
        if ($exhausted.Count -gt 0) {
            Add-Row $sec3 '【目前已用完的 feature】'
            foreach ($fn in $exhausted) {
                $f = $featureTable[$fn]
                Add-Row $sec3 ('  ' + $fn.PadRight(34) + $f.InUse + ' / ' + $f.Issued)
            }
            Add-Finding -Level 'SUSPECT' -Title ('有 ' + $exhausted.Count + ' 個 feature 目前已全部用完') `
                -Detail ('已用完：' + (($exhausted | Select-Object -First 12) -join ', ') +
                         $(if ($exhausted.Count -gt 12) { ' ...' } else { '' }) + [Environment]::NewLine +
                         '對應 FlexNet 錯誤 -4。但這是執行當下的瞬間狀態，稍後可能就有人釋出。' + [Environment]::NewLine +
                         '若使用者的錯誤訊息不是「授權已用完」，這可能不是根因。') `
                -Fix ('在授權伺服器上開啟 Ansys License Management Center -> Reporting' + [Environment]::NewLine +
                      '  View Current License Usage  可查出目前是誰在使用' + [Environment]::NewLine +
                      '  View License Denials        可查出誰被拒絕')
        } else {
            Add-Row $sec3 '目前沒有任何 feature 處於用完狀態。'
        }
    } else {
        Add-Row $sec3 'lmstat -a 查詢失敗或逾時。'
    }

    # --- 產品比對：把「HFSS 打不開」翻成 increment 再逐一比對 ---
    $checkoutList = New-Object System.Collections.Generic.List[string]
    if ($Feature) {
        foreach ($f in $Feature) { if ($f.Trim()) { $checkoutList.Add($f.Trim()) | Out-Null } }
    }

    if ($Product -and $Product.Count -gt 0) {
        Add-Row $sec3 ''
        Add-Row $sec3 '【產品所需 increment 比對】'
        if ($null -eq $script:FeatureMap) {
            Add-Row $sec3 '  找不到 feature_map.json，無法進行產品比對。'
            Add-Finding -Level 'MANUAL' -Title '缺少產品對照表 feature_map.json' `
                -Detail '指定了 -Product 但工具目錄下沒有 feature_map.json，無法把產品名稱翻成 increment。' `
                -Fix '請向技術支援索取完整的工具包（應包含 feature_map.json）。'
        } else {
            $mapDate = $script:FeatureMap.referenceDate
            Add-Row $sec3 ('  對照表版本：' + $mapDate)
            foreach ($prodQuery in $Product) {
                $matches3 = Find-ProductEntry -Query $prodQuery
                Add-Row $sec3 ''
                if ($matches3.Count -eq 0) {
                    Add-Row $sec3 ('  「' + $prodQuery + '」：對照表中找不到')
                    Add-Finding -Level 'MANUAL' -Title ('對照表中找不到產品：' + $prodQuery) `
                        -Detail ('無法把「' + $prodQuery + '」對應到任何 Ansys 產品。' + [Environment]::NewLine +
                                 '可能是名稱拼法不同，或該產品不在對照表版本 ' + $mapDate + ' 的範圍內。') `
                        -Fix ('請改用完整產品名稱（例如 "Ansys HFSS"），或直接用 -Feature 指定 increment 名稱。')
                    continue
                }
                # 逐一比對每個候選，最後用證據挑出客戶實際擁有的那一個。
                # 這裡不能靠名稱猜——同一個產品的新舊名稱內容差很多。
                $cands = @($matches3 | Select-Object -First 6)
                $results = New-Object System.Collections.Generic.List[object]
                $order = 0

                foreach ($pname in $cands) {
                    $entry = $script:FeatureMap.products.PSObject.Properties[$pname].Value
                    $incs  = @($entry.increments)

                    $missing   = New-Object System.Collections.Generic.List[string]
                    $exhausted = New-Object System.Collections.Generic.List[string]
                    $ok        = 0

                    foreach ($inc in $incs) {
                        $n = $inc.name
                        if (-not $featureTable.ContainsKey($n)) {
                            $missing.Add($n) | Out-Null
                        } else {
                            $ft = $featureTable[$n]
                            if ($ft.Issued -gt 0 -and $ft.InUse -ge $ft.Issued) {
                                $exhausted.Add($n) | Out-Null
                            } else {
                                $ok++
                            }
                        }
                    }
                    $results.Add([pscustomobject]@{
                        Name = $pname; Category = $entry.category; Incs = $incs
                        Missing = $missing; Exhausted = $exhausted; Ok = $ok
                        Order = $order
                    }) | Out-Null
                    $order++
                }

                # 客戶實際擁有的產品，缺少的項目一定最少。用這個當判準。
                # 平手時（例如客戶的授權涵蓋所有候選）再用 Order 決定，Order 來自
                # Find-ProductEntry 的精確度排序。Sort-Object 不保證穩定排序，
                # 沒有這個 tie-break 的話同樣的輸入可能挑到不同產品。
                $best = @($results | Sort-Object @{E={$_.Missing.Count}}, @{E={$_.Exhausted.Count}},
                                                 @{E={$_.Order}})[0]

                if ($results.Count -gt 1) {
                    Add-Row $sec3 ('  「' + $prodQuery + '」符合 ' + $results.Count + ' 個產品名稱，逐一比對後判定為：')
                    foreach ($r in $results) {
                        $mark = '   '
                        if ($r.Name -eq $best.Name) { $mark = ' > ' }
                        Add-Row $sec3 ('  ' + $mark + $r.Name.PadRight(42) + '(' + $r.Category +
                                       ') 缺 ' + $r.Missing.Count + ' / 用完 ' + $r.Exhausted.Count +
                                       ' / 可用 ' + $r.Ok)
                    }
                    Add-Row $sec3 ''
                }

                $entry = $script:FeatureMap.products.PSObject.Properties[$best.Name].Value
                $incs  = @($best.Incs)
                Add-Row $sec3 ('  ' + $best.Name + '  （' + $best.Category + '，需要 ' + $incs.Count + ' 個 increment）')
                foreach ($inc in $incs) {
                    $n = $inc.name
                    if (-not $featureTable.ContainsKey($n)) {
                        Add-Row $sec3 ('      ' + $n.PadRight(30) + '授權中沒有')
                    } else {
                        $ft = $featureTable[$n]
                        if ($ft.Issued -gt 0 -and $ft.InUse -ge $ft.Issued) {
                            Add-Row $sec3 ('      ' + $n.PadRight(30) + '已用完 ' + $ft.InUse + '/' + $ft.Issued)
                        } else {
                            Add-Row $sec3 ('      ' + $n.PadRight(30) + '可用 ' + $ft.InUse + '/' + $ft.Issued)
                        }
                    }
                }
                Add-Row $sec3 ('      -> 可用 ' + $best.Ok + '，未購買 ' + $best.Missing.Count +
                               '，已用完 ' + $best.Exhausted.Count)

                $altNote = ''
                if ($results.Count -gt 1) {
                    $others = @($results | Where-Object { $_.Name -ne $best.Name } |
                                ForEach-Object { $_.Name + '（缺 ' + $_.Missing.Count + ' 項）' })
                    $altNote = ([Environment]::NewLine + [Environment]::NewLine +
                                '「' + $prodQuery + '」在對照表中有多個同名產品，已依實際授權內容判定為上述這一個。' +
                                [Environment]::NewLine + '其他候選：' + ($others -join '、'))
                }

                # 任何一項缺少或用完，整個產品就開不起來
                if ($best.Missing.Count -gt 0) {
                    $descLines = @()
                    foreach ($m in ($best.Missing | Select-Object -First 10)) {
                        $info = Get-IncrementInfo -Name $m
                        $dd = ''
                        if ($info -and $info.desc) { $dd = '  ' + $info.desc }
                        $descLines += ('  - ' + $m + $dd)
                    }
                    Add-Finding -Level 'CONFIRMED' -Title ($best.Name + ' 所需的授權項目不完整') `
                        -Detail ($best.Name + ' 需要 ' + $incs.Count + ' 個 increment，其中 ' + $best.Missing.Count +
                                 ' 個不在貴司的授權中：' + [Environment]::NewLine +
                                 ($descLines -join [Environment]::NewLine) +
                                 $(if ($best.Missing.Count -gt 10) { [Environment]::NewLine + '  （其餘 ' + ($best.Missing.Count - 10) + ' 項略）' } else { '' }) +
                                 [Environment]::NewLine + [Environment]::NewLine +
                                 '只要缺少任何一項，該產品就無法啟動。' + $altNote) `
                        -Fix ('請聯絡 ' + $VENDOR_MAIL + ' 確認貴司的授權內容是否包含 ' + $best.Name + '。' + [Environment]::NewLine +
                              '若確定已購買，可能是 License 檔案未更新到最新版本。')
                } elseif ($best.Exhausted.Count -gt 0) {
                    Add-Finding -Level 'CONFIRMED' -Title ($best.Name + ' 目前無法使用：所需授權已被占用') `
                        -Detail ($best.Name + ' 需要的 increment 全部都在授權中，但以下項目目前已全部借出：' + [Environment]::NewLine +
                                 (($best.Exhausted | ForEach-Object {
                                     $ft = $featureTable[$_]
                                     '  - ' + $_ + '  ' + $ft.InUse + '/' + $ft.Issued
                                 }) -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine +
                                 '只要其中一項取不到，該產品就無法啟動。' + $altNote) `
                        -Fix ('請等待其他使用者釋出，或在授權伺服器上用 Ansys License Management Center' + [Environment]::NewLine +
                              '  Reporting -> View Current License Usage  查出目前是誰在使用。' + [Environment]::NewLine +
                              '若經常發生，可考慮加購或用 Options File 保留授權給重要專案。')
                } else {
                    Add-Finding -Level 'OK' -Title ($best.Name + ' 所需的授權項目都可取得') `
                        -Detail ('已比對 ' + $incs.Count + ' 個 increment，全部存在且有空閒。' + $altNote)
                }

                # 挑鑑別度最高的幾項做實際取得測試。
                # 共用型 increment（例如 electronics_desktop 被 72 個產品共用）測了也
                # 分不出是哪個產品的問題，優先測只有這個產品用的那幾個。
                $rankedInc = @($incs | ForEach-Object {
                    $info = Get-IncrementInfo -Name $_.name
                    $sb = 999
                    if ($info) { $sb = [int]$info.sharedBy }
                    [pscustomobject]@{ Name = $_.name; SharedBy = $sb }
                } | Sort-Object SharedBy)
                foreach ($r in ($rankedInc | Select-Object -First 3)) {
                    if ((-not $checkoutList.Contains($r.Name)) -and $featureTable.ContainsKey($r.Name)) {
                        $checkoutList.Add($r.Name) | Out-Null
                    }
                }
            }
        }
    }

    # --- checkout 測試 ---
    Add-Row $sec3 ''
    Add-Row $sec3 '【實際取得授權測試】'
    if ($NoCheckout) {
        Add-Row $sec3 '  已指定 -NoCheckout，略過。'
    } elseif ($checkoutList.Count -eq 0) {
        Add-Row $sec3 '  未指定 -Product 或 -Feature，略過。'
        Add-Row $sec3 '  提示：加上 -Product HFSS 可自動找出該產品所需的授權項目並實際驗證。'
    } else {
        $Feature = @($checkoutList)
        Write-Host ''
        Write-Host '  接下來會短暫取用一張授權來驗證，' -ForegroundColor Yellow
        Write-Host '  驗證完立即歸還，不會影響其他使用者。' -ForegroundColor Yellow
        Write-Host ''
        foreach ($fn in $Feature) {
            $fnT = $fn.Trim()
            if (-not $fnT) { continue }

            # 先確認有空閒，避免搶走最後一張
            if ($featureTable.ContainsKey($fnT)) {
                $f = $featureTable[$fnT]
                if ($f.Issued -gt 0 -and $f.InUse -ge $f.Issued) {
                    Add-Row $sec3 ('  ' + $fnT.PadRight(24) + '跳過測試：目前 ' + $f.InUse + '/' + $f.Issued + ' 已全部用完')
                    Add-Finding -Level 'SUSPECT' -Title ('feature 已用完，未做取得測試：' + $fnT) `
                        -Detail ('目前 ' + $f.InUse + ' / ' + $f.Issued + ' 全數在使用中。' +
                                 '為避免搶走最後一張授權影響其他使用者，本工具略過此項測試。')
                    continue
                }
            }

            Write-Step ('測試取得 ' + $fnT)
            $outD = Invoke-Exe -Path $lmutil -Arguments @('lmdiag', '-c', $upServer.Server, '-n', $fnT) -TimeoutSec 90
            if ($null -eq $outD -or $outD -eq '__TIMEOUT__') {
                Add-Row $sec3 ('  ' + $fnT.PadRight(24) + '測試逾時')
                continue
            }

            $expiry = ''
            if ($outD -match 'expiry:\s*(\S+)') { $expiry = $Matches[1] }
            $canCheckout = ($outD -match 'This license can be checked out')
            $noLicense   = ($outD -match 'No licenses for')

            if ($canCheckout) {
                Add-Row $sec3 ('  ' + $fnT.PadRight(24) + '可以取得' +
                               $(if ($expiry) { '   到期日 ' + $expiry } else { '' }))
                Add-Finding -Level 'OK' -Title ('可以正常取得授權：' + $fnT) `
                    -Detail ('端到端驗證通過。' + $(if ($expiry) { '到期日 ' + $expiry + '。' } else { '' }))
            } elseif ($noLicense) {
                Add-Row $sec3 ('  ' + $fnT.PadRight(24) + '授權檔中沒有這個 feature')
                Add-Finding -Level 'CONFIRMED' -Title ('授權中沒有這個 feature：' + $fnT) `
                    -Detail ('伺服器連線正常，但 License 檔案裡沒有 ' + $fnT + ' 這個項目。' + [Environment]::NewLine +
                             '可能是：貴司未購買此產品、feature 名稱有誤、或 License 檔案未更新。') `
                    -Fix ('請確認 feature 名稱是否正確，或聯絡 ' + $VENDOR_MAIL + ' 確認授權內容。')
            } else {
                $firstErr = ''
                foreach ($line in ($outD -split "`r?`n")) {
                    if ($line -match 'cannot|Cannot|error|Error|denied') { $firstErr = $line.Trim(); break }
                }
                Add-Row $sec3 ('  ' + $fnT.PadRight(24) + '無法取得' + $(if ($firstErr) { '  ' + $firstErr } else { '' }))
                Add-Finding -Level 'CONFIRMED' -Title ('無法取得授權：' + $fnT) `
                    -Detail ('伺服器連線正常，但實際取用失敗。' + [Environment]::NewLine +
                             $(if ($firstErr) { 'lmdiag 回報：' + $firstErr } else { '' })) `
                    -Fix ('請回傳本報告至 ' + $VENDOR_MAIL + '，報告中含完整的 lmdiag 輸出。')
            }

            # 到期日判定
            if ($expiry -and $expiry -ne 'permanent' -and $expiry -notmatch '^1-jan-0') {
                $dt = $null
                try { $dt = [datetime]::ParseExact($expiry, 'd-MMM-yyyy',
                        [Globalization.CultureInfo]::GetCultureInfo('en-US')) } catch { }
                if ($dt) {
                    $days = [int]([math]::Floor(($dt - (Get-Date)).TotalDays))
                    if ($days -lt 0) {
                        Add-Finding -FixAction 'install-license-file' -FixOn 'licenseServer' -Level 'CONFIRMED' -Title ('授權已過期：' + $fnT) `
                            -Detail ('到期日 ' + $expiry + '，已經過期 ' + [math]::Abs($days) + ' 天。') `
                            -Fix ('請聯絡 ' + $VENDOR_MAIL + ' 辦理續約並取得新的 License 檔案。')
                    } elseif ($days -le 30) {
                        Add-Finding -Level 'SUSPECT' -Title ('授權即將到期：' + $fnT) `
                            -Detail ('到期日 ' + $expiry + '，剩下 ' + $days + ' 天。') `
                            -Fix ('請及早聯絡 ' + $VENDOR_MAIL + ' 辦理續約。')
                    }
                }
            }
        }
    }
}

# ============================================================================
#  階段 4：雲端彈性授權（AEC / Elastic Licensing）
# ============================================================================
Write-Head '階段 4　雲端彈性授權（AEC）'
$secAec = Add-Section '雲端彈性授權（AEC）'

$AEC_HOST = 'laas.fnocc.com'

# 找一支 LicensingSettings 來查（每個版次一份，用最新的）
$lsExe = $null
foreach ($c in ($clientUtils | Sort-Object Version -Descending)) {
    $cand = Join-Path (Split-Path -Parent $c.Util) 'LicensingSettings.exe'
    if (Test-Path -LiteralPath $cand) { $lsExe = $cand; break }
}

$aecEnabled  = $false
$aecClsId    = ''
$aecInPlay   = $false   # 這台機器是否真的在用 AEC
$svcPriority = $null

# 線索一：ansyslmd.ini 裡的 ANSYS_ELASTIC_CLS
$iniHasElastic = $false
if ($activeIni -and (Test-Path -LiteralPath $activeIni)) {
    $iniHasElastic = @(Get-Content -LiteralPath $activeIni -ErrorAction SilentlyContinue |
                       Where-Object { $_ -match '^\s*ANSYS_ELASTIC_CLS\s*=' }).Count -gt 0
}
# 線索二：環境變數
$envElastic = Get-EnvAny 'ANSYSLI_ELASTIC'

# 線索三：LicensingSettings 的實際設定
if ($lsExe) {
    $outE = Invoke-Exe -Path $lsExe -Arguments @('web', 'elastic', 'list') -TimeoutSec 45
    if ($outE -and $outE -ne '__TIMEOUT__') {
        if ($outE -match '"enabled"\s*:\s*true')  { $aecEnabled = $true }
        if ($outE -match '"clsId"\s*:\s*"([^"]*)"') { $aecClsId = $Matches[1] }
    }
    $outP = Invoke-Exe -Path $lsExe -Arguments @('preferences', 'service', 'list') -TimeoutSec 45
    if ($outP -and $outP -ne '__TIMEOUT__') { $svcPriority = $outP }
}

$aecInPlay = ($aecEnabled -or $iniHasElastic -or (-not [string]::IsNullOrWhiteSpace($envElastic)))

Add-Row $secAec ('LicensingSettings : ' + $(if ($lsExe) { $lsExe } else { '(找不到)' }))
Add-Row $secAec ('Elastic 已啟用    : ' + $aecEnabled)
Add-Row $secAec ('CLS ID 已設定     : ' + $(if ($aecClsId) { '是' } else { '否' }))
Add-Row $secAec ('ansyslmd.ini 含 ANSYS_ELASTIC_CLS : ' + $iniHasElastic)
Add-Row $secAec ('ANSYSLI_ELASTIC 環境變數          : ' +
                 $(if ($envElastic) { Protect-Text $envElastic } else { '未設定' }))

if ($svcPriority) {
    Add-Row $secAec ''
    Add-Row $secAec '【授權服務優先順序】清單順序即查詢順序'
    foreach ($l in ($svcPriority -split "`r?`n")) {
        if ($l.Trim()) { Add-Row $secAec ('  ' + $l.TrimEnd()) }
    }
}

if (-not $aecInPlay) {
    Add-Row $secAec ''
    Add-Row $secAec '本機未使用雲端彈性授權，略過 AEC 診斷。'
    Write-Step '本機未使用 AEC，略過'

    # 兩邊都沒有 = 根本沒有任何授權來源
    if ($resolvedServers.Count -eq 0) {
        Add-Finding -FixAction 'set-license-server' -Level 'CONFIRMED' -Title '本機沒有設定任何授權來源' `
            -Detail ('既沒有本地授權伺服器設定（ansyslmd.ini 的 SERVER=），' +
                     '也沒有啟用雲端彈性授權（AEC）。' + [Environment]::NewLine +
                     'Ansys 產品沒有任何地方可以取得授權。') `
            -Fix ('請以系統管理員身分開啟 Ansys Licensing Settings（開始 → Ansys 20xx Rx →' + [Environment]::NewLine +
                  'Ansys Licensing Settings 20xx Rx），設定授權伺服器或匯入 AEC 憑證。' + [Environment]::NewLine +
                  '不確定貴司使用哪一種授權方式時，請聯絡 ' + $VENDOR_MAIL + '。')
    }
} else {
    Write-Step '本機使用 AEC，進行雲端授權診斷'

    # --- 443 對外連線 ---
    Add-Row $secAec ''
    Add-Row $secAec '【對外連線測試】AEC 走 HTTPS 443 連到原廠雲端授權服務'
    $aecDns = $false
    $aecTcp = $false
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses($AEC_HOST) |
                 Where-Object { $_.AddressFamily -eq 'InterNetwork' })
        if ($ips.Count -gt 0) { $aecDns = $true }
    } catch { }
    if ($aecDns) {
        try {
            $tc = New-Object System.Net.Sockets.TcpClient
            $iar = $tc.BeginConnect($AEC_HOST, 443, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne(8000, $false) -and $tc.Connected) {
                $aecTcp = $true; $tc.EndConnect($iar)
            }
            $tc.Close()
        } catch { }
    }
    Add-Row $secAec ('  ' + $AEC_HOST + ' 名稱解析 : ' + $(if ($aecDns) { '成功' } else { '失敗' }))
    Add-Row $secAec ('  ' + $AEC_HOST + ':443 連線 : ' + $(if ($aecTcp) { '成功' } else { '失敗' }))

    if (-not $aecTcp) {
        Add-Finding -Level 'CONFIRMED' -Title ('無法連線到雲端授權服務 ' + $AEC_HOST + ':443') `
            -Detail ('AEC 需要透過 HTTPS（443 埠）連到原廠的雲端授權服務。' + [Environment]::NewLine +
                     '目前' + $(if (-not $aecDns) { '名稱解析就失敗了' } else { '名稱解析成功但 443 連不上' }) + '。' +
                     [Environment]::NewLine + '沒有這條連線，AEC 完全無法運作。') `
            -Fix ('請貴司網管放行對 ' + $AEC_HOST + ' 的 443 對外連線。' + [Environment]::NewLine +
                  '若貴司透過 Proxy 上網，需另外在 Ansys Licensing Settings 設定 Proxy。' + [Environment]::NewLine +
                  '手動驗證指令：' + [Environment]::NewLine +
                  '  Test-NetConnection -ComputerName ' + $AEC_HOST + ' -Port 443')
    } else {
        Add-Finding -Level 'OK' -Title '雲端授權服務連線正常' `
            -Detail ($AEC_HOST + ':443 可正常連線。')
    }

    # --- 憑證 ---
    Add-Row $secAec ''
    Add-Row $secAec '【CLS 憑證】'
    if ($aecEnabled -and [string]::IsNullOrWhiteSpace($aecClsId)) {
        Add-Row $secAec '  已啟用 Elastic Licensing，但 CLS ID 是空的'
        Add-Finding -FixAction 'import-cls-credential' -Level 'CONFIRMED' -Title '已啟用雲端彈性授權，但未匯入 CLS 憑證' `
            -Detail ('Elastic Licensing 已開啟，但 CLS ID 未設定，因此無法向原廠取得授權。') `
            -Fix ('請以 ASC 採購代表人的帳號登入 https://licensing.ansys.com，' + [Environment]::NewLine +
                  'Preferences -> Access Credentials -> Export CLS ID and CLS PIN 匯出 .json，' + [Environment]::NewLine +
                  '再用 Ansys Licensing Settings 的 Elastic Licensing 匯入該檔案。')
    } elseif ((-not $aecEnabled) -and ($iniHasElastic -or $envElastic)) {
        Add-Row $secAec '  設定檔中有 AEC 相關設定，但 Elastic Licensing 未啟用'
        Add-Finding -FixAction 'enable-elastic-licensing' -Level 'CONFIRMED' -Title 'AEC 已設定但未啟用' `
            -Detail ('ansyslmd.ini 或環境變數中有 AEC 設定，但 Elastic Licensing 目前是關閉狀態，' +
                     '因此不會去雲端取得授權。') `
            -Fix ('請以系統管理員身分開啟 Ansys Licensing Settings，在 Elastic Licensing 區塊啟用。')
    } else {
        Add-Row $secAec ('  CLS ID 已設定，Elastic Licensing 已啟用')
    }

    # --- 服務優先順序 ---
    if ($svcPriority) {
        $elasticOn = ($svcPriority -match '"name"\s*:\s*"web-elastic"[\s\S]{0,60}?"enable"\s*:\s*true')
        if (-not $elasticOn) {
            Add-Finding -FixAction 'enable-elastic-service' -Level 'CONFIRMED' -Title '雲端彈性授權服務未啟用（web-elastic = false）' `
                -Detail ('授權服務優先順序中，web-elastic 的 enable 是 false，' +
                         '代表即使 CLS 憑證設定正確，產品也不會去雲端取用授權。') `
                -Fix ('用 Ansys Licensing Settings 啟用，或執行：' + [Environment]::NewLine +
                      '  LicensingSettings preferences service list      查看目前順序' + [Environment]::NewLine +
                      '  LicensingSettings preferences service reset     還原預設順序')
        }
    }

    # --- Proxy ---
    if ($lsExe) {
        $outPx = Invoke-Exe -Path $lsExe -Arguments @('web', 'proxy', 'list') -TimeoutSec 45
        if ($outPx -and $outPx -ne '__TIMEOUT__') {
            Add-Row $secAec ''
            Add-Row $secAec '【Proxy 設定】'
            foreach ($l in ($outPx -split "`r?`n")) {
                if (-not $l.Trim()) { continue }
                # password 欄位一律遮蔽，不論有沒有加 -Anonymize。
                # 這份報告是要寄出去的，絕不能把憑證帶出去。
                $safe = [regex]::Replace($l, '("password"\s*:\s*")[^"]*(")', '${1}********${2}')
                Add-Row $secAec ('  ' + (Protect-Text $safe))
            }
            if ($outPx -match '"(windowsEnabled|otherEnabled)"\s*:\s*true') {
                Add-Finding -Level 'INFO' -Title '本機透過 Proxy 連線' `
                    -Detail ('AEC 的連線會經過 Proxy。若 443 測試失敗，Proxy 設定是首要懷疑對象。' +
                             [Environment]::NewLine + '（報告中的 Proxy 密碼欄位已遮蔽）') `
                    -Fix ('可用以下指令測試 Proxy：' + [Environment]::NewLine +
                          '  LicensingSettings web proxy test')
            }
        }
    }

    # --- 無法自動判定的兩件事 ---
    Add-Finding -Level 'MANUAL' -Title 'AEC 有兩件事本工具無法自動確認' `
        -Detail ('1. 點數是否已用完。' + [Environment]::NewLine +
                 '   原廠入口網站的點數顯示會延遲，看到「還有點數」不代表當下真的還有。' + [Environment]::NewLine +
                 '   若軟體端訊息是「點數不足」而非「連線失敗」，請以軟體端為準。' + [Environment]::NewLine +
                 '2. 原廠是否正在系統維護。' + [Environment]::NewLine +
                 '   維護期間所有 AEC 使用者都會同時無法啟動，症狀看起來像自己的設定壞了。') `
        -Fix ('查詢原廠雲端服務狀態（排查 AEC 問題時建議最先確認，只要幾秒鐘）：' + [Environment]::NewLine +
              '  https://cloudforum.ansys.com/category/serviceissues' + [Environment]::NewLine +
              '查詢剩餘點數：' + [Environment]::NewLine +
              '  https://licensing.ansys.com')
}

# ============================================================================
#  階段 5：伺服器端
# ============================================================================
$sec4 = $null
if ($isServer) {
    Write-Head '階段 5　伺服器端'
    $sec4 = Add-Section '伺服器端'

    # 服務
    Add-Row $sec4 '【服務狀態】'
    $svcs = @(Get-Service -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -like '*Ansys*' -or $_.Name -like '*ansys*' })
    if ($svcs.Count -eq 0) {
        Add-Row $sec4 '  找不到 Ansys 相關服務'
    } else {
        foreach ($s in $svcs) {
            Add-Row $sec4 ('  ' + $s.Status.ToString().PadRight(10) + $s.Name)
        }
        $stopped = @($svcs | Where-Object { $_.Status -ne 'Running' -and $_.Name -like '*License Manager*' })
        if ($stopped.Count -gt 0) {
            Add-Finding -FixAction 'restart-license-manager' -Level 'CONFIRMED' -Title 'License Manager 服務未執行' `
                -Detail ('以下服務不在執行狀態：' + (($stopped | ForEach-Object { $_.Name }) -join ', ')) `
                -Fix ('請以系統管理員身分開啟 Ansys License Management Center，' + [Environment]::NewLine +
                      '進入 View Status/Start/Stop License Manager 後點選 START。')
        }
    }

    # 程序
    Add-Row $sec4 ''
    Add-Row $sec4 '【授權程序】'
    $procTargets = @('lmgrd', 'ansyslmd')
    if ($isLegacy) { $procTargets += @('ansysli_server', 'ansysli_monitor') }
    $lmgrdRunning = $false
    foreach ($t in $procTargets) {
        $ps = @(Get-Process -Name $t -ErrorAction SilentlyContinue)
        if ($ps.Count -gt 0) {
            if ($t -eq 'lmgrd') { $lmgrdRunning = $true }
            foreach ($x in $ps) {
                Add-Row $sec4 ('  ' + ($t + '.exe').PadRight(20) + 'PID ' + $x.Id)
            }
        } else {
            Add-Row $sec4 ('  ' + ($t + '.exe').PadRight(20) + '未執行')
        }
    }
    if (-not $lmgrdRunning) {
        Add-Finding -FixAction 'restart-license-manager' -Level 'CONFIRMED' -Title 'lmgrd 沒有在執行' `
            -Detail '本機是授權伺服器，但 lmgrd.exe 沒有運作，因此無法對外提供授權。' `
            -Fix ('請以系統管理員身分開啟 Ansys License Management Center 並啟動 License Manager。' + [Environment]::NewLine +
                  '若啟動失敗，請往下看「連接埠占用」段落。')
    }

    # 連接埠占用
    Add-Row $sec4 ''
    Add-Row $sec4 '【連接埠占用】'
    $portsToCheck = @(1055)
    foreach ($st in $serverStates) {
        if ($st.Port -and ($portsToCheck -notcontains [int]$st.Port)) { $portsToCheck += [int]$st.Port }
    }
    if ($isLegacy) { $portsToCheck += 2325 }
    $portsToCheck = @($portsToCheck | Sort-Object -Unique)

    foreach ($p in $portsToCheck) {
        $conns = @()
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $conns = @(Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
        }
        if ($conns.Count -eq 0) {
            Add-Row $sec4 ('  TCP ' + $p + ' : 沒有程式在監聽')
            if ($p -eq 1055) {
                Add-Finding -FixAction 'restart-license-manager' -Level 'CONFIRMED' -Title '連接埠 1055 沒有任何程式在監聽' `
                    -Detail '授權伺服器上 lmgrd 應該綁定 1055，目前沒有。代表 License Manager 沒有啟動成功。' `
                    -Fix ('請以系統管理員身分啟動 Ansys License Management Center，' + [Environment]::NewLine +
                          '若按下 START 仍失敗，請查看 View FlexNet Debug Log 的錯誤原因。')
            }
            continue
        }
        foreach ($c in $conns) {
            $pname = '(查不到)'
            try { $pname = (Get-Process -Id $c.OwningProcess -ErrorAction Stop).ProcessName } catch { }
            $shown = $pname
            if ($Anonymize -and $pname -notin @('lmgrd', 'ansyslmd', 'ansysli_server', 'ansysli_monitor')) {
                $shown = Protect-Value -Value $pname -Prefix 'proc'
            }
            Add-Row $sec4 ('  TCP ' + $p + ' : ' + $shown + '.exe  (PID ' + $c.OwningProcess + ')')

            if ($p -eq 1055 -and $pname -ne 'lmgrd' -and $pname -ne '(查不到)') {
                Add-Finding -FixAction 'stop-conflicting-service' -FixParams @{ port = 1055; processName = $pname; processId = $c.OwningProcess } -Level 'CONFIRMED' -Title ('連接埠 1055 被其他程式占用：' + $shown + '.exe') `
                    -Detail ('1055 是 Ansys License Manager 的預設埠，目前被 ' + $shown + '.exe (PID ' +
                             $c.OwningProcess + ') 占用，導致 lmgrd 無法啟動。' + [Environment]::NewLine +
                             '1055 並非 Ansys 專用埠，其他使用 FlexNet 的軟體（PTC、部分 EDA/CAD 工具）也可能設定在此埠。' + [Environment]::NewLine +
                             '開機時哪個服務先啟動就先綁到，所以症狀常表現為「開機後突然不能用」。') `
                    -Fix ('短期：停用占用該埠的服務後，重新啟動 Ansys License Manager。' + [Environment]::NewLine + [Environment]::NewLine +
                          '長期（兩套軟體都要用時，建議改埠號避免再衝突）：' + [Environment]::NewLine +
                          '  1. 編輯授權伺服器的 ansyslmd.lic，把 SERVER 行埠號改為未使用的值（例如 1065）' + [Environment]::NewLine +
                          '  2. 所有用戶端的 ansyslmd.ini 同步改為 SERVER=1065@<主機名稱>' + [Environment]::NewLine +
                          '  3. 防火牆例外一併改為新埠號' + [Environment]::NewLine +
                          '  4. 選新埠號前先確認未被占用： netstat -ano | findstr 1065')
            }
        }
    }

    # License 檔案
    Add-Row $sec4 ''
    Add-Row $sec4 '【License 檔案】'
    $licFileDirs = @()
    if ($licDir) {
        $licFileDirs += (Join-Path $licDir 'license_files')
        $licFileDirs += (Join-Path $licDir 'license_files\ansyslmd')
    }
    $foundLic = $false
    foreach ($d in $licFileDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($lf in @(Get-ChildItem -LiteralPath $d -Filter '*.lic' -File -ErrorAction SilentlyContinue)) {
            $foundLic = $true
            Add-Row $sec4 ('  ' + $lf.FullName)
            Add-Row $sec4 ('    最後修改 ' + $lf.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))

            $content = @(Get-Content -LiteralPath $lf.FullName -ErrorAction SilentlyContinue)
            # 只取標頭行；務必排除 VENDOR_STRING（那是 INCREMENT 續行，含 customer number）
            $hdr = @($content | Where-Object { $_ -match '^\s*(SERVER\s|VENDOR\s|USE_SERVER\b|options\s*=)' } |
                     ForEach-Object { $_.Trim() } | Select-Object -Unique)
            if ($hdr.Count -eq 0) {
                Add-Row $sec4 '    >> 找不到 SERVER 行'
                Add-Finding -FixAction 'install-license-file' -Level 'CONFIRMED' -Title 'License 檔案缺少 SERVER 行' `
                    -Detail ($lf.FullName + ' 中找不到 SERVER 行。對應 FlexNet 錯誤 -13。' + [Environment]::NewLine +
                             '常見原因是檔案經過郵件轉寄、網頁複製貼上、或以 UTF-8 存檔而損壞。') `
                    -Fix ('請勿手動編輯 License 檔案。請聯絡 ' + $VENDOR_MAIL + ' 重新索取原始檔案，' + [Environment]::NewLine +
                          '再用 License Management Center 的 Add a License File 加入。')
            } else {
                foreach ($h in $hdr) { Add-Row $sec4 ('    ' + (Protect-Text $h)) }
            }

            # SERVER 行比對主機名稱與 HostID
            foreach ($h in $hdr) {
                if ($h -match '^\s*SERVER\s+(\S+)\s+(\S+)') {
                    $licHost = $Matches[1]; $licHostId = $Matches[2]
                    if ($licHost -ine $env:COMPUTERNAME -and $licHost -ne 'this_host') {
                        Add-Finding -FixAction 'install-license-file' -Level 'CONFIRMED' -Title 'License 檔案綁定的主機名稱與本機不符' `
                            -Detail ('License 檔案的 SERVER 行寫的是 ' + (Protect-Text $licHost) +
                                     '，但本機名稱是 ' + (Protect-Text $env:COMPUTERNAME) + '。' + [Environment]::NewLine +
                                     'lmgrd 會因此拒絕啟動。') `
                            -Fix ('可能是機器換過名稱，或 License 檔案放到了錯誤的機器上。' + [Environment]::NewLine +
                                  '請聯絡 ' + $VENDOR_MAIL + ' 辦理換機並重新核發 License。')
                    }
                    # HostID 比對
                    if ($lmutil -and $licHostId -match '^[0-9A-Fa-f]{12}$') {
                        $hidOut = Invoke-Exe -Path $lmutil -Arguments @('lmhostid') -TimeoutSec 30
                        if ($hidOut -and $hidOut -ne '__TIMEOUT__') {
                            $ids = @([regex]::Matches($hidOut, '\b[0-9a-fA-F]{12}\b') |
                                     ForEach-Object { $_.Value.ToLower() })
                            Add-Row $sec4 ('    本機 HostID : ' + (($ids | ForEach-Object { Protect-Value -Value $_ -Prefix 'hid' }) -join ', '))
                            if ($ids.Count -gt 0 -and ($ids -notcontains $licHostId.ToLower())) {
                                Add-Finding -FixAction 'install-license-file' -Level 'CONFIRMED' -Title 'License 檔案綁定的 HostID 與本機不符' `
                                    -Detail ('License 綁定的 HostID 不在本機目前的 HostID 清單中。' + [Environment]::NewLine +
                                             '常見原因：更換或停用網卡、更換硬碟、虛擬機遷移造成 MAC 變更。') `
                                    -Fix ('請聯絡 ' + $VENDOR_MAIL + ' 辦理換機（HostID 變更視同換機，一年上限三次）。' + [Environment]::NewLine +
                                          '若原網卡仍在，將其重新啟用即可恢復。')
                            }
                        }
                    }
                }
            }

            $incCount = @($content | Where-Object { $_ -match '^\s*INCREMENT' }).Count
            Add-Row $sec4 ('    INCREMENT 行數 : ' + $incCount + '（內容不輸出）')
        }
        # Options File
        foreach ($of in @(Get-ChildItem -LiteralPath $d -Filter '*.opt' -File -ErrorAction SilentlyContinue)) {
            Add-Row $sec4 ('  [Options File] ' + $of.FullName)
            Add-Finding -Level 'SUSPECT' -Title '伺服器上存在 FlexNet Options File' `
                -Detail ($of.FullName + ' 存在。這個檔案可以用 RESERVE / INCLUDE 規則限制誰能取得哪些授權。' + [Environment]::NewLine +
                         '若使用者回報「取不到授權」但伺服器顯示還有空閒，這裡的規則常常就是原因（對應 FlexNet 錯誤 -39）。') `
                -Fix '請檢查該檔案中的 RESERVE / INCLUDE / HOST_GROUP 規則是否把該使用者或機器排除在外。'
        }
    }
    if (-not $foundLic) {
        Add-Row $sec4 '  找不到 License 檔案'
        Add-Finding -FixAction 'install-license-file' -Level 'CONFIRMED' -Title '授權伺服器上找不到 License 檔案' `
            -Detail ('預期位置：' + ($licFileDirs -join ' 或 ')) `
            -Fix ('請用 License Management Center 的 Add a License File 加入 License 檔案。' + [Environment]::NewLine +
                  '若沒有 License 檔案，請聯絡 ' + $VENDOR_MAIL + '。')
    }

    # 防火牆（唯讀）
    Add-Row $sec4 ''
    Add-Row $sec4 '【防火牆規則】'
    if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
        $fwPort = @()
        try {
            $fwPort = @(Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
                        Where-Object { $_.LocalPort -eq '1055' } |
                        ForEach-Object { $_ | Get-NetFirewallRule -ErrorAction SilentlyContinue } |
                        Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' })
        } catch { }
        if ($fwPort.Count -gt 0) {
            Add-Row $sec4 ('  TCP 1055 有 ' + $fwPort.Count + ' 條啟用中的輸入允許規則')
        } elseif ($connOk) {
            # 連線已經證實可用，就不要再報防火牆——放行可能是以「程式」方式或由群組原則做的。
            # 明明通了還跳警告只會製造雜訊，也違背分級原則。
            Add-Row $sec4 '  找不到針對 TCP 1055 的輸入允許規則，但連線測試已通過，故不列為問題'
            Add-Row $sec4 '  （放行可能是以程式方式設定，或由網域群組原則統一管理）'
        } else {
            Add-Row $sec4 '  找不到針對 TCP 1055 的輸入允許規則'
            Add-Finding -FixAction 'add-firewall-rules' -Level 'SUSPECT' -Title '找不到 TCP 1055 的防火牆輸入允許規則' `
                -Detail ('未找到明確放行 1055 的輸入規則。若用戶端連線逾時，這可能是原因。' + [Environment]::NewLine +
                         '注意：也可能是以「程式」而非「連接埠」的方式放行，或由網域群組原則統一管理，' +
                         '因此本工具不將此列為確定根因。') `
                -Fix ('以系統管理員身分執行 PowerShell：' + [Environment]::NewLine +
                      '  New-NetFirewallRule -DisplayName "Ansys TCP 1055" -Direction Inbound ' +
                      '-Action Allow -Protocol TCP -LocalPort 1055 -Profile Domain,Private,Public' + [Environment]::NewLine +
                      '並將 lmgrd.exe 與 ansyslmd.exe 也加入例外。')
        }
    } else {
        Add-Row $sec4 '  這個系統沒有 Get-NetFirewallRule，略過'
    }
} else {
    Write-Step '本機不是授權伺服器，略過階段 5'
}

# ============================================================================
#  階段 6：基線比對
# ============================================================================
Write-Head '階段 6　基線比對'
$sec5 = Add-Section '基線比對'

# 目前狀態快照
$snapshot = [ordered]@{
    ToolVersion  = $TOOL_VERSION
    CreatedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    ComputerName = $env:COMPUTERNAME
    Role         = $roleTag
    Architecture = $(if ($isLegacy) { 'Interconnect' } else { 'CVD' })
    AnsyslicDir  = $licDir
    Servers      = @($resolvedServers)
    ClientVersions = @($clientUtils | ForEach-Object { $_.Version })
    IniContent   = @()
    LicenseHost  = ''
    LicenseHostId = ''
    CaseId       = $CaseId
}
if ($activeIni -and (Test-Path -LiteralPath $activeIni)) {
    # 一定要 .ToString()。Get-Content 回傳的是帶有 PSPath / PSProvider 等 NoteProperty
    # 的字串物件，直接丟給 ConvertTo-Json 會把整個 provider 物件圖序列化出來——
    # 實測基線檔會從幾 KB 爆成 7.9 MB。
    $snapshot.IniContent = @(Get-Content -LiteralPath $activeIni -ErrorAction SilentlyContinue |
                             Where-Object { $_ -match '\S' } |
                             ForEach-Object { $_.ToString() })
}

if ($SaveBaseline) {
    $blPath = Join-Path $ScriptDir 'expected.json'
    try {
        $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $blPath -Encoding utf8 -Force
        Add-Row $sec5 ('已建立基線檔：' + $blPath)
        Write-Host ''
        Write-Host ('  基線已建立：' + $blPath) -ForegroundColor Green
        Write-Host '  請將此檔案與工具一起保存，日後故障時可自動比對變更。' -ForegroundColor Green
    } catch {
        Add-Row $sec5 ('基線建立失敗：' + $_.Exception.Message)
    }
} else {
    # 找基線檔
    $blPath = $Expected
    if ([string]::IsNullOrWhiteSpace($blPath)) {
        $cand = Join-Path $ScriptDir 'expected.json'
        if (Test-Path -LiteralPath $cand) { $blPath = $cand }
    }
    if ($blPath -and (Test-Path -LiteralPath $blPath)) {
        Add-Row $sec5 ('基線檔：' + $blPath)
        $bl = $null
        try { $bl = Get-Content -LiteralPath $blPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Add-Row $sec5 ('  基線檔解析失敗：' + $_.Exception.Message)
        }
        if ($bl) {
            if ($bl.CreatedAt) { Add-Row $sec5 ('基線建立於：' + $bl.CreatedAt) }
            Add-Row $sec5 ''
            $diffs = New-Object System.Collections.Generic.List[string]

            if ($bl.AnsyslicDir -and ($bl.AnsyslicDir -ne $licDir)) {
                $diffs.Add('ANSYSLIC_DIR：' + $bl.AnsyslicDir + '  ->  ' + $licDir) | Out-Null
            }
            $blSrv = @($bl.Servers)
            $nowSrv = @($resolvedServers)
            $gone  = @($blSrv | Where-Object { $nowSrv -notcontains $_ })
            $added = @($nowSrv | Where-Object { $blSrv -notcontains $_ })
            foreach ($g in $gone)  { $diffs.Add('授權伺服器設定消失：' + $g) | Out-Null }
            foreach ($a in $added) { $diffs.Add('授權伺服器設定新增：' + $a) | Out-Null }

            $blIni  = @($bl.IniContent)
            $nowIni = @($snapshot.IniContent)
            $iniGone  = @($blIni  | Where-Object { $nowIni -notcontains $_ })
            $iniAdded = @($nowIni | Where-Object { $blIni  -notcontains $_ })
            foreach ($g in $iniGone)  { $diffs.Add('ansyslmd.ini 少了：' + $g) | Out-Null }
            foreach ($a in $iniAdded) { $diffs.Add('ansyslmd.ini 多了：' + $a) | Out-Null }

            if ($bl.Architecture -and ($bl.Architecture -ne $snapshot.Architecture)) {
                $diffs.Add('授權架構：' + $bl.Architecture + '  ->  ' + $snapshot.Architecture) | Out-Null
            }

            if ($diffs.Count -eq 0) {
                Add-Row $sec5 '與基線相符，沒有偵測到組態變更。'
                Add-Finding -Level 'INFO' -Title '組態與基線相符' `
                    -Detail '用戶端設定自基線建立以來沒有變動，問題可能不在設定，而在伺服器狀態或網路。'
            } else {
                foreach ($d in $diffs) { Add-Row $sec5 ('  ' + (Protect-Text $d)) }
                Add-Finding -FixAction 'restore-from-baseline' -FixParams @{ baselinePath = $blPath; differences = @($diffs) } -Level 'CONFIRMED' -Title ('組態與基線不符，偵測到 ' + $diffs.Count + ' 項變更') `
                    -Detail ('基線建立於 ' + $bl.CreatedAt + '，之後有以下變更：' + [Environment]::NewLine +
                             (($diffs | ForEach-Object { '  - ' + (Protect-Text $_) }) -join [Environment]::NewLine)) `
                    -Fix '請確認這些變更是否為預期。將設定改回基線狀態通常即可恢復。'
            }
        }
    } else {
        Add-Row $sec5 '沒有基線檔可比對。'
        Add-Row $sec5 '提示：在系統正常時執行 -SaveBaseline 可建立基線，日後故障時能直接指出「什麼變了」。'
        Write-Step '沒有基線檔'
    }
}

# ============================================================================
#  階段 7：判定與輸出
# ============================================================================

# 案件編號
if ([string]::IsNullOrWhiteSpace($CaseId)) {
    $blCand = Join-Path $ScriptDir 'expected.json'
    if (Test-Path -LiteralPath $blCand) {
        try {
            $tmp = Get-Content -LiteralPath $blCand -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($tmp.CaseId) { $CaseId = $tmp.CaseId }
        } catch { }
    }
}
if ([string]::IsNullOrWhiteSpace($CaseId)) {
    $CaseId = $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmm')
}
$script:Facts['案件編號'] = $CaseId

# 若整條路徑都正常但仍有人回報問題
$hasProblem = @($script:Findings | Where-Object { $_.Level -eq 'CONFIRMED' -or $_.Level -eq 'SUSPECT' }).Count -gt 0
if ((-not $hasProblem) -and $connOk) {
    Add-Finding -Level 'MANUAL' -Title '本機檢查未發現異常' `
        -Detail ('授權伺服器連線正常，用戶端設定也沒有明顯問題。' + [Environment]::NewLine +
                 '若使用者仍然無法開啟軟體，可能原因：' + [Environment]::NewLine +
                 '  - 問題發生在另一台機器（請在該機器上執行本工具）' + [Environment]::NewLine +
                 '  - 特定產品的 feature 未購買或已用完（請用 -Feature 指定該產品的 feature 再測一次）' + [Environment]::NewLine +
                 '  - 產品版次與 License Manager 版次不相容' + [Environment]::NewLine +
                 '  - 問題為間歇性，執行當下剛好正常') `
        -Fix ('請回傳本報告至 ' + $VENDOR_MAIL + '，並附上使用者看到的完整錯誤訊息截圖。')
}

$sorted = @($script:Findings | Sort-Object @{ Expression = { $LEVEL_META[$_.Level].Rank } })

# ---------------------------------------------------------------------------
#  console 摘要
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor White
Write-Host '  診斷結果' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor White
Write-Host ''
Write-Host ('  案件編號 : ' + $CaseId)
Write-Host ('  本機角色 : ' + $roleLabel)
Write-Host ''

$counts = @{}
foreach ($k in $LEVEL_META.Keys) { $counts[$k] = 0 }
foreach ($f in $sorted) { $counts[$f.Level] = $counts[$f.Level] + 1 }

foreach ($lvl in @('CONFIRMED', 'SUSPECT', 'MANUAL')) {
    $items = @($sorted | Where-Object { $_.Level -eq $lvl })
    if ($items.Count -eq 0) { continue }
    $color = 'Red'
    if ($lvl -eq 'SUSPECT') { $color = 'Yellow' }
    if ($lvl -eq 'MANUAL')  { $color = 'Magenta' }
    Write-Host ('  [' + $LEVEL_META[$lvl].Label + ']') -ForegroundColor $color
    foreach ($f in $items) {
        Write-Host ('    * ' + $f.Title) -ForegroundColor $color
    }
    Write-Host ''
}

if ($counts['CONFIRMED'] -eq 0 -and $counts['SUSPECT'] -eq 0 -and $counts['MANUAL'] -eq 0) {
    Write-Host '  未發現問題。' -ForegroundColor Green
    Write-Host ''
}

# ---------------------------------------------------------------------------
#  報告輸出
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $ScriptDir 'reports' }
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeCase = ($CaseId -replace '[^\w\-\.]', '_')
$baseName = 'AnsysLicense_' + $safeCase + '_' + $roleTag + '_' + $stamp
$txtPath  = Join-Path $OutDir ($baseName + '.txt')
$htmlPath = Join-Path $OutDir ($baseName + '.html')

# --- 純文字報告 ---
$tb = New-Object System.Text.StringBuilder
function TB { param([string] $s = '') $tb.AppendLine($s) | Out-Null }

TB ('=' * 72)
TB ('  ' + $TOOL_NAME + '  診斷報告')
TB ('  ' + $VENDOR_NAME + '  ' + $VENDOR_EN)
TB ('  技術支援：' + $VENDOR_MAIL)
TB ('=' * 72)
TB ''
TB '【這份報告包含哪些資訊】'
TB '  本報告是為了診斷 Ansys 授權連線問題而產生，內容包含：'
TB '    - 本機電腦名稱、作業系統版本'
TB '    - Ansys 安裝路徑與已安裝版次'
TB '    - 授權伺服器的主機名稱與連接埠設定'
TB '    - 授權服務的運作狀態與 feature 使用數量'
TB '    - License 檔案的 SERVER 行（不含授權碼與 INCREMENT 內容）'
if ($isServer) {
    TB '    - 占用授權連接埠的程式名稱'
}
if ($Anonymize) {
    TB ''
    TB '  已啟用去識別化：使用者帳號、內網 IP、第三方程式名稱已雜湊處理。'
} else {
    TB ''
    TB '  提示：若貴司資安規範不允許外傳上述資訊，可加上 -Anonymize 參數重新執行。'
}
TB ''
TB ('回傳方式：請將本檔案以電子郵件寄至 ' + $VENDOR_MAIL + '，並註明案件編號。')
TB ''
TB ('=' * 72)
TB ''
foreach ($k in $script:Facts.Keys) {
    TB ('  ' + $k.PadRight(16) + ': ' + $script:Facts[$k])
}
TB ''
TB ('=' * 72)
TB '  診斷結果'
TB ('=' * 72)
if ($sorted.Count -eq 0) {
    TB ''
    TB '  未發現任何項目。'
}
foreach ($lvl in @('CONFIRMED', 'SUSPECT', 'MANUAL', 'OK', 'INFO')) {
    $items = @($sorted | Where-Object { $_.Level -eq $lvl })
    if ($items.Count -eq 0) { continue }
    TB ''
    TB ('--- 【' + $LEVEL_META[$lvl].Label + '】 ' + $items.Count + ' 項 ---')
    foreach ($f in $items) {
        TB ''
        TB ('  * ' + $f.Title)
        if ($f.Detail) {
            foreach ($line in ($f.Detail -split "`r?`n")) { TB ('      ' + $line) }
        }
        if ($f.Fix) {
            TB ''
            TB '      建議處理方式：'
            foreach ($line in ($f.Fix -split "`r?`n")) { TB ('      ' + $line) }
        }
    }
}
TB ''
TB ('=' * 72)
TB '  收集到的資料'
TB ('=' * 72)
foreach ($s in $script:Sections) {
    TB ''
    TB ('--- ' + $s.Name + ' ---')
    foreach ($l in $s.Lines) { TB ('  ' + $l) }
}
TB ''
TB ('報告產生時間 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '　工具版本 ' + $TOOL_VERSION)
TB ('本工具全程唯讀，未修改本機任何設定。')

try {
    $tb.ToString() | Out-File -FilePath $txtPath -Encoding utf8 -Force
} catch {
    Write-Host ('  文字報告寫入失敗：' + $_.Exception.Message) -ForegroundColor Red
}

# --- HTML 報告 ---
function HtmlEnc {
    param([string] $s)
    if ($null -eq $s) { return '' }
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

$hb = New-Object System.Text.StringBuilder
function HB { param([string] $s = '') $hb.AppendLine($s) | Out-Null }

HB '<!DOCTYPE html>'
HB '<html lang="zh-Hant"><head><meta charset="UTF-8">'
HB '<meta name="viewport" content="width=device-width, initial-scale=1">'
HB ('<title>Ansys License 診斷報告 ' + (HtmlEnc $CaseId) + '</title>')
HB '<style>'
HB 'body{font-family:"Calibri","Microsoft JhengHei",sans-serif;margin:0;background:#f4f5f7;color:#1b1f27;}'
HB '.wrap{max-width:1000px;margin:0 auto;padding:24px;}'
HB 'header{background:#1b2a41;color:#fff;padding:22px 28px;border-radius:10px;}'
HB 'header h1{margin:0 0 4px;font-size:20px;}'
HB 'header .sub{opacity:.85;font-size:13px;line-height:1.7;}'
HB '.card{background:#fff;border:1px solid #dfe2e8;border-radius:10px;padding:18px 22px;margin-top:18px;}'
HB '.card h2{margin:0 0 12px;font-size:16px;border-bottom:2px solid #eceef2;padding-bottom:8px;}'
HB 'table.facts{border-collapse:collapse;width:100%;font-size:14px;}'
HB 'table.facts td{padding:5px 8px;border-bottom:1px solid #f0f1f4;}'
HB 'table.facts td.k{color:#5a6270;width:150px;}'
HB '.f{border-left:5px solid #ccc;background:#fafbfc;border-radius:0 8px 8px 0;padding:12px 16px;margin-bottom:12px;}'
HB '.f .t{font-weight:600;font-size:15px;margin-bottom:6px;}'
HB '.f .d{font-size:13.5px;line-height:1.75;white-space:pre-wrap;color:#333;}'
HB '.f .fx{margin-top:10px;padding:10px 12px;background:#eef4ff;border-radius:6px;'
HB '        font-size:13px;line-height:1.7;white-space:pre-wrap;font-family:Consolas,monospace;}'
HB '.f .fx b{font-family:"Microsoft JhengHei",sans-serif;display:block;margin-bottom:4px;}'
HB '.badge{display:inline-block;font-size:12px;padding:2px 10px;border-radius:10px;color:#fff;margin-right:8px;}'
HB 'pre{background:#1e2430;color:#dfe3ec;padding:14px 16px;border-radius:8px;overflow-x:auto;'
HB '     font-size:12.5px;line-height:1.6;font-family:Consolas,monospace;}'
HB '.notice{background:#fff8e5;border:1px solid #f0d9a0;border-radius:8px;padding:14px 18px;'
HB '        font-size:13.5px;line-height:1.8;}'
HB 'footer{text-align:center;color:#7a8190;font-size:12px;padding:22px 0;}'
HB '</style></head><body><div class="wrap">'

HB '<header>'
HB ('<h1>Ansys License 連線診斷報告</h1>')
HB ('<div class="sub">' + (HtmlEnc $VENDOR_NAME) + '　' + (HtmlEnc $VENDOR_EN) + '<br>')
HB ('技術支援：<a href="mailto:' + $VENDOR_MAIL + '" style="color:#9ec5ff;">' + $VENDOR_MAIL + '</a>　｜　案件編號：' + (HtmlEnc $CaseId) + '</div>')
HB '</header>'

HB '<div class="card"><h2>這份報告包含哪些資訊</h2><div class="notice">'
HB '本報告是為了診斷 Ansys 授權連線問題而產生，內容包含：本機電腦名稱與作業系統版本、'
HB 'Ansys 安裝路徑與已安裝版次、授權伺服器的主機名稱與連接埠設定、授權服務的運作狀態與 '
HB 'feature 使用數量、License 檔案的 SERVER 行（<b>不含授權碼與 INCREMENT 內容</b>）'
if ($isServer) { HB '、占用授權連接埠的程式名稱' }
HB '。<br>'
if ($Anonymize) {
    HB '<b>已啟用去識別化</b>：使用者帳號、內網 IP、第三方程式名稱均已雜湊處理。<br>'
} else {
    HB '若貴司資安規範不允許外傳上述資訊，可加上 <code>-Anonymize</code> 參數重新執行。<br>'
}
HB ('回傳方式：請將本檔案寄至 <a href="mailto:' + $VENDOR_MAIL + '">' + $VENDOR_MAIL + '</a>，並註明案件編號。')
HB '</div></div>'

HB '<div class="card"><h2>基本資訊</h2><table class="facts">'
foreach ($k in $script:Facts.Keys) {
    HB ('<tr><td class="k">' + (HtmlEnc $k) + '</td><td>' + (HtmlEnc ([string]$script:Facts[$k])) + '</td></tr>')
}
HB '</table></div>'

HB '<div class="card"><h2>診斷結果</h2>'
if ($sorted.Count -eq 0) { HB '<p>未發現任何項目。</p>' }
foreach ($lvl in @('CONFIRMED', 'SUSPECT', 'MANUAL', 'OK', 'INFO')) {
    $items = @($sorted | Where-Object { $_.Level -eq $lvl })
    if ($items.Count -eq 0) { continue }
    $meta = $LEVEL_META[$lvl]
    foreach ($f in $items) {
        HB ('<div class="f" style="border-left-color:' + $meta.Color + ';">')
        HB ('<div class="t"><span class="badge" style="background:' + $meta.Color + ';">' +
            (HtmlEnc $meta.Label) + '</span>' + (HtmlEnc $f.Title) + '</div>')
        if ($f.Detail) { HB ('<div class="d">' + (HtmlEnc $f.Detail) + '</div>') }
        if ($f.Fix) {
            HB ('<div class="fx"><b>建議處理方式</b>' + (HtmlEnc $f.Fix) + '</div>')
        }
        HB '</div>'
    }
}
HB '</div>'

HB '<div class="card"><h2>收集到的資料</h2>'
foreach ($s in $script:Sections) {
    HB ('<h3 style="font-size:14px;margin:16px 0 8px;">' + (HtmlEnc $s.Name) + '</h3>')
    HB '<pre>'
    foreach ($l in $s.Lines) { HB (HtmlEnc $l) }
    HB '</pre>'
}
HB '</div>'

HB ('<footer>報告產生時間 ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') +
    '　｜　工具版本 ' + $TOOL_VERSION + '　｜　本工具全程唯讀，未修改本機任何設定</footer>')
HB '</div></body></html>'

try {
    $hb.ToString() | Out-File -FilePath $htmlPath -Encoding utf8 -Force
} catch {
    Write-Host ('  HTML 報告寫入失敗：' + $_.Exception.Message) -ForegroundColor Red
}

# --- findings JSON（供解決包產生器使用）---
$jsonPath = $null
if ($Json) {
    $jsonPath = Join-Path $OutDir ($baseName + '.findings.json')

    $jsonFindings = @()
    foreach ($f in $sorted) {
        $params = $null
        if ($f.FixParams) {
            # hashtable 直接丟給 ConvertTo-Json 在 PS 5.1 會變成一堆 Keys/Values，
            # 先轉成 PSCustomObject 才會序列化成正常的物件。
            $params = [pscustomobject]$f.FixParams
        }
        $jsonFindings += [pscustomobject]@{
            level     = $f.Level
            title     = $f.Title
            detail    = $f.Detail
            fixText   = $f.Fix
            fixAction = $(if ($f.FixAction) { $f.FixAction } else { $null })
            fixTier   = $(if ($f.FixTier -gt 0) { $f.FixTier } else { $null })
            fixOn     = $(if ($f.FixAction) { $f.FixOn } else { $null })
            fixParams = $params
        }
    }

    $factsObj = [ordered]@{}
    foreach ($k in $script:Facts.Keys) { $factsObj[$k] = [string]$script:Facts[$k] }

    $payload = [ordered]@{
        schemaVersion = 1
        tool          = [ordered]@{ name = $TOOL_NAME; version = $TOOL_VERSION }
        caseId        = $CaseId
        generatedAt   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        anonymized    = [bool]$Anonymize
        machine       = [ordered]@{
            computerName = $env:COMPUTERNAME
            role         = $roleTag
            architecture = $(if ($isLegacy) { 'Interconnect' } else { 'CVD' })
            ansyslicDir  = $licDir
            isAdmin      = $isAdmin
            servers      = @($resolvedServers)
        }
        facts         = $factsObj
        findings      = $jsonFindings
        # 解決包產生器的硬性規則：只有 CONFIRMED 才允許生成修復動作。
        # 這裡先算好，讓產生器不必自己重新推導。
        actionable    = @($jsonFindings | Where-Object {
                            $_.level -eq 'CONFIRMED' -and $_.fixAction -and $_.fixTier -lt 3
                          } | ForEach-Object { $_.fixAction } | Select-Object -Unique)
        notAutomatable= @($jsonFindings | Where-Object { $_.fixTier -eq 3 } |
                          ForEach-Object { $_.fixAction } | Select-Object -Unique)
    }

    try {
        $payload | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8 -Force
    } catch {
        Write-Host ('  JSON 輸出失敗：' + $_.Exception.Message) -ForegroundColor Red
        $jsonPath = $null
    }
}

Write-Host ('=' * 60) -ForegroundColor White
Write-Host '  報告已產生' -ForegroundColor Green
Write-Host ''
Write-Host ('    ' + $htmlPath)
Write-Host ('    ' + $txtPath)
if ($jsonPath) { Write-Host ('    ' + $jsonPath) }
Write-Host ''
Write-Host ('  請將其中一份寄至 ' + $VENDOR_MAIL) -ForegroundColor Cyan
Write-Host ('  並註明案件編號 ' + $CaseId) -ForegroundColor Cyan
Write-Host ''
Write-Host '  本工具全程唯讀，未修改本機任何設定。' -ForegroundColor Green
Write-Host ''
