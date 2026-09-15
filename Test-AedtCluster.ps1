#Requires -Version 5.1
<#
.SYNOPSIS
    AEDT 多工作站串機檢查工具 —— 虎門科技股份有限公司

.DESCRIPTION
    要把兩台以上的工作站串起來一起算 AEDT（HFSS / Maxwell / Q3D / Icepak）時，
    先在每一台上各跑一次這支工具收集狀態，再彙整比對，找出串不起來的原因。

    本工具全程唯讀，不會修改貴司任何設定。偵測到問題時只把該做的事列出來。

    用法分兩步：

      步驟一（每一台各跑一次）
        .\Test-AedtCluster.ps1 -CaseId ACME-001 -Peers WS02,WS03

      步驟二（把所有 .node.json 收到同一個資料夾後跑一次）
        .\Test-AedtCluster.ps1 -Merge .\reports

    真正的價值在步驟二。版本不一致、安裝路徑不一致、temp 路徑不一致、
    網段不同——這些單機自己看永遠看不出來。

    結論沿用診斷工具的三級制：
      【確定】證據可唯一解釋現象
      【可疑】有異常但無法斷言為根因
      【需人工】資料不足或環境未經驗證，請回傳報告

.PARAMETER CaseId
    案件編號。同一組機器的所有節點報告要用同一個編號才對得起來。
    未指定時取電腦名稱加時間戳，但這樣彙整時無法確認是否為同一案件。

.PARAMETER Peers
    其他要參與串機的機器名稱或 IP，可多個。例：-Peers WS02,WS03
    指定後會從本機測試名稱解析、TCP 連通性與網段是否相同。
    不指定時只做本機檢查。

.PARAMETER Mode
    要做哪一種串機，決定各項檢查的嚴重度：
      DSO —— 只是把參數表的列分散到多台各算各的。純 DSO 分列時不走 MPI，門檻較低。
      DDM —— 單一模型的網格切開分散到多台記憶體。走 MPI，網路品質直接決定成敗。
      Unknown（預設）—— 不知道時兩種都用較嚴格的標準檢查。

.PARAMETER RsmPort
    AnsoftRSMService 的連接埠，預設 32958。
    只有在 Tools > Options > General Options > Remote Analysis 改過才需要指定。

.PARAMETER HpcPacks
    手上的 HPC Pack 數量。指定後會算給你看「集中在一台」與「攤到多台」
    各能開到幾核——HPC Pack 是倍增不是線性，攤開常常反而變少。
    搭配 -Peers 使用時會自動用機器台數計算。

.PARAMETER Merge
    彙整模式。給一個資料夾或多個 .node.json 檔案路徑，做跨機比對並產出彙整報告。
    這個模式不收集本機資料。

.PARAMETER Anonymize
    去識別化。把使用者帳號、內網 IP、電腦名稱雜湊處理後才寫進報告。

.PARAMETER Json
    另外輸出機器可讀的 findings JSON。節點模式一律會輸出 .node.json（彙整要用），
    這個參數是額外再輸出一份 findings 格式。

.PARAMETER OutDir
    報告輸出目錄，預設為腳本所在目錄下的 reports\。

.EXAMPLE
    .\Test-AedtCluster.ps1 -CaseId ACME-001 -Peers WS02,WS03 -Mode DDM
    在 WS01 上收集，並測試對 WS02、WS03 的連通性。

.EXAMPLE
    .\Test-AedtCluster.ps1 -Merge .\reports
    彙整同一個資料夾內所有節點報告，做跨機比對。

.EXAMPLE
    .\Test-AedtCluster.ps1 -HpcPacks 4 -Peers WS02,WS03,WS04
    順便算 4 個 HPC Pack 集中與分散的核心數差異。

.NOTES
    虎門科技股份有限公司 Taiwan Auto-Design Co.
    技術支援：cae-support@cadmen.com

    本工具唯讀。

    偵測邏輯依據 Ansys 公開文件撰寫，尚未在各版本實機全面驗證。
    設計與依據見 docs\AEDT串機工具設計.md。
    找不到某項設定時一律回報【需人工】，不會反過來斷定「沒有設」——
    串機設錯的代價是算到一半掉，講錯比不講更貴。
#>
[CmdletBinding()]
param(
    [string]   $CaseId,
    [string[]] $Peers,
    [ValidateSet('DSO', 'DDM', 'Unknown')]
    [string]   $Mode = 'Unknown',
    [int]      $RsmPort = 32958,
    [int]      $HpcPacks = 0,
    [string[]] $Merge,
    [switch]   $Anonymize,
    [switch]   $Json,
    [string]   $OutDir
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$TOOL_NAME    = 'AEDT 串機檢查工具'
$TOOL_VERSION = '0.1.0'
$VENDOR_NAME  = '虎門科技股份有限公司'
$VENDOR_EN    = 'Taiwan Auto-Design Co.'
$VENDOR_MAIL  = 'cae-support@cadmen.com'
$NODE_SCHEMA  = 1

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================================
#  資料模型
# ============================================================================
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Sections = New-Object System.Collections.Generic.List[object]
$script:Facts    = [ordered]@{}

$LEVEL_META = [ordered]@{
    'CONFIRMED' = @{ Label = '確定'   ; Rank = 0; Color = '#d13438' }
    'SUSPECT'   = @{ Label = '可疑'   ; Rank = 1; Color = '#c07800' }
    'MANUAL'    = @{ Label = '需人工' ; Rank = 2; Color = '#6b5bd6' }
    'OK'        = @{ Label = '正常'   ; Rank = 3; Color = '#107c10' }
    'INFO'      = @{ Label = '參考'   ; Rank = 4; Color = '#5a6270' }
}

# ----------------------------------------------------------------------------
#  佈署動作目錄
#
#  本工具不執行任何動作，只把結果標記成某一類。實際執行的工具在私有 repo。
#  Tier 依「出錯時的影響半徑」分級，與診斷工具同一套規則：
#    1 只影響 Ansys、只影響本機、可逆
#    2 動到機器層級設定，需逐項明確授權
#    3 會波及其他軟體或需跨機器協調，永不自動化
# ----------------------------------------------------------------------------
$ACTION_CATALOG = [ordered]@{
    'register-rsm'             = @{ Tier = 1; Label = '向 RSM 註冊 AEDT' }
    'start-rsm-service'        = @{ Tier = 1; Label = '啟動 AnsoftRSMService' }
    'start-hydra-service'      = @{ Tier = 1; Label = '啟動 Intel MPI hydra_service' }
    'set-temp-directory'       = @{ Tier = 1; Label = '設定 default.cfg 的 tempdirectory' }
    'set-mpi-vendor'           = @{ Tier = 1; Label = '指定 MPI 廠商' }
    'install-hydra-service'    = @{ Tier = 2; Label = '安裝 Intel MPI hydra_service' }
    'install-intel-mpi'        = @{ Tier = 2; Label = '安裝 AEDT 支援的 Intel MPI' }
    'install-msmpi'            = @{ Tier = 2; Label = '安裝 Microsoft MPI' }
    'register-mpi-credential'  = @{ Tier = 2; Label = '註冊 MPI 帳號密碼（需人工輸入）' }
    'add-cluster-firewall'     = @{ Tier = 2; Label = '新增串機所需的防火牆例外' }
    'align-aedt-version'       = @{ Tier = 3; Label = '統一各機器的 AEDT 版本或安裝路徑' }
    'align-os-version'         = @{ Tier = 3; Label = '統一各機器的 Windows 版本或更新層級' }
    'align-user-account'       = @{ Tier = 3; Label = '統一各機器的使用者帳號密碼' }
    'fix-network-topology'     = @{ Tier = 3; Label = '調整網路架構（多網卡／跨網段／VPN）' }
}

function Add-Finding {
    param(
        [ValidateSet('CONFIRMED', 'SUSPECT', 'MANUAL', 'OK', 'INFO')]
        [string] $Level,
        [string] $Title,
        [string] $Detail = '',
        [string] $Fix = '',
        [string] $Ref = '',
        [string] $FixAction = '',
        [hashtable] $FixParams = $null,
        # 動作要在哪一台執行。跨機比對出來的問題常常不是在彙整這台身上，
        # 沒有這個欄位的話會把事情派到錯的機器。
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
$script:AnonymizationKey = $null
$script:SensitiveHosts = @($Peers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                              ForEach-Object { [string]$_ } | Sort-Object -Unique)
$script:SensitiveUsers = @()
$script:SensitiveDomains = @()

function Protect-Value {
    param([string] $Value, [string] $Prefix = 'X')
    if (-not $Anonymize)                      { return $Value }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Value }
    if ($null -eq $script:AnonymizationKey) {
        $script:AnonymizationKey = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($script:AnonymizationKey) } finally { $rng.Dispose() }
    }
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = $script:AnonymizationKey
        $bytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))
    } finally {
        $hmac.Dispose()
    }
    $hex = ''
    foreach ($b in $bytes[0..7]) { $hex += $b.ToString('x2') }
    return ($Prefix + '-' + $hex)
}

function Protect-Text {
    param([string] $Text)
    if (-not $Anonymize) { return $Text }
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = [regex]::Replace($Text,
        '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b',
        { param($m) Protect-Value -Value $m.Value -Prefix 'ip' })
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $t = $t -replace [regex]::Escape($env:USERNAME), (Protect-Value -Value $env:USERNAME -Prefix 'user')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        $t = $t -replace [regex]::Escape($env:COMPUTERNAME), (Protect-Value -Value $env:COMPUTERNAME -Prefix 'pc')
    }
    foreach ($hostName in @($script:SensitiveHosts | Where-Object { $_ } |
                              Sort-Object { ([string]$_).Length } -Descending |
                              Select-Object -Unique)) {
        $t = $t -replace [regex]::Escape([string]$hostName),
                         (Protect-Value -Value ([string]$hostName) -Prefix 'host')
    }
    foreach ($userName in @($script:SensitiveUsers | Where-Object { $_ } | Select-Object -Unique)) {
        $t = $t -replace [regex]::Escape([string]$userName),
                         (Protect-Value -Value ([string]$userName) -Prefix 'user')
    }
    foreach ($domainName in @($script:SensitiveDomains | Where-Object { $_ } | Select-Object -Unique)) {
        if ([string]$domainName -eq 'WORKGROUP') { continue }
        $t = $t -replace [regex]::Escape([string]$domainName),
                         (Protect-Value -Value ([string]$domainName) -Prefix 'domain')
    }
    return $t
}

# ============================================================================
#  console 輸出
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

function Test-TcpPort {
    <#
        測 TCP 埠是否開著。Test-NetConnection 在某些環境下慢得離譜（會先做
        一堆診斷），而且 PS 5.1 沒有 -TimeoutSeconds，所以自己用 TcpClient。
    #>
    param([string] $Target, [int] $Port, [int] $TimeoutMs = 3000)

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return [pscustomobject]@{ Ok = $false; Reason = 'timeout' }
        }
        $client.EndConnect($iar)
        return [pscustomobject]@{ Ok = $true; Reason = '' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message }
    } finally {
        try { $client.Close() } catch { }
    }
}

function Resolve-HostAddresses {
    param([string] $Name)
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Name)
        return @($addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
                 ForEach-Object { $_.IPAddressToString })
    } catch {
        return @()
    }
}

function Get-ServiceLike {
    <#
        依名稱或顯示名稱的樣式找服務。

        故意用樣式比對而不是寫死服務名：RSM 與 MPI 的服務名在版本之間換過
        （AnsoftRSMService / Ansys EM RSM / hydra_service / MsMpiLaunchSvc），
        寫死會在客戶那台剛好是別的版本時回報「沒安裝」——這正是最貴的錯法。
    #>
    param([string] $Pattern)
    try {
        return @(Get-Service -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match $Pattern -or $_.DisplayName -match $Pattern })
    } catch {
        return @()
    }
}

function ConvertTo-ReleaseLabel {
    <#
        v242 -> 2024 R2、v251 -> 2025 R1。
        舊式的 AnsysEM19.2 也吃，直接回 2019 R2。認不出來就原樣回傳。
    #>
    param([string] $Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return '' }
    if ($Token -match '^[Vv](\d{2})(\d)$') {
        return ('20' + $Matches[1] + ' R' + $Matches[2])
    }
    if ($Token -match '(\d{2})\.(\d)$') {
        return ('20' + $Matches[1] + ' R' + $Matches[2])
    }
    return $Token
}

function Get-AedtInstalls {
    <#
        找出本機所有 AEDT 安裝。三條線索都走一遍再去重：
          1. ANSYSEM_ROOT* 環境變數
          2. HKLM\SOFTWARE\Ansoft\ElectronicsDesktop
          3. 檔案系統掃描
        任何一條都可能因為安裝方式而落空，所以不能只靠一條。
    #>
    $found = @{}

    function _addInstall {
        param([string] $Root, [string] $Source)
        if ([string]::IsNullOrWhiteSpace($Root)) { return }
        $Root = $Root.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $Root)) { return }
        $exe = Join-Path $Root 'ansysedt.exe'
        if (-not (Test-Path -LiteralPath $exe)) { return }
        $key = $Root.ToLower()
        if ($found.ContainsKey($key)) {
            if ($found[$key].Sources -notcontains $Source) { $found[$key].Sources += $Source }
            return
        }
        # 版本代號在 ...\AnsysEM\v242\Win64 的倒數第二層
        $token = Split-Path -Leaf (Split-Path -Parent $Root)
        $ver   = ''
        try { $ver = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { }
        $found[$key] = [pscustomobject]@{
            Root    = $Root
            Token   = $token
            Release = (ConvertTo-ReleaseLabel $token)
            FileVersion = $ver
            Sources = @($Source)
        }
    }

    foreach ($e in (Get-ChildItem Env: -ErrorAction SilentlyContinue)) {
        if ($e.Name -match '^ANSYSEM_ROOT') { _addInstall -Root $e.Value -Source 'env' }
    }

    foreach ($hive in @('HKLM:\SOFTWARE\Ansoft\ElectronicsDesktop',
                        'HKLM:\SOFTWARE\WOW6432Node\Ansoft\ElectronicsDesktop')) {
        if (-not (Test-Path -LiteralPath $hive)) { continue }
        foreach ($k in (Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
            foreach ($sub in @('Desktop', '')) {
                $p = if ($sub) { Join-Path $k.PSPath $sub } else { $k.PSPath }
                try {
                    $props = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
                    foreach ($name in @('InstallationDirectory', 'InstallDir', 'LibraryDirectory')) {
                        if ($props -and $props.$name) { _addInstall -Root ([string]$props.$name) -Source 'registry' }
                    }
                } catch { }
            }
        }
    }

    foreach ($pat in @('C:\Program Files\AnsysEM\*\Win64',
                       'C:\Program Files\AnsysEM\*\*\Win64',
                       'C:\Program Files\ANSYS Inc\*\Win64',
                       'C:\Program Files\ANSYS Inc\*\AnsysEM')) {
        foreach ($d in (Get-Item -Path $pat -ErrorAction SilentlyContinue)) {
            _addInstall -Root $d.FullName -Source 'filesystem'
        }
    }

    return @($found.Values | Sort-Object Root)
}

function Get-TempDirectorySetting {
    <#
        讀 <root>\config\default.cfg 的 tempdirectory。
        找不到檔案與找到檔案但沒有這一行是兩件事，回傳值要分得開——
        後者代表用預設值，前者代表我們根本沒讀到設定。
    #>
    param([string] $Root)
    $cfg = Join-Path $Root 'config\default.cfg'
    if (-not (Test-Path -LiteralPath $cfg)) {
        return [pscustomobject]@{ CfgPath = $cfg; CfgFound = $false; TempDir = $null }
    }
    $temp = $null
    try {
        foreach ($line in (Get-Content -LiteralPath $cfg -ErrorAction Stop)) {
            if ($line -match "^\s*tempdirectory\s*=\s*[`"']?([^`"'\r\n]+)[`"']?\s*$") {
                $temp = $Matches[1].Trim()
            }
        }
    } catch { }
    return [pscustomobject]@{ CfgPath = $cfg; CfgFound = $true; TempDir = $temp }
}

function Get-PathLocality {
    <#
        判斷一個路徑是不是本機磁碟。UNC 與網路磁碟機都不行——temp 目錄要求
        「每台路徑相同，但各自為本機」，寫成共用路徑會讓多台互相踩。
    #>
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Kind = 'unknown'; Exists = $false; FreeGB = $null }
    }
    if ($Path -match '^\\\\') {
        return [pscustomobject]@{ Kind = 'unc'; Exists = (Test-Path -LiteralPath $Path); FreeGB = $null }
    }
    $kind   = 'unknown'
    $freeGB = $null
    if ($Path -match '^([A-Za-z]):') {
        $drive = $Matches[1].ToUpper() + ':'
        try {
            $ld = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='" + $drive + "'") -ErrorAction Stop
            if ($ld) {
                switch ([int]$ld.DriveType) {
                    3 { $kind = 'local' }
                    4 { $kind = 'network' }
                    2 { $kind = 'removable' }
                    5 { $kind = 'cdrom' }
                    default { $kind = 'other' }
                }
                if ($ld.FreeSpace) { $freeGB = [math]::Round($ld.FreeSpace / 1GB, 1) }
            }
        } catch { }
    }
    return [pscustomobject]@{
        Kind = $kind; Exists = (Test-Path -LiteralPath $Path); FreeGB = $freeGB
    }
}

function Get-ActiveAdapters {
    <#
        列出有 IPv4 位址的介面。虛擬與 VPN 介面另外標記——AEDT 串機要求
        「每台只有一張有效網卡在同一網段」，Hyper-V 與 VPN 介面是最常見的肇因。
    #>
    $virtualPattern = 'Hyper-V|vEthernet|VMware|VirtualBox|Loopback|TAP-|TUN|AnyConnect|FortiClient|' +
                      'Pulse|GlobalProtect|WireGuard|Tailscale|ZeroTier|Npcap|Bluetooth|WSL|Docker'
    $list = @()
    try {
        foreach ($c in (Get-NetIPConfiguration -ErrorAction Stop)) {
            if (-not $c.IPv4Address) { continue }
            foreach ($a in @($c.IPv4Address)) {
                $list += [pscustomobject]@{
                    Alias     = $c.InterfaceAlias
                    Desc      = $c.InterfaceDescription
                    IPv4      = $a.IPAddress
                    PrefixLen = $a.PrefixLength
                    Gateway   = $(if ($c.IPv4DefaultGateway) { @($c.IPv4DefaultGateway)[0].NextHop } else { $null })
                    IsVirtual = (("" + $c.InterfaceAlias + ' ' + $c.InterfaceDescription) -match $virtualPattern)
                }
            }
        }
    } catch {
        # Get-NetIPConfiguration 在 Server Core 或舊版上可能沒有，退回 WMI
        try {
            foreach ($n in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop)) {
                foreach ($ip in @($n.IPAddress)) {
                    if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
                    $list += [pscustomobject]@{
                        Alias     = $n.Description
                        Desc      = $n.Description
                        IPv4      = $ip
                        PrefixLen = $null
                        Gateway   = $(if ($n.DefaultIPGateway) { @($n.DefaultIPGateway)[0] } else { $null })
                        IsVirtual = ($n.Description -match $virtualPattern)
                    }
                }
            }
        } catch { }
    }
    return @($list)
}

function Get-NetworkKey {
    <#
        用 IP 與遮罩長度算出網段字串，跨機比對時用來判斷是不是同一網段。
        遮罩長度拿不到時退回 /24——會有誤判，所以呼叫端要標示這是推測值。
    #>
    param([string] $IPv4, $PrefixLen)
    if ([string]::IsNullOrWhiteSpace($IPv4)) { return $null }
    $len = 24
    $guessed = $true
    if ($PrefixLen -and [int]$PrefixLen -gt 0 -and [int]$PrefixLen -le 32) {
        $len = [int]$PrefixLen; $guessed = $false
    }
    try {
        $bytes = ([System.Net.IPAddress]::Parse($IPv4)).GetAddressBytes()
        [array]::Reverse($bytes)
        $val  = [System.BitConverter]::ToUInt32($bytes, 0)
        # 不要寫成 [uint32]0xFFFFFFFF -shl n。PowerShell 會先把 0xFFFFFFFF 當成
        # int 的 -1，轉 uint32 時直接爆掉，而且會被下面的 catch 吃掉變成靜默失效。
        $mask = if ($len -eq 0) { [uint32]0 }
                else { [uint32](4294967295L - [long][math]::Pow(2, 32 - $len) + 1L) }
        $net  = [uint32]($val -band $mask)
        $nb   = [System.BitConverter]::GetBytes([uint32]$net)
        [array]::Reverse($nb)
        $addr = ([System.Net.IPAddress]::new($nb)).IPAddressToString
        return [pscustomobject]@{ Key = ($addr + '/' + $len); Guessed = $guessed }
    } catch {
        return $null
    }
}

function Get-HpcCoreTotal {
    <#
        單台在 n 個 HPC Pack 下可用的總核心數。

        Electronics Desktop 每份授權內含 4 個 HPC unit，第 5 核起才吃 HPC 授權；
        HPC Pack 額外開放的核心數是 2 * 4^n，倍增不是線性。
          n=1 -> 8+4  = 12
          n=2 -> 32+4 = 36
          n=3 -> 128+4= 132
          n=4 -> 512+4= 516
        原廠文件在講第 4 個 pack 時會寫 512（省略內含的 4）。
    #>
    param([int] $Packs)
    if ($Packs -le 0) { return 4 }
    return [int](2 * [math]::Pow(4, $Packs) + 4)
}

# ============================================================================
#  報告輸出（節點模式與彙整模式共用）
# ============================================================================
function Write-Reports {
    param(
        [string] $BaseName,
        [string] $OutDirectory,
        [string] $Title,
        [string] $Case
    )

    if (-not (Test-Path -LiteralPath $OutDirectory)) {
        New-Item -ItemType Directory -Path $OutDirectory -Force | Out-Null
    }

    $sorted = @($script:Findings | Sort-Object @{ Expression = { $LEVEL_META[$_.Level].Rank } })

    # --- console 摘要 ---
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor White
    Write-Host ('  ' + $Title) -ForegroundColor White
    Write-Host ('=' * 60) -ForegroundColor White
    Write-Host ''
    Write-Host ('  案件編號 : ' + $Case)
    Write-Host ''

    $any = $false
    foreach ($lvl in @('CONFIRMED', 'SUSPECT', 'MANUAL')) {
        $items = @($sorted | Where-Object { $_.Level -eq $lvl })
        if ($items.Count -eq 0) { continue }
        $any = $true
        $color = 'Red'
        if ($lvl -eq 'SUSPECT') { $color = 'Yellow' }
        if ($lvl -eq 'MANUAL')  { $color = 'Magenta' }
        Write-Host ('  [' + $LEVEL_META[$lvl].Label + ']') -ForegroundColor $color
        foreach ($f in $items) {
            $where = ''
            if ($f.FixOn -and $f.FixOn -ne 'local') { $where = '  (' + $f.FixOn + ')' }
            Write-Host ('    * ' + $f.Title + $where) -ForegroundColor $color
        }
        Write-Host ''
    }
    if (-not $any) {
        Write-Host '  未發現問題。' -ForegroundColor Green
        Write-Host ''
    }

    # --- 純文字報告 ---
    $txtPath = Join-Path $OutDirectory ($BaseName + '.txt')
    $tb = New-Object System.Text.StringBuilder
    $null = $tb.AppendLine('=' * 72)
    $null = $tb.AppendLine('  ' + $TOOL_NAME + '  ' + $Title)
    $null = $tb.AppendLine('  ' + $VENDOR_NAME + '  ' + $VENDOR_EN)
    $null = $tb.AppendLine('  技術支援：' + $VENDOR_MAIL)
    $null = $tb.AppendLine('=' * 72)
    $null = $tb.AppendLine('')
    foreach ($k in $script:Facts.Keys) {
        $null = $tb.AppendLine(('  ' + $k).PadRight(24) + ': ' + (Protect-Text ([string]$script:Facts[$k])))
    }
    $null = $tb.AppendLine('')

    $null = $tb.AppendLine('-' * 72)
    $null = $tb.AppendLine('  結論')
    $null = $tb.AppendLine('-' * 72)
    $null = $tb.AppendLine('')
    if ($sorted.Count -eq 0) {
        $null = $tb.AppendLine('  未發現問題。')
        $null = $tb.AppendLine('')
    }
    foreach ($f in $sorted) {
        if ($f.Level -eq 'INFO' -or $f.Level -eq 'OK') { continue }
        $where = ''
        if ($f.FixOn -and $f.FixOn -ne 'local') { $where = '  <在 ' + $f.FixOn + ' 上處理>' }
        $null = $tb.AppendLine('  【' + $LEVEL_META[$f.Level].Label + '】' + $f.Title + $where)
        foreach ($line in (Protect-Text $f.Detail) -split "`r?`n") {
            if ($line) { $null = $tb.AppendLine('      ' + $line) }
        }
        if ($f.Fix) {
            $null = $tb.AppendLine('      → 建議：')
            foreach ($line in (Protect-Text $f.Fix) -split "`r?`n") {
                if ($line) { $null = $tb.AppendLine('        ' + $line) }
            }
        }
        if ($f.Ref) { $null = $tb.AppendLine('      參考：' + $f.Ref) }
        $null = $tb.AppendLine('')
    }

    $info = @($sorted | Where-Object { $_.Level -eq 'OK' -or $_.Level -eq 'INFO' })
    if ($info.Count -gt 0) {
        $null = $tb.AppendLine('-' * 72)
        $null = $tb.AppendLine('  其他觀察')
        $null = $tb.AppendLine('-' * 72)
        $null = $tb.AppendLine('')
        foreach ($f in $info) {
            $null = $tb.AppendLine('  [' + $LEVEL_META[$f.Level].Label + '] ' + $f.Title)
            foreach ($line in (Protect-Text $f.Detail) -split "`r?`n") {
                if ($line) { $null = $tb.AppendLine('      ' + $line) }
            }
            $null = $tb.AppendLine('')
        }
    }

    foreach ($s in $script:Sections) {
        $null = $tb.AppendLine('-' * 72)
        $null = $tb.AppendLine('  ' + $s.Name)
        $null = $tb.AppendLine('-' * 72)
        $null = $tb.AppendLine('')
        foreach ($line in $s.Lines) { $null = $tb.AppendLine('  ' + (Protect-Text $line)) }
        $null = $tb.AppendLine('')
    }

    $null = $tb.AppendLine('=' * 72)
    $null = $tb.AppendLine('  本工具全程唯讀，未修改本機任何設定。')
    $null = $tb.AppendLine('  產生時間：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $null = $tb.AppendLine('=' * 72)

    try {
        $tb.ToString() | Out-File -FilePath $txtPath -Encoding utf8 -Force
    } catch {
        Write-Host ('  報告寫入失敗：' + $_.Exception.Message) -ForegroundColor Red
        $txtPath = $null
    }
    return $txtPath
}

function Get-FindingsPayload {
    param([string] $Case, [hashtable] $Extra = @{})
    $sorted = @($script:Findings | Sort-Object @{ Expression = { $LEVEL_META[$_.Level].Rank } })
    $jsonFindings = @()
    foreach ($f in $sorted) {
        $params = $null
        if ($f.FixParams) { $params = [pscustomobject]$f.FixParams }
        $jsonFindings += [pscustomobject]@{
            level     = $f.Level
            title     = Protect-Text $f.Title
            detail    = Protect-Text $f.Detail
            fixText   = Protect-Text $f.Fix
            fixAction = $(if ($f.FixAction) { $f.FixAction } else { $null })
            fixTier   = $(if ($f.FixTier -gt 0) { $f.FixTier } else { $null })
            fixOn     = $(if ($f.FixAction) { $f.FixOn } else { $null })
            fixParams = $params
        }
    }
    $factsObj = [ordered]@{}
    foreach ($k in $script:Facts.Keys) { $factsObj[$k] = Protect-Text ([string]$script:Facts[$k]) }

    $payload = [ordered]@{
        schemaVersion = $NODE_SCHEMA
        tool          = [ordered]@{ name = $TOOL_NAME; version = $TOOL_VERSION }
        caseId        = $Case
        generatedAt   = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
        anonymized    = [bool]$Anonymize
        facts         = $factsObj
        findings      = $jsonFindings
        actionable    = @($jsonFindings | Where-Object {
                            $_.level -eq 'CONFIRMED' -and $_.fixAction -and $_.fixTier -lt 3
                          } | ForEach-Object { $_.fixAction } | Select-Object -Unique)
        notAutomatable= @($jsonFindings | Where-Object { $_.fixTier -eq 3 } |
                          ForEach-Object { $_.fixAction } | Select-Object -Unique)
    }
    foreach ($k in $Extra.Keys) { $payload[$k] = $Extra[$k] }
    return $payload
}

# ============================================================================
#  彙整模式
# ============================================================================
function Invoke-MergeMode {
    param([string[]] $Paths, [string] $OutDirectory)

    Write-Head '讀取節點報告'

    $files = @()
    foreach ($p in $Paths) {
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
        Write-Host ''
        Write-Host '  沒有找到任何 .node.json。' -ForegroundColor Red
        Write-Host '  請先在每一台機器上跑一次節點模式，再把產生的 .node.json 收到同一個資料夾。' -ForegroundColor Yellow
        Write-Host ''
        return 2
    }

    $nodes = @()
    foreach ($f in $files) {
        try {
            $obj = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Add-Finding -Level 'MANUAL' -Title ('節點報告讀取失敗：' + (Split-Path -Leaf $f)) `
                -Detail $_.Exception.Message
            continue
        }
        if (-not $obj.node) {
            Add-Finding -Level 'MANUAL' -Title ('不是節點報告：' + (Split-Path -Leaf $f)) `
                -Detail '檔案能解析成 JSON，但沒有 node 區塊。請確認是本工具產生的 .node.json。'
            continue
        }
        if ($obj.schemaVersion -ne $NODE_SCHEMA) {
            Add-Finding -Level 'MANUAL' -Title ('節點報告版本不符：' + $obj.node.computerName) `
                -Detail ('檔案 schemaVersion = ' + $obj.schemaVersion + '，本工具預期 ' + $NODE_SCHEMA + '。' +
                         [Environment]::NewLine + '請用同一版工具重新收集。')
            continue
        }
        $nodes += $obj
        Write-Step ('讀入 ' + $obj.node.computerName + '  (' + (Split-Path -Leaf $f) + ')')
    }

    if ($nodes.Count -eq 0) { return 2 }

    # 匿名彙整報告時也要遮掉節點檔內出現的所有本機與對端名稱。
    $nodeHosts = @($nodes | ForEach-Object {
        [string]$_.node.computerName
        [string]$_.node.userName
        [string]$_.node.domain
        @($_.node.peerProbes) | ForEach-Object { [string]$_.target }
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_) -and [string]$_ -ne 'WORKGROUP'
    })
    $script:SensitiveHosts = @($script:SensitiveHosts + $nodeHosts | Sort-Object -Unique)
    $script:SensitiveUsers = @($nodes | ForEach-Object { [string]$_.node.userName } |
                                Where-Object { $_ } | Sort-Object -Unique)
    $script:SensitiveDomains = @($nodes | ForEach-Object { [string]$_.node.domain } |
                                  Where-Object { $_ } | Sort-Object -Unique)

    # 案件編號一致性。不一致代表混到別case的資料，比對出來的差異全都不可信。
    $cases = @($nodes | ForEach-Object { $_.caseId } | Select-Object -Unique)
    $case  = @($cases)[0]
    if ($cases.Count -gt 1) {
        Add-Finding -Level 'MANUAL' -Title '這批節點報告的案件編號不一致' `
            -Detail ('讀到 ' + $cases.Count + ' 種案件編號：' + ($cases -join '、') + [Environment]::NewLine +
                     '可能混到了別的案件或別批機器的資料。下面所有跨機比對的結論都要打折扣。') `
            -Fix '請確認每一台收集時都用同一個 -CaseId，再重收一次。'
    }

    $script:Facts['案件編號']   = $case
    $script:Facts['節點數量']   = $nodes.Count
    $script:Facts['節點清單']   = (@($nodes | ForEach-Object { $_.node.computerName }) -join '、')
    $script:Facts['串機型態']   = (@($nodes | ForEach-Object { $_.node.mode } | Select-Object -Unique) -join '、')

    if ($nodes.Count -lt 2) {
        Add-Finding -Level 'MANUAL' -Title '只有一台機器的資料，無法做跨機比對' `
            -Detail '串機檢查的重點在跨機一致性。單一節點的報告只能看該台自己的狀態。' `
            -Fix '請在每一台要參與串機的機器上都跑一次節點模式，再彙整。'
    }

    # ---- 逐項跨機比對 ----
    Write-Head '跨機比對'

    $sec = Add-Section '各節點摘要'
    Add-Row $sec ('機器名稱'.PadRight(18) + 'AEDT 版本'.PadRight(24) + 'RSM'.PadRight(8) + 'MPI')
    Add-Row $sec ('-' * 72)
    foreach ($n in $nodes) {
        $vers = (@($n.node.aedt | ForEach-Object { $_.release }) -join ',')
        if (-not $vers) { $vers = '(未偵測到)' }
        $rsm  = if ($n.node.rsm.running) { '執行中' } elseif ($n.node.rsm.installed) { '已停' } else { '未偵測到' }
        $mpi  = (@($n.node.mpi.detected | ForEach-Object { $_.vendor }) -join ',')
        if (-not $mpi) { $mpi = '(未偵測到)' }
        Add-Row $sec ($n.node.computerName.PadRight(18) + $vers.PadRight(24) + $rsm.PadRight(8) + $mpi)
    }

    # 1. AEDT 版本
    Write-Step '比對 AEDT 版本'
    $noAedt = @($nodes | Where-Object { -not $_.node.aedt -or @($_.node.aedt).Count -eq 0 })
    foreach ($n in $noAedt) {
        Add-Finding -Level 'CONFIRMED' -Title ($n.node.computerName + ' 上沒有偵測到 AEDT') `
            -Detail '這台無法參與串機。' `
            -Fix '在這台安裝與其他機器相同版本、相同路徑的 AEDT。' `
            -FixAction 'align-aedt-version' -FixOn $n.node.computerName
    }
    $withAedt = @($nodes | Where-Object { $_.node.aedt -and @($_.node.aedt).Count -gt 0 })
    if ($withAedt.Count -ge 2) {
        # 每台各自的版本集合取交集，沒有交集就是串不起來
        $common = $null
        foreach ($n in $withAedt) {
            $set = @($n.node.aedt | ForEach-Object { $_.release })
            if ($null -eq $common) { $common = $set }
            else { $common = @($common | Where-Object { $set -contains $_ }) }
        }
        if (@($common).Count -eq 0) {
            $detail = '各機器安裝的版本：' + [Environment]::NewLine
            foreach ($n in $withAedt) {
                $detail += '  ' + $n.node.computerName + ' : ' +
                           ((@($n.node.aedt | ForEach-Object { $_.release })) -join '、') + [Environment]::NewLine
            }
            Add-Finding -Level 'CONFIRMED' -Title '沒有任何一個 AEDT 版本是每台機器都有的' `
                -Detail ($detail + '串機要求每台裝同一版本。') `
                -Fix '把所有要參與串機的機器統一到同一個版本。' `
                -FixAction 'align-aedt-version' -FixOn 'all'
        } else {
            Add-Finding -Level 'OK' -Title ('每台都有的版本：' + ((@($common)) -join '、')) `
                -Detail '串機請指定其中一個版本。'
            $script:Facts['共通版本'] = ((@($common)) -join '、')

            # 同一個 release 底下還有修補版號（2026.1.0 與 2026.1.4 都是 2026 R1）。
            # 只比到 release 會說「版本一致」然後放行，但那是不同的執行檔。
            # Ansys 要求各節點裝同一版；修補版不同會不會出事要看情況，
            # 所以這裡列【可疑】而不是【確定】——講死了就是超出證據。
            foreach ($rel in @($common)) {
                $pairs = @()
                foreach ($n in $withAedt) {
                    $hit = @($n.node.aedt | Where-Object { $_.release -eq $rel } |
                             Where-Object { $_.fileVersion }) | Select-Object -First 1
                    if ($hit) {
                        $pairs += [pscustomobject]@{
                            Machine = $n.node.computerName
                            File    = [string]$hit.fileVersion
                        }
                    }
                }
                $distinct = @($pairs | ForEach-Object { $_.File } | Select-Object -Unique)
                if ($pairs.Count -ge 2 -and $distinct.Count -gt 1) {
                    $detail = ($rel + ' 在各機器上的實際版本：') + [Environment]::NewLine
                    foreach ($pair in $pairs) {
                        $detail += '  ' + $pair.Machine + ' : ' + $pair.File + [Environment]::NewLine
                    }
                    $detail += '這些都算 ' + $rel + '，但執行檔不是同一版。'
                    Add-Finding -Level 'SUSPECT' -Title ($rel + ' 的修補版號各機不同') `
                        -Detail $detail `
                        -Fix ('把參與串機的機器統一到同一個修補版（通常是都更新到最新的 ' +
                              (@($distinct | Sort-Object -Descending)[0]) + '）。') `
                        -FixAction 'align-aedt-version' -FixOn 'all'
                }
            }
        }

        # 1b. 作業系統產品不同是明確不相容；相同產品但更新層級不同先列為疑點。
        #     新版節點分開保存 Caption／Version／Build，舊版仍可從 os 欄位盡量解析。
        Write-Step '比對作業系統版本'
        $osRecords = @()
        $osUnknown = @()
        foreach ($n in $nodes) {
            $caption = [string]$n.node.osCaption
            $version = [string]$n.node.osVersion
            $build = [string]$n.node.osBuildNumber
            $legacy = [string]$n.node.os
            if ([string]::IsNullOrWhiteSpace($caption)) { $caption = $legacy }
            if ([string]::IsNullOrWhiteSpace($version) -and
                $caption -match '^(.*?)\s*\((\d+(?:\.\d+)+)\)\s*$') {
                $caption = $Matches[1].Trim()
                $version = $Matches[2]
            }
            if ([string]::IsNullOrWhiteSpace($caption)) {
                $osUnknown += $n.node.computerName
                continue
            }
            $osRecords += [pscustomobject]@{
                Computer = [string]$n.node.computerName
                Caption = $caption.Trim()
                CaptionKey = $caption.Trim().ToLowerInvariant()
                Version = $version.Trim()
                Build = $build.Trim()
            }
        }
        $captionGroups = @($osRecords | Group-Object CaptionKey)
        if ($captionGroups.Count -gt 1) {
            $detail = ''
            foreach ($r in $osRecords) {
                $suffix = if ($r.Version) { ' (' + $r.Version + ')' } else { '' }
                $detail += '  ' + $r.Caption + $suffix + '  <- ' + $r.Computer + [Environment]::NewLine
            }
            Add-Finding -Level 'CONFIRMED' -Title '作業系統版本各機不同' `
                -Detail ($detail + '參與串機的機器應使用相同 Windows 產品版本。') `
                -Fix '請 IT 把要參與串機的機器統一到相同 Windows 產品版本。' `
                -FixAction 'align-os-version' -FixOn 'all'
        } elseif ($captionGroups.Count -eq 1) {
            $versions = @($osRecords | ForEach-Object { $_.Version } |
                          Where-Object { $_ } | Select-Object -Unique)
            $builds = @($osRecords | ForEach-Object { $_.Build } |
                        Where-Object { $_ } | Select-Object -Unique)
            if ($versions.Count -gt 1 -or $builds.Count -gt 1) {
                $detail = ''
                foreach ($r in $osRecords) {
                    $detail += '  ' + $r.Caption + '，Version ' + $(if ($r.Version) { $r.Version } else { '未知' }) +
                               '，Build ' + $(if ($r.Build) { $r.Build } else { '未知' }) +
                               '  <- ' + $r.Computer + [Environment]::NewLine
                }
                Add-Finding -Level 'SUSPECT' -Title 'Windows 更新層級各機不同' `
                    -Detail ($detail + '不先判定為故障；正式求解前請確認 Windows Update 與修補層級。') `
                    -Fix '請 IT 確認各機器的 Windows 更新與修補層級是否需要統一。' `
                    -FixAction 'align-os-version' -FixOn 'all'
            } else {
                Add-Finding -Level 'OK' -Title ('作業系統版本一致：' + $osRecords[0].Caption)
            }
        }
        if ($osUnknown.Count -gt 0) {
            Add-Finding -Level 'MANUAL' -Title '有機器讀不到作業系統版本' `
                -Detail ('請人工確認：' + ($osUnknown -join '、'))
        }

        # 2. 安裝路徑是否一致
        #
        # 這一段與下面的 temp 比對刻意不放進「有共通版本」的分支裡。
        # 版本不一致時這些問題依然存在，而客戶統一版本之後會馬上撞上——
        # 一次講完比讓他跑第二輪才發現划算。
        Write-Step '比對安裝路徑'
        $relScope = if (@($common).Count -gt 0) { @($common) } else { $null }
        $relsToCheck = if ($relScope) { $relScope }
                       else { @($withAedt | ForEach-Object { $_.node.aedt } |
                                ForEach-Object { $_.release } | Select-Object -Unique) }
        foreach ($rel in $relsToCheck) {
            # 不可以叫 $paths——PowerShell 變數不分大小寫，會撞到本函式的 $Paths 參數
            $rootMap = @{}
            foreach ($n in $withAedt) {
                foreach ($a in @($n.node.aedt)) {
                    if ($a.release -ne $rel) { continue }
                    $key = ([string]$a.root).ToLower()
                    if (-not $rootMap.ContainsKey($key)) { $rootMap[$key] = @() }
                    if ($rootMap[$key] -notcontains $n.node.computerName) {
                        $rootMap[$key] += $n.node.computerName
                    }
                }
            }
            if ($rootMap.Keys.Count -gt 1) {
                $detail = $rel + ' 的安裝路徑：' + [Environment]::NewLine
                foreach ($k in $rootMap.Keys) {
                    $detail += '  ' + $k + '  <- ' + (($rootMap[$k]) -join '、') + [Environment]::NewLine
                }
                Add-Finding -Level 'CONFIRMED' -Title ($rel + ' 的安裝路徑各機不同') `
                    -Detail ($detail + '串機要求每台裝在相同路徑，或改成共用目錄。') `
                    -Fix '重裝到相同路徑，或改用一台上的共用安裝目錄讓其他機器掛載。' `
                    -FixAction 'align-aedt-version' -FixOn 'all'
            }
        }

        # 3. temp 目錄
        Write-Step '比對 temp 目錄'
        $tempMap = @{}
        $tempUnknown = @()
        foreach ($n in $withAedt) {
            foreach ($a in @($n.node.aedt)) {
                if ($relScope -and ($relScope -notcontains $a.release)) { continue }
                if ([string]::IsNullOrWhiteSpace($a.tempDir)) {
                    $tempUnknown += ($n.node.computerName + ' (' + $a.release + ')')
                    continue
                }
                $key = ([string]$a.tempDir).ToLower().TrimEnd('\')
                if (-not $tempMap.ContainsKey($key)) { $tempMap[$key] = @() }
                if ($tempMap[$key] -notcontains $n.node.computerName) {
                    $tempMap[$key] += $n.node.computerName
                }
            }
        }
        if ($tempMap.Keys.Count -gt 1) {
            $detail = ''
            foreach ($k in $tempMap.Keys) {
                $detail += '  ' + $k + '  <- ' + (($tempMap[$k]) -join '、') + [Environment]::NewLine
            }
            # 只要有一個值帶 8.3 短檔名（PROGRA~1、JEFF~1.HON 這種），就提醒一句。
            # 實際遇過同一台的不同版次，一個寫短檔名一個寫長檔名，指的是同一個目錄。
            # 判定仍然是【確定】：AEDT 要求的是「路徑字串相同」，而且本工具讀不到
            # 別台機器的短檔名對應，無從展開比對。講出來讓人自己判斷就好。
            $shortNameNote = ''
            foreach ($k in $tempMap.Keys) {
                if ($k -match '~\d') {
                    $shortNameNote = [Environment]::NewLine +
                        '註：上面有路徑使用 8.3 短檔名（含 ~1 這種寫法），' +
                        '兩者可能其實是同一個目錄的長短檔名兩種寫法。' + [Environment]::NewLine +
                        '即使如此仍建議統一——AEDT 比的是路徑字串本身，不是展開後的目錄。'
                    break
                }
            }
            Add-Finding -Level 'CONFIRMED' -Title 'temp 目錄各機路徑不同' `
                -Detail ($detail + [Environment]::NewLine +
                         '串機要求 temp 目錄「每台路徑字串相同、但各自為本機磁碟」。' + [Environment]::NewLine +
                         '這是實務上最常被漏掉的一項。' + $shortNameNote) `
                -Fix ('在每台的 <安裝路徑>\config\default.cfg 設成同一個值，例如：' + [Environment]::NewLine +
                      "  tempdirectory='C:\Temp'") `
                -FixAction 'set-temp-directory' -FixOn 'all'
        } elseif ($tempMap.Keys.Count -eq 1) {
            Add-Finding -Level 'OK' -Title ('temp 目錄各機一致：' + (@($tempMap.Keys)[0]))
        }
        if ($tempUnknown.Count -gt 0) {
            Add-Finding -Level 'MANUAL' -Title '有機器的 temp 目錄讀不到設定' `
                -Detail ('以下節點的 default.cfg 沒有 tempdirectory 這一行，代表用內建預設值：' +
                         [Environment]::NewLine + '  ' + ($tempUnknown -join ([Environment]::NewLine + '  ')) +
                         [Environment]::NewLine +
                         '預設值在不同版本與不同 Windows 設定下不見得相同，串機前建議明確指定。') `
                -Fix '在每台的 default.cfg 明確寫上相同的 tempdirectory。' `
                -FixAction 'set-temp-directory' -FixOn 'all'
        }
    }

    # 4. RSM
    Write-Step '比對串機環境變數'
    # ANSYS_EM_EXEC_DIR 是 RSM 以 MPI 緊密整合啟動 AEDT 引擎時必要的。
    # 缺了不會報錯，會卡在求解初期查詢記憶體那一步不動——實機踩過。
    $execDirMissing = @()
    $execDirValues  = @{}
    $envDataSeen    = $false
    foreach ($n in $nodes) {
        if ($null -eq $n.node.clusterEnv) { continue }
        $envDataSeen = $true
        $value = [string]$n.node.clusterEnv.ANSYS_EM_EXEC_DIR
        if ([string]::IsNullOrWhiteSpace($value)) {
            $execDirMissing += $n.node.computerName
        } else {
            $execDirValues[$n.node.computerName] = $value
        }
    }
    if (-not $envDataSeen) {
        Add-Finding -Level 'MANUAL' -Title '節點報告沒有串機環境變數資料' `
            -Detail '這些節點報告是舊版工具產生的，無法比對 ANSYS_EM_EXEC_DIR 等設定。' `
            -Fix '兩台都用新版重跑一次節點檢查。'
    } elseif ($execDirMissing.Count -gt 0) {
        Add-Finding -Level 'CONFIRMED' -Title (($execDirMissing -join '、') + ' 沒有設定 ANSYS_EM_EXEC_DIR') `
            -Detail ('RSM 以 MPI 緊密整合啟動 AEDT 引擎時需要這個環境變數。' + [Environment]::NewLine +
                     '缺了不會跳錯誤訊息，求解會卡在「Determining memory availability on distributed machines」' + [Environment]::NewLine +
                     '之類的地方不動，看不出跟環境變數有關。' + [Environment]::NewLine +
                     '沒設通常就代表那台沒有跑過修復步驟。') `
            -Fix '在這幾台各跑一次修復（一鍵串機的步驟 6），然後重新啟動 Electromagnetics RSM 服務。' `
            -FixAction 'set-ansys-em-exec-dir' -FixOn (($execDirMissing -join ','))
    } else {
        $distinctExec = @($execDirValues.Values | Select-Object -Unique)
        if ($distinctExec.Count -gt 1) {
            $detail = '各機器的 ANSYS_EM_EXEC_DIR：' + [Environment]::NewLine
            foreach ($k in ($execDirValues.Keys | Sort-Object)) {
                $detail += '  ' + $k + ' : ' + $execDirValues[$k] + [Environment]::NewLine
            }
            Add-Finding -Level 'SUSPECT' -Title 'ANSYS_EM_EXEC_DIR 各機路徑不同' `
                -Detail ($detail + '串機要求各節點的 AEDT 安裝路徑相同。') `
                -Fix '把各機的 AEDT 安裝到相同路徑，或確認這些路徑指向同一個版本。' `
                -FixAction 'set-ansys-em-exec-dir' -FixOn 'all'
        } else {
            Add-Finding -Level 'OK' -Title '每台都設好了 ANSYS_EM_EXEC_DIR' `
                -Detail ('值：' + $distinctExec[0])
        }
    }

    Write-Step '比對 RSM 狀態'
    $noRsm  = @($nodes | Where-Object { -not $_.node.rsm.installed })
    $offRsm = @($nodes | Where-Object { $_.node.rsm.installed -and -not $_.node.rsm.running })
    foreach ($n in $noRsm) {
        Add-Finding -Level 'SUSPECT' -Title ($n.node.computerName + ' 上沒有偵測到 RSM 服務') `
            -Detail ('沒有找到名稱或顯示名稱含 RSM 的服務。' + [Environment]::NewLine +
                     '走 RSM 路徑串機時每台都必須註冊；只用排程器或純命令列 MPI 時可以不用。') `
            -Fix '開始 > Ansys Electromagnetics > Register with RSM（多版本要逐一註冊）。' `
            -FixAction 'register-rsm' -FixOn $n.node.computerName
    }
    foreach ($n in $offRsm) {
        Add-Finding -Level 'CONFIRMED' -Title ($n.node.computerName + ' 的 RSM 服務沒有執行') `
            -Detail ('服務存在但不是 Running。狀態：' + $n.node.rsm.status) `
            -Fix '啟動該服務，並把啟動類型設為自動。' `
            -FixAction 'start-rsm-service' -FixOn $n.node.computerName
    }

    # 5. MPI
    Write-Step '比對 MPI'
    $vendorMap = @{}
    foreach ($n in $nodes) {
        $vs = @($n.node.mpi.detected | ForEach-Object { $_.vendor } | Select-Object -Unique)
        if ($vs.Count -eq 0) {
            Add-Finding -Level 'SUSPECT' -Title ($n.node.computerName + ' 上沒有偵測到任何 MPI') `
                -Detail ('沒有找到 Intel MPI hydra_service、Microsoft MPI 或 IBM Platform MPI 的跡象。' +
                         [Environment]::NewLine +
                         '純 DSO 分列不需要 MPI；DDM 或頻點分散一定要。') `
                -Fix '在這台安裝與其他機器相同的 MPI，或確認串機型態只需要 DSO。' `
                -FixAction 'install-msmpi' -FixOn $n.node.computerName
            continue
        }
        foreach ($v in $vs) {
            if (-not $vendorMap.ContainsKey($v)) { $vendorMap[$v] = @() }
            $vendorMap[$v] += $n.node.computerName
        }
    }
    $commonVendors = @($vendorMap.Keys | Where-Object { @($vendorMap[$_]).Count -eq $nodes.Count })
    if ($vendorMap.Keys.Count -gt 0 -and $commonVendors.Count -eq 0) {
        $detail = '各機偵測到的 MPI：' + [Environment]::NewLine
        foreach ($k in $vendorMap.Keys) {
            $detail += '  ' + $k + '  <- ' + (($vendorMap[$k]) -join '、') + [Environment]::NewLine
        }
        Add-Finding -Level 'CONFIRMED' -Title '沒有任何一種 MPI 是每台都有的' `
            -Detail ($detail + '走 MPI 的串機要求每台裝同一種、同一版。') `
            -Fix ('一般 Windows 多工作站請在每台安裝 AEDT 支援的相同 Intel MPI；' +
                  'Microsoft MPI 的多主機模式只支援 Windows HPC Job。') `
            -FixAction 'install-intel-mpi' -FixOn 'all'
    } elseif ($commonVendors.Count -gt 0) {
        Add-Finding -Level 'OK' -Title ('每台都有的 MPI：' + ($commonVendors -join '、'))
        # hydra_service 的版本要與 Intel MPI 版本相符
        if ($commonVendors -contains 'IntelMPI') {
            $hydraVers = @{}
            foreach ($n in $nodes) {
                foreach ($d in @($n.node.mpi.detected)) {
                    if ($d.vendor -ne 'IntelMPI') { continue }
                    $v = if ($d.version) { [string]$d.version } else { '(未知)' }
                    if (-not $hydraVers.ContainsKey($v)) { $hydraVers[$v] = @() }
                    $hydraVers[$v] += $n.node.computerName
                }
            }
            if ($hydraVers.Keys.Count -gt 1) {
                $detail = ''
                foreach ($k in $hydraVers.Keys) {
                    $detail += '  ' + $k + '  <- ' + (($hydraVers[$k]) -join '、') + [Environment]::NewLine
                }
                Add-Finding -Level 'SUSPECT' -Title 'Intel MPI 的 hydra_service 版本各機不同' `
                    -Detail ($detail + 'hydra_service 的版本必須與要使用的 Intel MPI 版本相符。') `
                    -Fix ('統一各機的 Intel MPI 版本。只有 Windows HPC Job 的多主機模式' +
                          '才可改用 Microsoft MPI。') `
                    -FixAction 'install-hydra-service' -FixOn 'all'
            }
            $noHydraRun = @($nodes | Where-Object {
                $h = @($_.node.mpi.detected | Where-Object { $_.vendor -eq 'IntelMPI' })
                $h.Count -gt 0 -and -not (@($h | Where-Object { $_.running })).Count
            })
            foreach ($n in $noHydraRun) {
                Add-Finding -Level 'CONFIRMED' -Title ($n.node.computerName + ' 的 hydra_service 沒有執行') `
                    -Detail 'Intel MPI 在 Windows 上要求每台的 hydra_service 都安裝且執行中。' `
                    -Fix ('以系統管理員身分：' + [Environment]::NewLine +
                          '  hydra_service -install' + [Environment]::NewLine +
                          '  hydra_service -start') `
                    -FixAction 'start-hydra-service' -FixOn $n.node.computerName
            }
        }
    }

    # 6. 使用者帳號
    Write-Step '比對使用者帳號'
    $users = @{}
    foreach ($n in $nodes) {
        $u = [string]$n.node.userName
        if ([string]::IsNullOrWhiteSpace($u)) { continue }
        if (-not $users.ContainsKey($u)) { $users[$u] = @() }
        $users[$u] += $n.node.computerName
    }
    if ($users.Keys.Count -gt 1) {
        $detail = ''
        foreach ($k in $users.Keys) {
            $displayUser = Protect-Value -Value ([string]$k) -Prefix 'user'
            $detail += '  ' + $displayUser + '  <- ' + (($users[$k]) -join '、') + [Environment]::NewLine
        }
        Add-Finding -Level 'SUSPECT' -Title '收集時的使用者帳號各機不同' `
            -Detail ($detail + [Environment]::NewLine +
                     '串機要求每台有同一組帳號與密碼。這裡看到的是「跑本工具的人」，' +
                     '不一定等於實際跑模擬的帳號，所以只列為【可疑】。' + [Environment]::NewLine +
                     '密碼是否相同本工具無法也不應該檢查。') `
            -Fix '確認實際要跑模擬的帳號在每台都存在且密碼相同（或使用網域帳號）。' `
            -FixAction 'align-user-account' -FixOn 'all'
    } elseif ($users.Keys.Count -eq 1) {
        $displayUser = Protect-Value -Value ([string](@($users.Keys)[0])) -Prefix 'user'
        Add-Finding -Level 'INFO' -Title ('收集時的帳號各機一致：' + $displayUser) `
            -Detail '密碼是否相同無法由本工具驗證。'
    }

    # 7. 網段
    Write-Step '比對網段'
    $subnets = @{}
    $multiNic = @()
    $withVirtual = @()
    foreach ($n in $nodes) {
        $real = @($n.node.adapters | Where-Object { -not $_.isVirtual })
        $virt = @($n.node.adapters | Where-Object { $_.isVirtual })
        # 只有「實體網卡不只一張」才算問題。多一張 Hyper-V 介面很常見，
        # 把它也算成【可疑】會讓報告在幾乎每個客戶那裡都亮燈，燈就不值錢了。
        if ($real.Count -gt 1) {
            $multiNic += ($n.node.computerName + ' (實體 ' + $real.Count + ' 張：' +
                          ((@($real | ForEach-Object { $_.alias })) -join '、') + ')')
        }
        if ($virt.Count -gt 0) {
            $withVirtual += ($n.node.computerName + ' (' + ((@($virt | ForEach-Object { $_.alias })) -join '、') + ')')
        }
        foreach ($a in $real) {
            if (-not $a.network) { continue }
            $k = [string]$a.network
            if (-not $subnets.ContainsKey($k)) { $subnets[$k] = @() }
            if ($subnets[$k] -notcontains $n.node.computerName) { $subnets[$k] += $n.node.computerName }
        }
    }
    $sharedSubnet = @($subnets.Keys | Where-Object { @($subnets[$_]).Count -eq $nodes.Count })
    if ($nodes.Count -ge 2) {
        if ($sharedSubnet.Count -eq 0) {
            $detail = '各機的實體網卡網段：' + [Environment]::NewLine
            foreach ($k in $subnets.Keys) { $detail += '  ' + $k + '  <- ' + (($subnets[$k]) -join '、') + [Environment]::NewLine }
            Add-Finding -Level 'SUSPECT' -Title '沒有一個網段是每台都在的' `
                -Detail ($detail + [Environment]::NewLine +
                         '遮罩長度取不到時本工具會以 /24 推測，跨網段的判斷可能因此失準。') `
                -Fix '把要串機的機器放在同一個網段，或請網管確認跨網段的路由與防火牆。' `
                -FixAction 'fix-network-topology' -FixOn 'all'
        } else {
            Add-Finding -Level 'OK' -Title ('每台都在的網段：' + ($sharedSubnet -join '、'))
        }
    }
    if ($multiNic.Count -gt 0) {
        Add-Finding -Level 'SUSPECT' -Title '有機器存在多張實體網卡' `
            -Detail (('  ' + ($multiNic -join ([Environment]::NewLine + '  '))) + [Environment]::NewLine +
                     'AEDT 串機要求每台只有一個有效網路在同一網段。多網卡時 MPI 可能挑到錯的介面。') `
            -Fix '串機測試期間停用不需要的介面；確認可以跑之後再逐項恢復。' `
            -FixAction 'fix-network-topology' -FixOn 'all'
    }
    if ($withVirtual.Count -gt 0) {
        Add-Finding -Level 'INFO' -Title '有機器存在虛擬或 VPN 介面' `
            -Detail (('  ' + ($withVirtual -join ([Environment]::NewLine + '  '))) + [Environment]::NewLine +
                     '虛擬介面本身通常無害，但要確認主機名稱解析到預期介面。' + [Environment]::NewLine +
                     '判定靠名稱樣式比對，可能有漏。不要因為使用 VPN 就改用 Microsoft MPI；' +
                     'Microsoft MPI 多主機只支援 Windows HPC Job。')
    }

    # 8. 連通性矩陣
    Write-Step '整理連通性'
    $probeSec = Add-Section ('連通性（TCP ' + $RsmPort + '）')
    $anyProbe = $false
    $failPairs = @()
    foreach ($n in $nodes) {
        foreach ($p in @($n.node.peerProbes)) {
            $anyProbe = $true
            $mark = if ($p.tcpOk) { 'OK' } else { '失敗' }
            Add-Row $probeSec ($n.node.computerName + '  ->  ' + $p.target + '   ' + $mark +
                               $(if ($p.resolved) { '   ' + (($p.resolved) -join ',') } else { '   (名稱無法解析)' }))
            if (-not $p.tcpOk) { $failPairs += ($n.node.computerName + ' -> ' + $p.target) }
        }
    }
    if (-not $anyProbe) {
        Add-Row $probeSec '（收集時沒有指定 -Peers，沒有連通性資料）'
        Add-Finding -Level 'MANUAL' -Title '沒有任何連通性測試資料' `
            -Detail '收集時沒有指定 -Peers，所以無法判斷機器之間能不能連上。' `
            -Fix '在每台重跑一次並用 -Peers 列出其他機器，例如：-Peers WS02,WS03'
    } elseif ($failPairs.Count -gt 0) {
        Add-Finding -Level 'CONFIRMED' -Title ('有 ' + $failPairs.Count + ' 條連線測試失敗') `
            -Detail (('  ' + ($failPairs -join ([Environment]::NewLine + '  '))) + [Environment]::NewLine +
                     'TCP ' + $RsmPort + ' 是 AnsoftRSMService 的連接埠。連不上通常是服務沒起、' +
                     '防火牆擋住，或名稱解析到錯的位址。') `
            -Fix ('依序確認：' + [Environment]::NewLine +
                  '  1. 目標機器的 RSM 服務在跑' + [Environment]::NewLine +
                  '  2. 防火牆放行 TCP ' + $RsmPort + ' 與 MPI 用的埠' + [Environment]::NewLine +
                  '  3. 名稱解析到的位址是對的那張網卡') `
            -FixAction 'add-cluster-firewall' -FixOn 'all'
    } else {
        Add-Finding -Level 'OK' -Title '所有做過的連線測試都通'
    }

    # 9. 防火牆
    $fwOff = @($nodes | Where-Object { $_.node.firewall.anyProfileOff })
    if ($fwOff.Count -gt 0) {
        Add-Finding -Level 'INFO' -Title '有機器的防火牆設定檔是關閉的' `
            -Detail ('  ' + ((@($fwOff | ForEach-Object { $_.node.computerName })) -join '、') + [Environment]::NewLine +
                     '正式設定應啟用防火牆，並放行 AEDT、RSM、Intel Hydra 與 MPI 通訊埠。' +
                     '官方只在特定 RSM 連線錯誤的故障排除流程中，把暫時停用防火牆列為隔離測試。')
    }

    # 10. HPC Pack 試算
    if ($HpcPacks -gt 0) {
        Add-HpcPackFinding -Packs $HpcPacks -Machines $nodes.Count
    }

    Add-Finding -Level 'INFO' -Title '授權面請另外用 License 診斷工具確認' `
        -Detail ('本工具不查 License。HPC Pack 夠不夠、anshpc 有沒有被借光，' +
                 '請在同一批機器上跑 Check-AnsysLicense.ps1 -Product HFSS。')

    # ---- 輸出 ----
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeCase = ($case -replace '[^\w\-\.]', '_')
    $baseName = 'AedtCluster_' + $safeCase + '_merged_' + $stamp
    $txtPath  = Write-Reports -BaseName $baseName -OutDirectory $OutDirectory -Title '串機彙整報告' -Case $case

    $jsonPath = $null
    if ($Json) {
        $jsonPath = Join-Path $OutDirectory ($baseName + '.findings.json')
        $payload  = Get-FindingsPayload -Case $case -Extra @{
            mergedNodes = @($nodes | ForEach-Object { Protect-Text $_.node.computerName })
        }
        try { $payload | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding utf8 -Force }
        catch { Write-Host ('  JSON 輸出失敗：' + $_.Exception.Message) -ForegroundColor Red; $jsonPath = $null }
    }

    Write-Host ('=' * 60) -ForegroundColor White
    Write-Host '  彙整報告已產生' -ForegroundColor Green
    Write-Host ''
    if ($txtPath)  { Write-Host ('    ' + $txtPath) }
    if ($jsonPath) { Write-Host ('    ' + $jsonPath) }
    Write-Host ''
    Write-Host ('  請寄至 ' + $VENDOR_MAIL + '，並註明案件編號 ' + $case) -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  本工具全程唯讀，未修改任何機器的設定。' -ForegroundColor Green
    Write-Host ''
    return 0
}

function Add-HpcPackFinding {
    <#
        HPC Pack 是倍增不是線性，攤到多台常常反而總核心數變少。
        這件事要在客戶動手串機之前就講——不然買了機器才發現划不來。
    #>
    param([int] $Packs, [int] $Machines)
    if ($Packs -le 0) { return }
    if ($Machines -lt 1) { $Machines = 1 }

    $lines = @()
    $lines += ('手上 ' + $Packs + ' 個 HPC Pack 的幾種配置：')
    $lines += ''
    $lines += ('  集中在 1 台        : ' + (Get-HpcCoreTotal -Packs $Packs) + ' 核')
    $best = Get-HpcCoreTotal -Packs $Packs
    $bestLabel = '集中在 1 台'
    for ($m = 2; $m -le [math]::Max($Machines, 2); $m++) {
        if ($m -gt $Packs) { break }
        $per = [math]::Floor($Packs / $m)
        if ($per -lt 1) { break }
        $total = (Get-HpcCoreTotal -Packs $per) * $m
        $label = ('平均分給 ' + $m + ' 台（各 ' + $per + ' 個）')
        $lines += ('  ' + $label.PadRight(18) + ': ' + $total + ' 核  (每台 ' + (Get-HpcCoreTotal -Packs $per) + ')')
        if ($total -gt $best) { $best = $total; $bestLabel = $label }
    }
    $lines += ''
    $lines += ('總核心數最多的配置：' + $bestLabel + '  ' + $best + ' 核')
    $lines += ''
    $lines += 'Electronics Desktop 每份授權內含 4 個 HPC unit，第 5 核起才吃 HPC 授權；'
    $lines += 'HPC Pack 額外開放的核心數為 2 x 4^n，所以集中幾乎一定比分散多。'
    $lines += '會選擇分散通常是因為單台記憶體不夠，而不是因為核心數——這個取捨要客戶自己決定。'

    Add-Finding -Level 'INFO' -Title 'HPC Pack 配置試算' -Detail ($lines -join [Environment]::NewLine) `
        -Ref 'https://www.padtinc.com/2024/02/16/ansys-hpc-licensing-explained/'
}

# ============================================================================
#  進入點分流
# ============================================================================
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $ScriptDir 'reports' }

Write-Host ''
Write-Host ('  ' + $TOOL_NAME + '  v' + $TOOL_VERSION) -ForegroundColor White
Write-Host ('  ' + $VENDOR_NAME) -ForegroundColor DarkGray
Write-Host '  本工具全程唯讀，不會修改任何設定。' -ForegroundColor Green

if ($Merge) {
    $rc = Invoke-MergeMode -Paths $Merge -OutDirectory $OutDir
    exit $rc
}

# ============================================================================
#  節點模式
# ============================================================================
if ([string]::IsNullOrWhiteSpace($CaseId)) {
    $CaseId = $env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmm')
    Write-Host ''
    Write-Host ('  未指定 -CaseId，自動使用 ' + $CaseId) -ForegroundColor Yellow
    Write-Host '  彙整時要靠這個編號確認是同一批機器，建議每台都指定同一個值。' -ForegroundColor Yellow
}

$isAdmin = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

# ---------------------------------------------------------------------------
#  階段 0：本機基本資料
# ---------------------------------------------------------------------------
Write-Head '本機環境'

$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { }
$cs = $null
try { $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop } catch { }
if ($cs -and $cs.Domain) { $script:SensitiveDomains = @([string]$cs.Domain) }

$logicalCores = 0
$physCores    = 0
try {
    foreach ($p in (Get-CimInstance Win32_Processor -ErrorAction Stop)) {
        $logicalCores += [int]$p.NumberOfLogicalProcessors
        $physCores    += [int]$p.NumberOfCores
    }
} catch { $logicalCores = [int]$env:NUMBER_OF_PROCESSORS }

$ramGB = $null
if ($cs -and $cs.TotalPhysicalMemory) { $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1) }

$script:Facts['案件編號']   = $CaseId
$script:Facts['電腦名稱']   = $env:COMPUTERNAME
$script:Facts['使用者']     = $env:USERNAME
$script:Facts['網域／工作群組'] = $(if ($cs) { $cs.Domain } else { '' })
$script:Facts['作業系統']   = $(if ($os) { $os.Caption + ' (' + $os.Version + ')' } else { '' })
$script:Facts['實體核心']   = $physCores
$script:Facts['邏輯核心']   = $logicalCores
$script:Facts['記憶體 GB']  = $ramGB
$script:Facts['系統管理員'] = $(if ($isAdmin) { '是' } else { '否' })
$script:Facts['串機型態']   = $Mode

Write-Step ('電腦名稱  ' + $env:COMPUTERNAME)
Write-Step ('核心／記憶體  ' + $physCores + ' 實體 / ' + $logicalCores + ' 邏輯 / ' + $ramGB + ' GB')

if (-not $isAdmin) {
    Add-Finding -Level 'INFO' -Title '未以系統管理員身分執行' `
        -Detail '服務狀態與防火牆設定在一般權限下有機會讀不到，讀不到時會回報【需人工】而不是「沒有」。' `
        -Fix '要拿到最完整的資料，請以系統管理員身分重跑一次。'
}

# ---------------------------------------------------------------------------
#  階段 1：AEDT 安裝
# ---------------------------------------------------------------------------
Write-Head 'AEDT 安裝'

$installs = Get-AedtInstalls
$aedtJson = @()

if ($installs.Count -eq 0) {
    Add-Finding -Level 'CONFIRMED' -Title '本機沒有偵測到 AEDT' `
        -Detail ('環境變數、登錄檔與常見安裝路徑三個地方都沒有找到 ansysedt.exe。' + [Environment]::NewLine +
                 '這台無法參與串機。') `
        -Fix '安裝與其他機器相同版本、相同路徑的 AEDT。' `
        -FixAction 'align-aedt-version'
    Write-Step '未偵測到 AEDT'
} else {
    $sec = Add-Section 'AEDT 安裝'
    foreach ($i in $installs) {
        Write-Step ($i.Release + '  ' + $i.Root)
        $t = Get-TempDirectorySetting -Root $i.Root
        $loc = $null
        if ($t.TempDir) { $loc = Get-PathLocality -Path $t.TempDir }

        Add-Row $sec ($i.Release + '  ' + $i.Root)
        Add-Row $sec ('    偵測來源  : ' + ($i.Sources -join ', '))
        if ($i.FileVersion) { Add-Row $sec ('    檔案版本  : ' + $i.FileVersion) }
        Add-Row $sec ('    default.cfg: ' + $(if ($t.CfgFound) { $t.CfgPath } else { '(不存在) ' + $t.CfgPath }))
        Add-Row $sec ('    tempdirectory: ' + $(if ($t.TempDir) { $t.TempDir } else { '(未設定，使用內建預設)' }))
        if ($loc) {
            Add-Row $sec ('    temp 位置  : ' + $loc.Kind +
                          $(if ($loc.Exists) { '，存在' } else { '，不存在' }) +
                          $(if ($null -ne $loc.FreeGB) { '，剩餘 ' + $loc.FreeGB + ' GB' } else { '' }))
        }
        Add-Row $sec ''

        if (-not $t.CfgFound) {
            Add-Finding -Level 'MANUAL' -Title ($i.Release + ' 的 default.cfg 不存在') `
                -Detail ('預期位置：' + $t.CfgPath + [Environment]::NewLine +
                         '可能是安裝方式不同或版本差異。本工具因此無法確認 temp 目錄設定。') `
                -Fix '請回傳報告，由我方確認該版本的組態檔位置。'
        } elseif (-not $t.TempDir) {
            Add-Finding -Level 'MANUAL' -Title ($i.Release + ' 沒有明確設定 tempdirectory') `
                -Detail ('default.cfg 存在但沒有 tempdirectory 這一行，代表使用內建預設值。' +
                         [Environment]::NewLine +
                         '串機要求每台的 temp 路徑字串相同，預設值不保證跨機一致。') `
                -Fix ("在 " + $t.CfgPath + " 加入（每台寫同一個值）：" + [Environment]::NewLine +
                      "  tempdirectory='C:\Temp'") `
                -FixAction 'set-temp-directory'
        } else {
            if ($loc.Kind -eq 'unc' -or $loc.Kind -eq 'network') {
                Add-Finding -Level 'CONFIRMED' -Title ($i.Release + ' 的 temp 目錄指向網路位置') `
                    -Detail ('tempdirectory = ' + $t.TempDir + '（判定為 ' + $loc.Kind + '）' + [Environment]::NewLine +
                             'temp 目錄必須「每台路徑字串相同、但各自為本機磁碟」。' + [Environment]::NewLine +
                             '指到共用位置時多台會互相踩到對方的暫存檔。') `
                    -Fix ("改成每台都有的本機路徑，例如 tempdirectory='C:\Temp'") `
                    -FixAction 'set-temp-directory'
            } elseif (-not $loc.Exists) {
                Add-Finding -Level 'CONFIRMED' -Title ($i.Release + ' 的 temp 目錄不存在') `
                    -Detail ('tempdirectory = ' + $t.TempDir + '，但這個路徑在本機找不到。') `
                    -Fix '建立該目錄，並確認跑模擬的帳號有寫入權限。' `
                    -FixAction 'set-temp-directory'
            } elseif ($null -ne $loc.FreeGB -and $loc.FreeGB -lt 50) {
                Add-Finding -Level 'SUSPECT' -Title ($i.Release + ' 的 temp 目錄剩餘空間偏低') `
                    -Detail ('tempdirectory = ' + $t.TempDir + '，剩餘 ' + $loc.FreeGB + ' GB。' +
                             [Environment]::NewLine +
                             'DDM 會在 temp 產生大量中間檔，空間不足會讓求解在中途失敗。' +
                             '多少才夠取決於模型大小，這裡只是提醒。') `
                    -Fix '清理磁碟或把 temp 指到空間較大的本機磁碟（記得每台改成一樣）。'
            }
        }

        $aedtJson += [pscustomobject]@{
            root        = Protect-Text $i.Root
            token       = $i.Token
            release     = $i.Release
            fileVersion = $i.FileVersion
            sources     = $i.Sources
            cfgFound    = $t.CfgFound
            tempDir     = Protect-Text $t.TempDir
            tempKind    = $(if ($loc) { $loc.Kind } else { $null })
            tempExists  = $(if ($loc) { $loc.Exists } else { $null })
            tempFreeGB  = $(if ($loc) { $loc.FreeGB } else { $null })
        }
    }
}

# ---------------------------------------------------------------------------
#  階段 2：RSM
# ---------------------------------------------------------------------------
Write-Head 'RSM 服務'

$rsmSvcs = Get-ServiceLike -Pattern 'RSM'
# 串機必要的環境變數。這些是修復步驟會設的東西，沒設就代表那台沒跑過修復——
# 而症狀不是報錯，是求解卡在「Determining memory availability on distributed machines」
# 那種地方不動，完全看不出跟環境變數有關。
$clusterEnvNames = @('ANSYS_EM_EXEC_DIR', 'ANSYSEM_LISTEN_PORT_RANGE',
                     'I_MPI_PORT_RANGE', 'I_MPI_HYDRA_SERVICE_PORT')
$clusterEnv = [ordered]@{}
foreach ($envName in $clusterEnvNames) {
    $envValue = ''
    try { $envValue = [string][Environment]::GetEnvironmentVariable($envName, 'Machine') } catch { $envValue = '' }
    $clusterEnv[$envName] = (Protect-Text $envValue)
}

$rsmJson = [ordered]@{ installed = $false; running = $false; status = ''; services = @() }

if ($rsmSvcs.Count -eq 0) {
    if ($isAdmin) {
        Add-Finding -Level 'SUSPECT' -Title '沒有偵測到 RSM 服務' `
            -Detail ('找不到名稱或顯示名稱含 RSM 的服務。' + [Environment]::NewLine +
                     '走 RSM 路徑串機時每台都必須註冊；只用排程器或純命令列 MPI 時可以不用。') `
            -Fix '開始 > Ansys Electromagnetics > Ansys Electromagnetics Suite <版本> > Register with RSM。' `
            -FixAction 'register-rsm'
    } else {
        Add-Finding -Level 'MANUAL' -Title '沒有偵測到 RSM 服務（權限不足，結果不可信）' `
            -Detail '一般權限下服務清單可能不完整，不能據此斷定沒有安裝。' `
            -Fix '請以系統管理員身分重跑一次。'
    }
    Write-Step '未偵測到 RSM 服務'
} else {
    $rsmJson.installed = $true
    $sec = Add-Section 'RSM 服務'
    foreach ($s in $rsmSvcs) {
        Write-Step ($s.Name + '  ' + $s.Status)
        Add-Row $sec ($s.Name + '  [' + $s.DisplayName + ']  ' + $s.Status)
        $rsmJson.services += [pscustomobject]@{
            name = $s.Name; displayName = $s.DisplayName; status = [string]$s.Status
        }
        if ($s.Status -eq 'Running') { $rsmJson.running = $true }
    }
    $rsmJson.status = (@($rsmSvcs | ForEach-Object { [string]$_.Status }) -join ',')
    if (-not $rsmJson.running) {
        Add-Finding -Level 'CONFIRMED' -Title 'RSM 服務已安裝但沒有執行' `
            -Detail ('狀態：' + $rsmJson.status + [Environment]::NewLine +
                     '其他機器會連不上本機的 TCP ' + $RsmPort + '。') `
            -Fix '啟動該服務，並把啟動類型設為自動。' `
            -FixAction 'start-rsm-service'
    } else {
        Add-Finding -Level 'OK' -Title 'RSM 服務執行中'
    }
}

# 本機 RSM 埠是否真的在聽
$listening = $false
try {
    $conns = Get-NetTCPConnection -State Listen -LocalPort $RsmPort -ErrorAction Stop
    $listening = (@($conns).Count -gt 0)
} catch {
    try {
        $ns = netstat -ano 2>$null | Select-String (':' + $RsmPort + '\s')
        $listening = (@($ns).Count -gt 0)
    } catch { }
}
$rsmJson.portListening = $listening
$rsmJson.port = $RsmPort
if ($rsmJson.running -and -not $listening) {
    Add-Finding -Level 'SUSPECT' -Title ('RSM 在跑，但本機沒有在聽 TCP ' + $RsmPort) `
        -Detail ('服務狀態是 Running，但找不到監聽中的 ' + $RsmPort + '。' + [Environment]::NewLine +
                 '可能是連接埠被改過（Tools > Options > General Options > Remote Analysis），' +
                 '或服務起來了但初始化失敗。') `
        -Fix ('確認實際使用的連接埠，用 -RsmPort 指定後重跑。')
}

# ---------------------------------------------------------------------------
#  階段 3：MPI
# ---------------------------------------------------------------------------
Write-Head 'MPI'

$mpiDetected = @()

# Intel MPI —— hydra_service
foreach ($s in (Get-ServiceLike -Pattern 'hydra')) {
    $exe = ''
    $ver = ''
    try {
        $wmi = Get-CimInstance Win32_Service -Filter ("Name='" + $s.Name + "'") -ErrorAction Stop
        if ($wmi) { $exe = ($wmi.PathName -replace '^"([^"]+)".*$', '$1') -replace '\s+-\w+$', '' }
    } catch { }
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        try { $ver = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { }
        # 路徑裡常常帶版本號，例如 ...\mpi\intel2021.8.0\...
        if (-not $ver -and $exe -match 'intel[\\\/ ]?(\d+\.\d+[\d\.]*)') { $ver = $Matches[1] }
    }
    $mpiDetected += [pscustomobject]@{
        vendor = 'IntelMPI'; kind = 'service'; name = $s.Name
        status = [string]$s.Status; running = ($s.Status -eq 'Running')
        path = (Protect-Text $exe); version = $ver
    }
    Write-Step ('Intel MPI hydra  ' + $s.Name + '  ' + $s.Status)
}

# Microsoft MPI
$msmpiSvcs = Get-ServiceLike -Pattern 'MsMpi'
$msmpiRoot = $null
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\MPI', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\MPI')) {
    if (Test-Path -LiteralPath $k) {
        try {
            $p = Get-ItemProperty -LiteralPath $k -ErrorAction Stop
            if ($p.InstallRoot) { $msmpiRoot = [string]$p.InstallRoot }
        } catch { }
    }
}
if ($msmpiSvcs.Count -gt 0 -or $msmpiRoot) {
    $running = (@($msmpiSvcs | Where-Object { $_.Status -eq 'Running' }).Count -gt 0)
    $ver = ''
    if ($msmpiRoot) {
        $mp = Join-Path $msmpiRoot 'Bin\mpiexec.exe'
        if (Test-Path -LiteralPath $mp) {
            try { $ver = (Get-Item -LiteralPath $mp).VersionInfo.FileVersion } catch { }
        }
    }
    $mpiDetected += [pscustomobject]@{
        vendor = 'MSMPI'; kind = 'service'
        name = (@($msmpiSvcs | ForEach-Object { $_.Name }) -join ',')
        status = (@($msmpiSvcs | ForEach-Object { [string]$_.Status }) -join ',')
        running = $running; path = (Protect-Text $msmpiRoot); version = $ver
    }
    Write-Step ('Microsoft MPI  ' + $(if ($running) { '執行中' } else { '未執行／僅安裝' }))
    if ($msmpiSvcs.Count -gt 0 -and -not $running) {
        Add-Finding -Level 'SUSPECT' -Title 'MS-MPI 服務已安裝但沒有執行' `
            -Detail ('MsMpiLaunchSvc 沒有在跑，其他機器無法在本機啟動求解行程。') `
            -Fix '啟動該服務並設為自動啟動。'
    }
}

# IBM Platform MPI（舊版流程）
foreach ($s in (Get-ServiceLike -Pattern 'Platform MPI|PCMPI')) {
    $mpiDetected += [pscustomobject]@{
        vendor = 'PlatformMPI'; kind = 'service'; name = $s.Name
        status = [string]$s.Status; running = ($s.Status -eq 'Running')
        path = ''; version = ''
    }
    Write-Step ('IBM Platform MPI  ' + $s.Name + '  ' + $s.Status)
}

# AEDT 自帶的 MPI 執行檔（服務沒裝時仍看得到檔案，判斷「有沒有東西可用」）
$mpiBinaries = @()
foreach ($i in $installs) {
    foreach ($pat in @('common\mpi\*\*\hydra_service.exe', 'common\mpi\*\*\*\hydra_service.exe',
                       'common\mpi\*\*\mpiexec.exe')) {
        foreach ($f in (Get-Item -Path (Join-Path $i.Root $pat) -ErrorAction SilentlyContinue)) {
            $mpiBinaries += (Protect-Text $f.FullName)
        }
    }
}
if ($mpiBinaries.Count -gt 0) {
    $sec = Add-Section 'AEDT 內附的 MPI 執行檔'
    foreach ($b in ($mpiBinaries | Select-Object -Unique)) { Add-Row $sec $b }
}

if ($mpiDetected.Count -eq 0) {
    $lvl = 'SUSPECT'
    $detail = ('沒有找到 Intel MPI hydra_service、Microsoft MPI 或 IBM Platform MPI 的服務。' +
               [Environment]::NewLine)
    if ($mpiBinaries.Count -gt 0) {
        $detail += 'AEDT 安裝目錄裡有 MPI 執行檔，但對應的服務沒有註冊。' + [Environment]::NewLine
    }
    $detail += '純 DSO 分列參數表時不需要 MPI；DDM 或頻點分散一定要。'
    # 權限不足時服務清單可能不完整（Get-Service 會靜默略過讀不到的項目），
    # 不能據此說「沒有 MPI」。RSM 那一段本來就是這樣處理的，這裡要一致——
    # 不一致的話，同一種證據在報告的兩節裡會得到兩種強度的結論。
    if (-not $isAdmin) {
        $lvl = 'MANUAL'
        $detail += [Environment]::NewLine +
                   '本次不是以系統管理員身分執行，服務清單可能不完整，不能據此斷定沒有安裝。'
    }
    # DSO 不需要 MPI，這時連「可疑」都不該報。這一條要放在權限判斷之後，
    # 因為 DSO 模式下就算讀不到也無所謂——本來就不需要。
    if ($Mode -eq 'DSO') {
        $lvl = 'INFO'
        $detail += [Environment]::NewLine + '本次指定 -Mode DSO，所以不列為問題。'
    }
    Add-Finding -Level $lvl -Title '沒有偵測到可用的 MPI 服務' -Detail $detail `
        -Fix ('一般 Windows 多工作站請安裝 AEDT 支援的 Intel MPI，並確認 hydra_service 執行中。' +
              [Environment]::NewLine +
              '在 HPC and Analysis Options > Options 設 MPI Vendor = Intel、MPI Version = Default 或實際安裝版。' +
              [Environment]::NewLine +
              'Microsoft MPI 多主機只支援 Windows HPC Job，不是一般工作站或 VPN 的替代方案。') `
        -FixAction 'install-intel-mpi'
    Write-Step '未偵測到 MPI 服務'
} else {
    $vendors = @($mpiDetected | ForEach-Object { $_.vendor } | Select-Object -Unique)
    Add-Finding -Level 'OK' -Title ('偵測到 MPI：' + ($vendors -join '、'))
    if ($vendors.Count -gt 1) {
        Add-Finding -Level 'INFO' -Title '本機同時存在多種 MPI' `
            -Detail ('偵測到：' + ($vendors -join '、') + [Environment]::NewLine +
                     'AEDT 未指定廠商時預設使用 Microsoft。要用哪一種請在' +
                     ' HPC and Analysis Options > Options 明確指定，不要靠預設。') `
            -Fix '在 HPC and Analysis Options > Options 明確設定 MPI Vendor，每台設成一樣。' `
            -FixAction 'set-mpi-vendor'
    }
    $idle = @($mpiDetected | Where-Object { $_.vendor -eq 'IntelMPI' -and -not $_.running })
    if ($idle.Count -gt 0) {
        Add-Finding -Level 'CONFIRMED' -Title 'Intel MPI 的 hydra_service 沒有執行' `
            -Detail 'Intel MPI 在 Windows 上要求每台的 hydra_service 都安裝且執行中。' `
            -Fix ('以系統管理員身分執行：' + [Environment]::NewLine +
                  '  hydra_service -install' + [Environment]::NewLine +
                  '  hydra_service -start') `
            -FixAction 'start-hydra-service'
    }
}

# MPI 的驗證方式會隨 AEDT 綁定的 Intel MPI 版本而變，不能把舊版命令當成通則。
Add-Finding -Level 'MANUAL' -Title 'MPI 遠端啟動與使用者驗證需要實際測試' `
    -Detail ('本工具不讀取或保存任何帳號密碼。AEDT 2026 R1 Help 沒有把 ' +
             'mpiexec -register／-validate 列為 Intel MPI 2021 的通用步驟。') `
    -Fix ('在每台以實際執行 AEDT 的帳號確認 mpiexec 來源與版本，再依該版本說明設定驗證：' +
          [Environment]::NewLine +
          '  Get-Command mpiexec.exe -All' + [Environment]::NewLine +
          '  mpiexec.exe -help' + [Environment]::NewLine +
          '最後以小模型的單機雙程序與雙機求解證明遠端程序能啟動。') `
    -FixAction 'register-mpi-credential'

# ---------------------------------------------------------------------------
#  階段 4：網路與防火牆
# ---------------------------------------------------------------------------
Write-Head '網路與防火牆'

$adapters = Get-ActiveAdapters
$adapterJson = @()
$sec = Add-Section '網路介面'
foreach ($a in $adapters) {
    $nk = Get-NetworkKey -IPv4 $a.IPv4 -PrefixLen $a.PrefixLen
    $tag = if ($a.IsVirtual) { '  [虛擬／VPN]' } else { '' }
    Add-Row $sec ($a.Alias + '  ' + $a.IPv4 +
                  $(if ($a.PrefixLen) { '/' + $a.PrefixLen } else { '' }) +
                  $(if ($a.Gateway) { '  gw ' + $a.Gateway } else { '' }) + $tag)
    $adapterJson += [pscustomobject]@{
        alias = (Protect-Text $a.Alias); description = (Protect-Text $a.Desc)
        ipv4 = (Protect-Text $a.IPv4); prefixLength = $a.PrefixLen
        gateway = (Protect-Text $a.Gateway); isVirtual = $a.IsVirtual
        network = $(if ($nk) { $nk.Key } else { $null })
        networkGuessed = $(if ($nk) { $nk.Guessed } else { $null })
    }
}
$realAdapters = @($adapters | Where-Object { -not $_.IsVirtual })
Write-Step ('有效介面 ' + $adapters.Count + ' 個，其中判定為實體 ' + $realAdapters.Count + ' 個')

if ($adapters.Count -eq 0) {
    Add-Finding -Level 'MANUAL' -Title '讀不到任何有 IPv4 位址的網路介面' `
        -Detail '本工具兩種取得方式都失敗了，網路相關的判斷全部不可信。' `
        -Fix '請回傳報告。'
} elseif ($realAdapters.Count -gt 1) {
    Add-Finding -Level 'SUSPECT' -Title '本機有多個實體網路介面在使用中' `
        -Detail (('  ' + ((@($realAdapters | ForEach-Object { $_.Alias + ' ' + $_.IPv4 })) -join
                  ([Environment]::NewLine + '  '))) + [Environment]::NewLine +
                 'AEDT 串機要求每台只有一個有效網路在同一網段。多網卡時 MPI 可能挑到錯的介面。') `
        -Fix '串機測試期間停用不需要的介面；確認可以跑之後再逐項恢復。' `
        -FixAction 'fix-network-topology'
}
$virtual = @($adapters | Where-Object { $_.IsVirtual })
if ($virtual.Count -gt 0) {
    Add-Finding -Level 'INFO' -Title ('本機有 ' + $virtual.Count + ' 個虛擬或 VPN 介面') `
        -Detail (('  ' + ((@($virtual | ForEach-Object { $_.Alias + ' ' + $_.IPv4 })) -join
                  ([Environment]::NewLine + '  '))) + [Environment]::NewLine +
                 '判定是靠名稱樣式比對，可能有漏。請確認主機名稱解析到預期介面。' +
                 '不要因為使用 VPN 就改用 Microsoft MPI；Microsoft MPI 多主機只支援 Windows HPC Job。')
}

# 主機名稱能不能解析回自己
$selfAddrs = Resolve-HostAddresses -Name $env:COMPUTERNAME
$localIps  = @($adapters | ForEach-Object { $_.IPv4 })
$selfOk    = (@($selfAddrs | Where-Object { $localIps -contains $_ }).Count -gt 0)
if ($selfAddrs.Count -eq 0) {
    Add-Finding -Level 'CONFIRMED' -Title '本機名稱無法解析為 IP' `
        -Detail ($env:COMPUTERNAME + ' 解析不到任何 IPv4 位址。串機要求主機名稱可正確解析。') `
        -Fix '請網管確認 DNS，或在各機的 hosts 檔加入對應。'
} elseif (-not $selfOk) {
    Add-Finding -Level 'SUSPECT' -Title '本機名稱解析到的位址不在本機介面清單裡' `
        -Detail ('解析結果：' + (Protect-Text ($selfAddrs -join '、')) + [Environment]::NewLine +
                 '本機介面：' + (Protect-Text ($localIps -join '、')) + [Environment]::NewLine +
                 'MPI 可能因此連到錯的位址。') `
        -Fix '清掉過期的 DNS 或 hosts 記錄，確認名稱解析到要用來串機的那張網卡。'
}

# 防火牆
$fwProfiles = @()
$anyOff = $false
try {
    foreach ($p in (Get-NetFirewallProfile -ErrorAction Stop)) {
        $fwProfiles += [pscustomobject]@{ name = [string]$p.Name; enabled = [bool]$p.Enabled }
        if (-not $p.Enabled) { $anyOff = $true }
    }
} catch { }
if ($fwProfiles.Count -gt 0) {
    $sec = Add-Section '防火牆設定檔'
    foreach ($p in $fwProfiles) { Add-Row $sec ($p.name + ' : ' + $(if ($p.enabled) { '啟用' } else { '關閉' })) }
    if ($anyOff) {
        Add-Finding -Level 'INFO' -Title '有防火牆設定檔是關閉的' `
            -Detail ('正式設定應啟用防火牆並加入 AEDT、RSM、Intel Hydra 與 MPI 通訊例外。' +
                     '暫時停用防火牆只適合在特定連線錯誤下隔離原因，不是標準前置步驟。')
    }
} else {
    Add-Finding -Level 'MANUAL' -Title '讀不到防火牆設定' `
        -Detail '可能是權限不足或這台沒有 Windows 防火牆模組。無法判斷 32958 是否被擋。'
}

# 有沒有針對串機開的規則
#
# $fwRuleReadable 是關鍵：規則列舉在一般權限下可能整個讀不到，
# 而「讀不到」與「沒有這條規則」是兩件完全不同的事。
# 不分開的話，權限不足會被講成「防火牆沒放行」——這正是最貴的錯法：
# 客戶明明設好了，我們叫他去改一個本來就對的東西。
# 現場驗證清單 A6 要求的就是這一條。
$fwRuleHits = @()
$fwRuleReadable = $true
if ($fwProfiles.Count -gt 0) {
    # 規則先一次抓回來建索引，不要每個 filter 都 pipe 一次 Get-NetFirewallRule。
    # 每 pipe 一次就是一次完整查詢，數量一多就爆。
    # 實測（開發機，1122 條規則、80 個符合的 filter）：
    #   逐條 pipe          44.9 秒
    #   一次抓回來建索引     4.2 秒
    # 節點收集的預算是 60 秒（現場驗證清單 A9），光這一段就吃掉大半。
    # filter 的 InstanceID 等於 rule 的 Name／InstanceID，可以直接對。
    $ruleById = @{}
    try {
        foreach ($rr in (Get-NetFirewallRule -ErrorAction Stop)) {
            if ($rr.InstanceID) { $ruleById[[string]$rr.InstanceID] = $rr }
        }
    } catch { $fwRuleReadable = $false }

    try {
        foreach ($f in (Get-NetFirewallPortFilter -ErrorAction Stop)) {
            if (@($f.LocalPort) -contains ([string]$RsmPort)) {
                $rr = $ruleById[[string]$f.InstanceID]
                if ($rr -and $rr.Enabled -and $rr.Direction -eq 'Inbound') {
                    $fwRuleHits += ('埠 ' + $RsmPort + ' : ' + $rr.DisplayName)
                }
            }
        }
    } catch { $fwRuleReadable = $false }
    try {
        foreach ($f in (Get-NetFirewallApplicationFilter -ErrorAction Stop)) {
            if ($f.Program -and $f.Program -match 'ansysedt|hydra_service|mpiexec|smpd') {
                $rr = $ruleById[[string]$f.InstanceID]
                if ($rr -and $rr.Enabled -and $rr.Direction -eq 'Inbound') {
                    $fwRuleHits += ('程式 : ' + $rr.DisplayName)
                }
            }
        }
    } catch { $fwRuleReadable = $false }
    $fwRuleHits = @($fwRuleHits | Select-Object -Unique)
    if ($fwRuleHits.Count -gt 0) {
        $sec = Add-Section '與串機相關的輸入防火牆規則'
        foreach ($h in $fwRuleHits) { Add-Row $sec $h }
    } elseif (-not $fwRuleReadable) {
        Add-Finding -Level 'MANUAL' -Title '讀不到防火牆規則清單，無法判斷有沒有放行' `
            -Detail ('防火牆設定檔讀得到，但規則清單列舉失敗' +
                     $(if (-not $isAdmin) { '（本次不是以系統管理員身分執行）' } else { '' }) + '。' +
                     [Environment]::NewLine +
                     '這裡「讀不到」不等於「沒有放行」，所以不做任何判斷。') `
            -Fix ('以系統管理員身分重跑一次；或自行確認 TCP ' + $RsmPort +
                  '（AnsoftRSMService）與所選 MPI 用的埠是否已放行。')
    } elseif (-not $anyOff) {
        Add-Finding -Level 'SUSPECT' -Title ('防火牆啟用中，但沒看到放行 ' + $RsmPort + ' 或 AEDT 的輸入規則') `
            -Detail ('沒有找到相關規則不代表一定被擋（可能有涵蓋範圍更大的規則），' +
                     '但這是連不上時的第一嫌疑。') `
            -Fix ('放行 TCP ' + $RsmPort + '（AnsoftRSMService）以及所選 MPI 用的埠。' + [Environment]::NewLine +
                  '初次測試可先整個關掉確認能通，再逐條收緊。') `
            -FixAction 'add-cluster-firewall'
    }
}

# ---------------------------------------------------------------------------
#  階段 5：對端連通性
# ---------------------------------------------------------------------------
$peerJson = @()
if ($Peers -and $Peers.Count -gt 0) {
    Write-Head '對端連通性'
    $myNets = @($adapterJson | Where-Object { -not $_.isVirtual } | ForEach-Object { $_.network })
    foreach ($p in $Peers) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $addrs = Resolve-HostAddresses -Name $p
        $tcp   = Test-TcpPort -Target $p -Port $RsmPort
        $sameNet = $false
        foreach ($a in $addrs) {
            $nk = Get-NetworkKey -IPv4 $a -PrefixLen $(if ($realAdapters.Count -gt 0) { $realAdapters[0].PrefixLen } else { $null })
            if ($nk -and ($myNets -contains $nk.Key)) { $sameNet = $true }
        }
        Write-Step ($p + '  ' + $(if ($tcp.Ok) { 'TCP ' + $RsmPort + ' OK' } else { 'TCP ' + $RsmPort + ' 失敗' }) +
                    '  ' + $(if ($addrs.Count -gt 0) { $addrs -join ',' } else { '(名稱無法解析)' }))

        $peerJson += [pscustomobject]@{
            target = (Protect-Text $p); resolved = @($addrs | ForEach-Object { Protect-Text $_ })
            tcpOk = $tcp.Ok; tcpReason = $tcp.Reason; sameSubnet = $sameNet; port = $RsmPort
        }

        if ($addrs.Count -eq 0) {
            Add-Finding -Level 'CONFIRMED' -Title ($p + ' 的名稱無法解析') `
                -Detail '串機要求主機名稱可正確解析為 IP。' `
                -Fix '請網管確認 DNS，或在各機的 hosts 檔加入對應。'
        } elseif ($addrs.Count -gt 1) {
            Add-Finding -Level 'SUSPECT' -Title ($p + ' 解析到多個位址') `
                -Detail ('解析結果：' + (Protect-Text ($addrs -join '、')) + [Environment]::NewLine +
                         '對方有多張網卡時，MPI 可能連到不是拿來串機的那一張。') `
                -Fix '讓每台只保留一個有效網段，或在 hosts 檔明確指定要用的位址。' `
                -FixAction 'fix-network-topology'
        }
        if (-not $tcp.Ok -and $addrs.Count -gt 0) {
            Add-Finding -Level 'CONFIRMED' -Title ('連不上 ' + $p + ' 的 TCP ' + $RsmPort) `
                -Detail ('原因：' + $tcp.Reason + [Environment]::NewLine +
                         'TCP ' + $RsmPort + ' 是 AnsoftRSMService 的連接埠。') `
                -Fix ('依序確認：' + [Environment]::NewLine +
                      '  1. ' + $p + ' 的 RSM 服務在跑' + [Environment]::NewLine +
                      '  2. ' + $p + ' 的防火牆放行 TCP ' + $RsmPort + [Environment]::NewLine +
                      '  3. 連接埠沒有被改過（Tools > Options > General Options > Remote Analysis）') `
                -FixAction 'add-cluster-firewall' -FixOn $p
        } elseif ($tcp.Ok -and $addrs.Count -gt 0 -and -not $sameNet -and $myNets.Count -gt 0) {
            Add-Finding -Level 'SUSPECT' -Title ($p + ' 連得上，但看起來不在同一網段') `
                -Detail ('對方位址：' + (Protect-Text ($addrs -join '、')) + [Environment]::NewLine +
                         '本機網段：' + (Protect-Text ($myNets -join '、')) + [Environment]::NewLine +
                         '遮罩長度取不到時本工具以 /24 推測，這個判斷可能失準。') `
                -Fix '跨網段串機需要網管確認路由與延遲；DDM 對網路延遲特別敏感。'
        }
    }
} else {
    Add-Finding -Level 'MANUAL' -Title '沒有做連通性測試' `
        -Detail '沒有指定 -Peers，所以完全不知道這台跟其他機器之間能不能連上。' `
        -Fix '重跑一次並列出其他機器，例如：-Peers WS02,WS03'
}

# ---------------------------------------------------------------------------
#  階段 6：HPC Pack 試算與授權提醒
# ---------------------------------------------------------------------------
if ($HpcPacks -gt 0) {
    $machineCount = 1
    if ($Peers) { $machineCount = 1 + @($Peers | Where-Object { $_ }).Count }
    Add-HpcPackFinding -Packs $HpcPacks -Machines $machineCount
}

Add-Finding -Level 'INFO' -Title '授權面請另外用 License 診斷工具確認' `
    -Detail ('本工具不查 License。HPC Pack 夠不夠、anshpc 有沒有被借光，' +
             '請在同一台跑 Check-AnsysLicense.ps1 -Product HFSS。')

# ---------------------------------------------------------------------------
#  階段 7：輸出
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeCase = ($CaseId -replace '[^\w\-\.]', '_')
$safePc   = ((Protect-Text $env:COMPUTERNAME) -replace '[^\w\-\.]', '_')
$baseName = 'AedtCluster_' + $safeCase + '_' + $safePc + '_' + $stamp

$txtPath = Write-Reports -BaseName $baseName -OutDirectory $OutDir -Title '節點檢查報告' -Case $CaseId

# --- 節點 JSON（彙整模式的輸入，一定要輸出）---
$nodeBlock = [ordered]@{
    computerName = (Protect-Text $env:COMPUTERNAME)
    userName     = (Protect-Text $env:USERNAME)
    domain       = $(if ($cs) { Protect-Text ([string]$cs.Domain) } else { '' })
    os           = $(if ($os) { [string]$os.Caption } else { '' })
    osCaption    = $(if ($os) { [string]$os.Caption } else { '' })
    osVersion    = $(if ($os) { [string]$os.Version } else { '' })
    osBuildNumber= $(if ($os) { [string]$os.BuildNumber } else { '' })
    isAdmin      = $isAdmin
    mode         = $Mode
    physicalCores= $physCores
    logicalCores = $logicalCores
    memoryGB     = $ramGB
    collectedAt  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    aedt         = @($aedtJson)
    rsm          = $rsmJson
    clusterEnv   = [pscustomobject]$clusterEnv
    mpi          = [ordered]@{ detected = @($mpiDetected); binaries = @($mpiBinaries | Select-Object -Unique) }
    adapters     = @($adapterJson)
    selfResolve  = @($selfAddrs | ForEach-Object { Protect-Text $_ })
    firewall     = [ordered]@{
                       profiles = @($fwProfiles)
                       anyProfileOff = $anyOff
                       clusterRules = @($fwRuleHits)
                   }
    peerProbes   = @($peerJson)
}

$nodePath = Join-Path $OutDir ($baseName + '.node.json')
$payload  = Get-FindingsPayload -Case $CaseId -Extra @{ node = [pscustomobject]$nodeBlock }
try {
    $jsonText = $payload | ConvertTo-Json -Depth 10
    (Protect-Text $jsonText) | Out-File -FilePath $nodePath -Encoding utf8 -Force
} catch {
    Write-Host ('  節點 JSON 輸出失敗：' + $_.Exception.Message) -ForegroundColor Red
    $nodePath = $null
}

$jsonPath = $null
if ($Json -and $nodePath) {
    # -Json 要的是不含 node 區塊的精簡版，給解決包產生器吃
    $jsonPath = Join-Path $OutDir ($baseName + '.findings.json')
    try {
        $jsonText = (Get-FindingsPayload -Case $CaseId) | ConvertTo-Json -Depth 8
        (Protect-Text $jsonText) | Out-File -FilePath $jsonPath -Encoding utf8 -Force
    } catch { $jsonPath = $null }
}

Write-Host ('=' * 60) -ForegroundColor White
Write-Host '  節點報告已產生' -ForegroundColor Green
Write-Host ''
if ($txtPath)  { Write-Host ('    ' + $txtPath) }
if ($nodePath) { Write-Host ('    ' + $nodePath) }
if ($jsonPath) { Write-Host ('    ' + $jsonPath) }
Write-Host ''
Write-Host '  下一步：在其他每一台也跑一次（用同一個 -CaseId），' -ForegroundColor Cyan
Write-Host '  把所有 .node.json 收到同一個資料夾後執行：' -ForegroundColor Cyan
Write-Host ''
Write-Host ('    .\Test-AedtCluster.ps1 -Merge ' + $OutDir) -ForegroundColor White
Write-Host ''
Write-Host '  跨機比對才是這支工具的重點——版本、路徑、temp、網段不一致，' -ForegroundColor Cyan
Write-Host '  單機自己看永遠看不出來。' -ForegroundColor Cyan
Write-Host ''
Write-Host '  本工具全程唯讀，未修改本機任何設定。' -ForegroundColor Green
Write-Host ''
