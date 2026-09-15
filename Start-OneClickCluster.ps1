#Requires -Version 5.1
<#
.SYNOPSIS
    AEDT 兩台電腦一鍵串機精靈 —— 虎門科技股份有限公司

.DESCRIPTION
    現場用。兩台各開一次、各按一次「開始」，工具自己完成：

      1. 前置檢查（帳號型態、AEDT、權限）
      2. 對端連通（名稱解析、SMB、RSM 埠）
      3. 本機節點檢查
      4. 交換兩台的節點報告（走網路共用，失敗時退回 USB 模式）
      5. 跨機彙整比對
      6. 修復（需要系統管理員）
      7. Intel MPI 帳密註冊
      8. 雙機驗證
      9. 產生 machines.txt 與批次命令（只有主控機做）

    案件編號由兩台的電腦名稱自動推導，兩台會算出同一個，現場不必輸入也不會對不起來。

    第一台跑到步驟 4 時對端還沒有資料是正常的，工具會停在那裡並告訴你去另一台按一次；
    回來再按一次「開始」就會從能繼續的地方接下去。

.PARAMETER PairHosts
    已知的兩台機器名稱，例：-PairHosts HOSTA,HOSTB
    工具會看自己是哪一台，自動把「另一台」填進去，現場連打字都不用。
    本機不在名單裡時會明講，不會默默用錯的對端跑下去。

.PARAMETER LibraryOnly
    只載入函式不開視窗，給單元測試用。
#>
[CmdletBinding()]
param(
    [string[]] $PairHosts = @(),
    [switch]   $LibraryOnly
)

$ErrorActionPreference = 'Stop'

$TOOL_NAME    = 'AEDT 一鍵串機精靈'
$TOOL_VERSION = '1.0.0'
$VENDOR_NAME  = '虎門科技股份有限公司'

# ============================================================================
#  純邏輯區（無副作用，可單元測試）
# ============================================================================

function Test-HostNameFormat {
    <# 電腦名稱或 IP 的格式檢查。擋掉會被塞進命令列的怪字元。 #>
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9.\-]{0,62}$')
}

function Test-AsciiText {
    param([string] $Value)
    if ($null -eq $Value) { return $false }
    foreach ($character in $Value.ToCharArray()) {
        if ([int][char]$character -gt 127) { return $false }
    }
    return $true
}

function Quote-Argument {
    param([string] $Value)
    if ($Value -match '"') { throw '輸入值不可包含雙引號。' }
    return '"' + $Value + '"'
}

function New-PairCaseId {
    <#
        兩台各自算，結果必須相同——所以排序後接起來，不能用時間戳。
        現場因此不必輸入案件編號，也不會發生兩台編號不同導致彙整拒收的情形。
    #>
    param(
        [Parameter(Mandatory = $true)][string] $LocalName,
        [Parameter(Mandatory = $true)][string] $PeerName
    )
    $clean = {
        param($value)
        $text = ($value -replace '[^A-Za-z0-9]', '')
        if ($text.Length -gt 20) { $text = $text.Substring(0, 20) }
        return $text.ToUpperInvariant()
    }
    $a = & $clean $LocalName
    $b = & $clean $PeerName
    if ([string]::IsNullOrWhiteSpace($a)) { $a = 'NODEA' }
    if ([string]::IsNullOrWhiteSpace($b)) { $b = 'NODEB' }
    $pair = @($a, $b) | Sort-Object
    return ('PAIR-' + $pair[0] + '-' + $pair[1])
}

function Resolve-PeerFromPair {
    <#
        給定兩台機器的名單，回傳「不是本機的那一台」。
        同一個啟動器因此可以在兩台上各用一次，不必做兩個版本、也不必打字。

        本機不在名單裡時回傳空字串——這種情況必須讓人看到，
        默默挑一台當對端會讓人以為跑對了，其實是在測錯的機器。

        自己做逗號切分，不能依賴 PowerShell 幫忙：用 powershell -File 啟動時，
        參數一律當成字串傳，「HOSTA,HOSTB」會變成「一個」字串而不是兩個元素。
        這個差異不會報錯，只會讓自動帶入靜靜地不作用。
    #>
    param(
        [string[]] $PairHosts = @(),
        [string]   $LocalName = $env:COMPUTERNAME
    )
    $flat = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @($PairHosts)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        foreach ($piece in ($entry -split '[,;]')) { $flat.Add($piece) }
    }
    $list = @($flat | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($list.Count -lt 2) { return '' }
    $lower  = "$LocalName".ToLowerInvariant()
    $others = @($list | Where-Object { $_.ToLowerInvariant() -ne $lower })
    if ($others.Count -eq $list.Count) { return '' }   # 本機不在名單裡
    if ($others.Count -lt 1) { return '' }             # 名單裡兩個都是自己
    return $others[0]
}

function Get-LocalAccountKind {
    <#
        判斷目前登入帳號是本機帳號、Microsoft 帳戶、Azure AD 還是網域帳號。

        Microsoft 帳戶是現場最常見的地雷：它在 Windows 裡仍然是一個本機帳號，
        whoami 看起來很正常，但密碼是雲端密碼，兩台不可能設成一致，
        Intel MPI 的 -register/-validate 因此必定失敗，而錯誤訊息長得像網路問題。

        PrincipalSourceOverride 是給測試注入用的；不注入時才真的去問 Get-LocalUser。
    #>
    param(
        [string] $UserName     = $env:USERNAME,
        [string] $ComputerName = $env:COMPUTERNAME,
        [string] $UserDomain   = $env:USERDOMAIN,
        [object] $PrincipalSourceOverride = $null
    )
    if ($UserDomain -and $ComputerName -and ($UserDomain -ne $ComputerName)) {
        return 'Domain'
    }
    $source = $PrincipalSourceOverride
    if ($null -eq $source) {
        $command = Get-Command -Name 'Get-LocalUser' -ErrorAction SilentlyContinue
        if ($command) {
            try { $source = (Get-LocalUser -Name $UserName -ErrorAction Stop).PrincipalSource } catch { $source = $null }
        }
    }
    switch ([string]$source) {
        'MicrosoftAccount' { return 'MicrosoftAccount' }
        'AzureAd'          { return 'AzureAd' }
        'Local'            { return 'Local' }
        default            { return 'Unknown' }
    }
}

function Get-AccountKindLabel {
    param([string] $Kind)
    switch ($Kind) {
        'Local'            { return '本機帳戶' }
        'MicrosoftAccount' { return 'Microsoft 帳戶' }
        'AzureAd'          { return 'Azure AD／公司帳戶' }
        'Domain'           { return '網域帳戶' }
        default            { return '無法判斷' }
    }
}

function Get-AccountCompatibility {
    <#
        比對兩台的帳號能不能撐起 Intel MPI 的跨機認證。

        回傳 Level：
          OK     —— 可以往下做
          BLOCK  —— 現在做下去一定失敗，先修帳號
          MANUAL —— 資料不足，要人工確認
    #>
    param(
        [string] $LocalKind,
        [string] $LocalUser,
        [string] $PeerKind   = '',
        [string] $PeerUser   = '',
        [string] $LocalDomain = '',
        [string] $PeerDomain  = ''
    )
    $cloudKinds = @('MicrosoftAccount', 'AzureAd')

    if ($cloudKinds -contains $LocalKind) {
        return [pscustomobject]@{
            Level   = 'BLOCK'
            Summary = ('本機登入的是「' + (Get-AccountKindLabel $LocalKind) + '」，Intel MPI 跨機認證無法使用。')
            Advice  = @(
                '在「兩台」上各建立一個同名、同密碼的本機系統管理員帳號（例：ansys）：',
                '  1. 設定 > 帳戶 > 其他使用者 > 新增帳戶',
                '  2. 選「我沒有這位人員的登入資訊」→「新增沒有 Microsoft 帳戶的使用者」',
                '  3. 兩台的帳號名稱與密碼必須逐字相同，並設為「系統管理員」',
                '  4. 兩台都改用這個帳號登入，再重新執行本工具',
                '理由：沒有網域時，Intel MPI 用本機帳密做跨機認證；Microsoft 帳戶的密碼在雲端，兩台無法設成一致。'
            )
        }
    }
    if ($PeerKind -and ($cloudKinds -contains $PeerKind)) {
        return [pscustomobject]@{
            Level   = 'BLOCK'
            Summary = ('對端登入的是「' + (Get-AccountKindLabel $PeerKind) + '」，Intel MPI 跨機認證無法使用。')
            Advice  = @('請依同樣步驟在兩台各建立同名同密碼的本機系統管理員帳號後重跑。')
        }
    }
    if ($LocalKind -eq 'Domain') {
        if ($PeerKind -and $PeerKind -ne 'Domain') {
            return [pscustomobject]@{
                Level   = 'BLOCK'
                Summary = '本機是網域帳戶但對端不是，兩台認證來源不同。'
                Advice  = @('請讓兩台都用同一個網域帳號登入，或都改用同名同密碼的本機帳號。')
            }
        }
        if ($LocalDomain -and $PeerDomain -and
            ($LocalDomain.ToLowerInvariant() -ne $PeerDomain.ToLowerInvariant())) {
            # 兩台都「在網域裡」但不是同一個網域。這種組合在畫面上看起來完全正常，
            # 一路做到第 8 步才會失敗，而且訊息長得像網路問題。
            return [pscustomobject]@{
                Level   = 'BLOCK'
                Summary = ('兩台在不同的網域：本機 ' + $LocalDomain + '、對端 ' + $PeerDomain + '。')
                Advice  = @(
                    '對端要能認得你送過去的帳密，兩台必須屬於同一個網域（或有互信關係）。',
                    '請改用同一個網域的帳號登入兩台，或改用同名同密碼的本機系統管理員帳號。'
                )
            }
        }
        return [pscustomobject]@{
            Level   = 'OK'
            Summary = '兩台都是網域帳戶，可直接做 Intel MPI 帳密註冊。'
            Advice  = @(
                '網域帳號不必兩台同名——對端是拿你送過去的帳密去登入，不看它自己登入的是誰。',
                '但求解當下兩台都要連得到網域控制站，帶出公司就可能驗不過。'
            )
        }
    }
    if ($LocalKind -eq 'Local') {
        if (-not $PeerKind) {
            return [pscustomobject]@{
                Level   = 'MANUAL'
                Summary = ('本機是本機帳戶「' + $LocalUser + '」；對端資料尚未取得。')
                Advice  = @('請到另一台也執行一次本工具，取得對端帳號資訊後才能確認是否一致。')
            }
        }
        if ($PeerKind -ne 'Local') {
            return [pscustomobject]@{
                Level   = 'BLOCK'
                Summary = '本機是本機帳戶，對端不是，兩台認證來源不同。'
                Advice  = @('請讓兩台都改用同名同密碼的本機系統管理員帳號。')
            }
        }
        if ($LocalUser -and $PeerUser -and ($LocalUser.ToLowerInvariant() -ne $PeerUser.ToLowerInvariant())) {
            return [pscustomobject]@{
                Level   = 'BLOCK'
                Summary = ('兩台的本機帳號名稱不同：本機「' + $LocalUser + '」、對端「' + $PeerUser + '」。')
                Advice  = @(
                    '在兩台各建立一個同名、同密碼的本機系統管理員帳號（例：ansys），兩台都改用它登入後重跑。',
                    '只改名稱不夠——密碼也必須逐字相同。'
                )
            }
        }
        return [pscustomobject]@{
            Level   = 'OK'
            Summary = ('兩台都是本機帳戶「' + $LocalUser + '」。名稱一致。')
            Advice  = @('工具無法驗證兩台的密碼是否相同。稍後的 Intel MPI 驗證若失敗，第一個要懷疑的就是密碼不一致。')
        }
    }
    return [pscustomobject]@{
        Level   = 'MANUAL'
        Summary = '無法判斷本機帳號型態。'
        Advice  = @('請人工確認兩台是否使用同名同密碼的本機帳號，或同一個網域帳號。')
    }
}

function Get-ExchangeShareCandidates {
    <#
        交換資料夾的候選路徑，依序嘗試。
        C$ 是 Windows 內建的管理共用，不必在客戶機器上開新的共用；
        能不能寫進去本身就是「兩台帳密一致」的好指標。
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Peer,
        [string] $CaseId = ''
    )
    $tail = 'AnsysWork\MpiToolkit\exchange'
    if ($CaseId) { $tail = $tail + '\' + $CaseId }
    return @(
        ('\\' + $Peer + '\C$\' + $tail),
        ('\\' + $Peer + '\MpiExchange\' + $CaseId).TrimEnd('\')
    )
}

function Get-LocalExchangePath {
    param([string] $CaseId = '')
    $base = 'C:\AnsysWork\MpiToolkit\exchange'
    if ($CaseId) { return (Join-Path $base $CaseId) }
    return $base
}

function New-NodeIdentityRecord {
    <#
        放進交換資料夾的小卡片：對端靠它比對帳號與 AEDT 是否一致。
        刻意不含密碼、不含任何憑證。
    #>
    param(
        [string] $ComputerName,
        [string] $UserName,
        [string] $AccountKind,
        [string] $UserDomain,
        [bool]   $IsAdministrator,
        [string] $AedtRoot = '',
        [string] $AedtVersion = '',
        [string] $Role = '',
        [string] $CaseId = ''
    )
    return [pscustomobject]@{
        schema          = 1
        caseId          = $CaseId
        computerName    = $ComputerName
        userName        = $UserName
        userDomain      = $UserDomain
        accountKind     = $AccountKind
        isAdministrator = $IsAdministrator
        aedtRoot        = $AedtRoot
        aedtVersion     = $AedtVersion
        role            = $Role
        toolVersion     = $TOOL_VERSION
        writtenAt       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz')
    }
}

function Get-StepStatusGlyph {
    param([string] $Status)
    switch ($Status) {
        'Pass'    { return '✓' }
        'Warn'    { return '△' }
        'Fail'    { return '✗' }
        'Wait'    { return '…' }
        'Skip'    { return '—' }
        'Running' { return '▶' }
        default   { return '·' }
    }
}

function Resolve-OverallOutcome {
    <#
        把各步驟狀態收斂成一句現場看得懂的結論。
        只要有 Fail 就是紅；沒有 Fail 但有 Wait 就是「還有一台沒做」。
    #>
    param([object[]] $Statuses)
    $list = @($Statuses | Where-Object { $_ })
    if ($list -contains 'Fail') { return 'Fail' }
    if ($list -contains 'Wait') { return 'Wait' }
    if ($list -contains 'Warn') { return 'Warn' }
    if ($list -contains 'Pass') { return 'Pass' }
    return 'Pending'
}

if ($LibraryOnly) { return }

# ============================================================================
#  執行期輔助（有副作用）
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Busy     = $false

# 攤平一次就好。-File 模式會把 "HOSTA,HOSTB" 當成單一字串送進來，
# 直接對它數 Count 會得到 1，自動帶入就會靜靜地不作用。
$script:PairList = @()
foreach ($pairEntry in @($PairHosts)) {
    if ([string]::IsNullOrWhiteSpace($pairEntry)) { continue }
    $script:PairList += @(($pairEntry -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-IsAdministrator {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-AedtInstallInfo {
    <# 三條線索：環境變數、登錄檔、檔案系統。任一條找到就算。 #>
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('ANSYSEM_ROOT251', 'ANSYSEM_ROOT252', 'ANSYSEM_ROOT261', 'ANSYSEM_ROOT262', 'ANSYS_EM_EXEC_DIR')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
        if ($value -and (Test-Path -LiteralPath $value)) { $roots.Add($value) }
    }
    foreach ($base in @('C:\Program Files\AnsysEM', 'C:\Program Files\ANSYS Inc')) {
        if (Test-Path -LiteralPath $base) {
            Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidate = Join-Path $_.FullName 'Win64\ansysedt.exe'
                if (Test-Path -LiteralPath $candidate) { $roots.Add((Split-Path -Parent $candidate)) }
            }
        }
    }
    $unique = @($roots | Select-Object -Unique)
    $version = ''
    if ($unique.Count -gt 0) {
        try {
            $exe = Join-Path $unique[0] 'ansysedt.exe'
            if (Test-Path -LiteralPath $exe) {
                $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
            }
        } catch { $version = '' }
    }
    return [pscustomobject]@{
        Found   = ($unique.Count -gt 0)
        Root    = $(if ($unique.Count -gt 0) { $unique[0] } else { '' })
        All     = $unique
        Version = $version
    }
}

function Write-Log {
    param([string] $Text, [string] $Color = '')
    if ([string]::IsNullOrEmpty($Text)) { return }
    $logBox.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
    [Windows.Forms.Application]::DoEvents()
}

function Set-StepStatus {
    param([int] $Index, [string] $Status, [string] $Detail = '')
    if ($Index -lt 0 -or $Index -ge $stepList.Items.Count) { return }
    $item = $stepList.Items[$Index]
    $item.SubItems[0].Text = Get-StepStatusGlyph $Status
    $item.SubItems[2].Text = $Detail
    $script:StepStatus[$Index] = $Status
    switch ($Status) {
        'Pass'    { $item.ForeColor = [Drawing.Color]::FromArgb(0, 110, 60) }
        'Warn'    { $item.ForeColor = [Drawing.Color]::FromArgb(170, 105, 0) }
        'Fail'    { $item.ForeColor = [Drawing.Color]::FromArgb(178, 34, 34) }
        'Wait'    { $item.ForeColor = [Drawing.Color]::FromArgb(38, 89, 130) }
        'Running' { $item.ForeColor = [Drawing.Color]::FromArgb(0, 82, 155) }
        default   { $item.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90) }
    }
    $stepList.Refresh()
    [Windows.Forms.Application]::DoEvents()
}

function Invoke-ChildScript {
    <#
        跑一支子腳本並把輸出倒進畫面。等待期間持續 DoEvents，視窗才不會變成白色未回應。
        逾時就殺掉——現場沒有人有耐心猜它是在跑還是掛了。
    #>
    param(
        [Parameter(Mandatory = $true)][string] $ScriptName,
        [string[]] $Arguments = @(),
        [int] $TimeoutSeconds = 900
    )
    $scriptPath = Join-Path $script:ToolRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Write-Log ('  找不到 ' + $ScriptName + '，請重新解壓縮完整工具。')
        return [pscustomobject]@{ ExitCode = -1; Output = '' }
    }
    $stdout = [IO.Path]::GetTempFileName()
    $stderr = [IO.Path]::GetTempFileName()
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Argument $scriptPath)
    if ($Arguments.Count -gt 0) { $argLine = $argLine + ' ' + ($Arguments -join ' ') }
    $exitCode = -1
    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argLine `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
            if ((Get-Date) -gt $deadline) {
                try { $process.Kill() } catch { }
                Write-Log ('  ' + $ScriptName + ' 超過 ' + $TimeoutSeconds + ' 秒沒有結束，已中止。')
                break
            }
        }
        if ($process.HasExited) { $exitCode = $process.ExitCode }
    } catch {
        Write-Log ('  執行 ' + $ScriptName + ' 失敗：' + $_.Exception.Message)
        return [pscustomobject]@{ ExitCode = -1; Output = '' }
    }
    $text = ''
    foreach ($file in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $file) {
            $content = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
            if ($content) { $text = $text + $content }
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim()) { Write-Log ('    ' + $line.TrimEnd()) }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $text }
}

# ============================================================================
#  步驟實作
# ============================================================================

function Step-Preflight {
    param([hashtable] $State)
    Write-Log '── 步驟 1：前置檢查 ───────────────────────────'
    $State.LocalName   = $env:COMPUTERNAME
    $State.UserName    = $env:USERNAME
    $State.UserDomain  = $env:USERDOMAIN
    $State.AccountKind = Get-LocalAccountKind
    $State.IsAdmin     = Test-IsAdministrator
    $aedt = Get-AedtInstallInfo
    $State.AedtRoot    = $aedt.Root
    $State.AedtVersion = $aedt.Version

    Write-Log ('  本機名稱：' + $State.LocalName)
    Write-Log ('  登入帳號：' + $State.UserName + '（' + (Get-AccountKindLabel $State.AccountKind) + '）')
    Write-Log ('  系統管理員：' + $(if ($State.IsAdmin) { '是' } else { '否（步驟 6 會另外要求提權）' }))
    if ($aedt.Found) {
        Write-Log ('  AEDT：' + $aedt.Root + $(if ($aedt.Version) { '（' + $aedt.Version + '）' } else { '' }))
    } else {
        Write-Log '  AEDT：找不到安裝。這台不能當求解節點。'
    }

    $compat = Get-AccountCompatibility -LocalKind $State.AccountKind -LocalUser $State.UserName
    $State.AccountCompat = $compat
    Write-Log ('  帳號判定：' + $compat.Summary)
    foreach ($line in $compat.Advice) { Write-Log ('    ' + $line) }

    if (-not $aedt.Found) { return @{ Status = 'Fail'; Detail = '找不到 AEDT 安裝' } }
    if ($compat.Level -eq 'BLOCK') { return @{ Status = 'Fail'; Detail = $compat.Summary } }
    if ($compat.Level -eq 'MANUAL') { return @{ Status = 'Warn'; Detail = '帳號待與對端比對' } }
    return @{ Status = 'Pass'; Detail = ($State.UserName + ' / ' + (Get-AccountKindLabel $State.AccountKind)) }
}

function Step-PeerReach {
    param([hashtable] $State)
    Write-Log '── 步驟 2：對端連通 ───────────────────────────'
    $peer = $State.Peer
    $resolved = $null
    try {
        $resolved = [Net.Dns]::GetHostEntry($peer)
        $addresses = @($resolved.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
        Write-Log ('  名稱解析：' + $peer + ' → ' + ($addresses -join ', '))
        $State.PeerResolvedName = $resolved.HostName
        $State.PeerAddresses = $addresses
    } catch {
        Write-Log ('  名稱解析失敗：' + $_.Exception.Message)
        Write-Log '    對策：改填對端的 IP，或在兩台的 hosts 檔互相加上對方。'
        return @{ Status = 'Fail'; Detail = '名稱解析失敗' }
    }

    $rsmOk = $false
    try {
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect($peer, 32958, $null, $null)
        $rsmOk = $async.AsyncWaitHandle.WaitOne(4000, $false) -and $client.Connected
        $client.Close()
    } catch { $rsmOk = $false }
    Write-Log ('  對端 RSM TCP 32958：' + $(if ($rsmOk) { '通' } else { '不通（對端還沒修復過就會這樣，屬正常）' }))
    $State.PeerRsmOpen = $rsmOk

    $shareOk = $false
    foreach ($candidate in (Get-ExchangeShareCandidates -Peer $peer)) {
        $root = Split-Path -Parent (Split-Path -Parent $candidate)
        try {
            if (Test-Path -LiteralPath $root) { $shareOk = $true; $State.PeerShareRoot = $candidate; break }
        } catch { }
    }
    if (-not $shareOk) {
        try {
            if (Test-Path -LiteralPath ('\\' + $peer + '\C$')) {
                $shareOk = $true
                $State.PeerShareRoot = (Get-ExchangeShareCandidates -Peer $peer)[0]
            }
        } catch { }
    }
    $State.ShareAvailable = $shareOk
    if ($shareOk) {
        Write-Log ('  網路共用：可存取 \\' + $peer + '\C$，交換報告走網路。')
        return @{ Status = 'Pass'; Detail = '解析 + 共用皆通' }
    }
    Write-Log ('  網路共用：無法存取 \\' + $peer + '\C$，改用 USB 模式。')
    Write-Log '    註：工作群組環境下存取 C$ 失敗，通常就是兩台帳號名稱或密碼不一致——'
    Write-Log '    這與 Intel MPI 跨機認證的要求是同一件事，請一併確認。'
    return @{ Status = 'Warn'; Detail = '共用不通，改 USB 模式' }
}

function Step-NodeCheck {
    param([hashtable] $State)
    Write-Log '── 步驟 3：本機節點檢查 ───────────────────────'
    $outDir = $State.LocalReportDir
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $arguments = @(
        '-CaseId', (Quote-Argument $State.CaseId),
        '-Peers',  (Quote-Argument $State.Peer),
        '-Mode',   'DDM',
        '-Json',
        '-OutDir', (Quote-Argument $outDir)
    )
    $result = Invoke-ChildScript -ScriptName 'Test-AedtCluster.ps1' -Arguments $arguments -TimeoutSeconds 600
    $nodeFile = Get-ChildItem -LiteralPath $outDir -Filter '*.node.json' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $nodeFile) {
        return @{ Status = 'Fail'; Detail = '沒有產生 .node.json' }
    }
    $State.LocalNodeFile = $nodeFile.FullName
    Write-Log ('  本機節點報告：' + $nodeFile.FullName)
    if ($result.ExitCode -ge 2) { return @{ Status = 'Warn'; Detail = '檢查有【確定】等級問題，見上方輸出' } }
    if ($result.ExitCode -eq 1) { return @{ Status = 'Warn'; Detail = '檢查有【可疑】項目' } }
    return @{ Status = 'Pass'; Detail = '節點報告已產生' }
}

function Step-Exchange {
    param([hashtable] $State)
    Write-Log '── 步驟 4：交換兩台的節點報告 ─────────────────'
    $mergeDir = $State.MergeDir
    if (-not (Test-Path -LiteralPath $mergeDir)) { New-Item -ItemType Directory -Path $mergeDir -Force | Out-Null }

    # 本機的先放進本機收件匣，對端才拉得到
    $localInbox = Get-LocalExchangePath -CaseId $State.CaseId
    if (-not (Test-Path -LiteralPath $localInbox)) { New-Item -ItemType Directory -Path $localInbox -Force | Out-Null }
    Copy-Item -LiteralPath $State.LocalNodeFile -Destination $localInbox -Force
    Copy-Item -LiteralPath $State.LocalNodeFile -Destination $mergeDir -Force

    $identity = New-NodeIdentityRecord -ComputerName $State.LocalName -UserName $State.UserName `
        -AccountKind $State.AccountKind -UserDomain $State.UserDomain -IsAdministrator ([bool]$State.IsAdmin) `
        -AedtRoot $State.AedtRoot -AedtVersion $State.AedtVersion -Role $State.Role -CaseId $State.CaseId
    $identityPath = Join-Path $localInbox ($State.LocalName + '.identity.json')
    ($identity | ConvertTo-Json -Depth 5) | Out-File -FilePath $identityPath -Encoding utf8 -Force
    Write-Log ('  本機交換資料夾：' + $localInbox)

    $pulled = 0
    if ($State.ShareAvailable) {
        $peerInbox = '\\' + $State.Peer + '\C$\AnsysWork\MpiToolkit\exchange\' + $State.CaseId
        # 順便把本機的推過去，對端就算還沒開工具也拿得到
        try {
            if (-not (Test-Path -LiteralPath $peerInbox)) { New-Item -ItemType Directory -Path $peerInbox -Force | Out-Null }
            Copy-Item -LiteralPath $State.LocalNodeFile -Destination $peerInbox -Force
            Copy-Item -LiteralPath $identityPath -Destination $peerInbox -Force
            Write-Log ('  已把本機報告推到 ' + $peerInbox)
        } catch {
            Write-Log ('  推送到對端失敗：' + $_.Exception.Message)
        }
        try {
            if (Test-Path -LiteralPath $peerInbox) {
                Get-ChildItem -LiteralPath $peerInbox -Filter '*.node.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notlike ($State.LocalName + '*') } |
                    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $mergeDir -Force; $pulled++ }
                $peerIdentity = Get-ChildItem -LiteralPath $peerInbox -Filter '*.identity.json' -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.BaseName -notlike ($State.LocalName + '*') } | Select-Object -First 1
                if ($peerIdentity) {
                    $record = Get-Content -LiteralPath $peerIdentity.FullName -Raw | ConvertFrom-Json
                    $State.PeerIdentity = $record
                    Write-Log ('  對端帳號：' + $record.userName + '（' + (Get-AccountKindLabel $record.accountKind) + '）')
                    $compat = Get-AccountCompatibility -LocalKind $State.AccountKind -LocalUser $State.UserName `
                        -PeerKind $record.accountKind -PeerUser $record.userName `
                        -LocalDomain $State.UserDomain -PeerDomain ([string]$record.userDomain)
                    $State.AccountCompat = $compat
                    Write-Log ('  帳號比對：' + $compat.Summary)
                    foreach ($line in $compat.Advice) { Write-Log ('    ' + $line) }
                    if ($compat.Level -eq 'BLOCK') {
                        return @{ Status = 'Fail'; Detail = $compat.Summary }
                    }
                }
            }
        } catch {
            Write-Log ('  從對端取回失敗：' + $_.Exception.Message)
        }
    } else {
        Write-Log '  USB 模式：請把下面這個資料夾整個複製到另一台的同一個位置，兩台各按一次「開始」。'
        Write-Log ('    ' + $localInbox)
        Write-Log ('    對端也做完後，把對端的 .node.json 放進：' + $mergeDir)
    }

    $count = @(Get-ChildItem -LiteralPath $mergeDir -Filter '*.node.json' -File -ErrorAction SilentlyContinue).Count
    Write-Log ('  目前彙整資料夾內有 ' + $count + ' 份節點報告。')
    if ($count -lt 2) {
        Write-Log ''
        Write-Log '  ▶ 下一步：到另一台開同一支工具、填本機名稱當對端，按一次「開始」。'
        Write-Log '    然後回到這台再按一次「開始」，會自動接下去。'
        return @{ Status = 'Wait'; Detail = '等待對端執行（目前只有 1 份）' }
    }
    return @{ Status = 'Pass'; Detail = ($count.ToString() + ' 份節點報告已就位') }
}

function Step-Merge {
    param([hashtable] $State)
    Write-Log '── 步驟 5：跨機彙整比對 ───────────────────────'
    $outDir = $State.OutDir
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $arguments = @('-Merge', (Quote-Argument $State.MergeDir), '-Json', '-OutDir', (Quote-Argument $outDir))
    $result = Invoke-ChildScript -ScriptName 'Test-AedtCluster.ps1' -Arguments $arguments -TimeoutSeconds 300
    if ($result.ExitCode -lt 0) { return @{ Status = 'Fail'; Detail = '彙整未能執行' } }
    if ($result.ExitCode -ge 2) { return @{ Status = 'Warn'; Detail = '彙整發現【確定】等級不一致，見上方輸出' } }
    if ($result.ExitCode -eq 1) { return @{ Status = 'Warn'; Detail = '彙整有【可疑】項目' } }
    return @{ Status = 'Pass'; Detail = '兩台一致' }
}

function Step-Repair {
    param([hashtable] $State)
    Write-Log '── 步驟 6：修復（需要系統管理員）─────────────'
    $scriptPath = Join-Path $script:ToolRoot 'Repair-AedtClusterNode.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return @{ Status = 'Fail'; Detail = '找不到 Repair-AedtClusterNode.ps1' }
    }
    $reportPath = Join-Path $State.OutDir 'repair'
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
               (Quote-Argument $scriptPath) +
               ' -TempDirectory ' + (Quote-Argument 'C:\AnsysWork\AedtTemp') +
               ' -ReportDirectory ' + (Quote-Argument $reportPath) +
               ' -Peer ' + (Quote-Argument $State.Peer) +
               ' -ConfigureNetworkPorts'
    Write-Log '  即將跳出 UAC，請按「是」。修復內容：'
    Write-Log '    統一 tempdirectory 為 C:\AnsysWork\AedtTemp（自動備份 default.cfg）'
    Write-Log '    設定 RSM MPI 需要的 ANSYS_EM_EXEC_DIR'
    Write-Log '    啟動並驗證 Electromagnetics RSM 與 Intel Hydra'
    Write-Log '    建立只放行 LocalSubnet 的防火牆規則（不會關閉防火牆）'
    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argLine `
            -Verb RunAs -WindowStyle Hidden -PassThru
        while (-not $process.HasExited) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        $code = $process.ExitCode
    } catch {
        Write-Log ('  提權失敗或使用者取消：' + $_.Exception.Message)
        return @{ Status = 'Fail'; Detail = '未取得系統管理員權限' }
    }
    Write-Log ('  修復結束，代碼 ' + $code + '。報告：' + $reportPath)
    if ($code -eq 0) { return @{ Status = 'Pass'; Detail = '修復完成' } }
    return @{ Status = 'Warn'; Detail = ('修復回傳 ' + $code + '，請看 repair 報告') }
}

function Step-MpiCredential {
    param([hashtable] $State)
    Write-Log '── 步驟 7：Intel MPI 帳密註冊 ─────────────────'
    Write-Log '  會跳出 Intel MPI 自己的視窗要你輸入「目前這個 Windows 帳號」的名稱與密碼。'
    Write-Log '  本工具不接收、不保存、不記錄密碼，也不會把它放進命令列或報告。'
    $scriptPath = Join-Path $script:ToolRoot 'Register-IntelMpiCredential.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        return @{ Status = 'Fail'; Detail = '找不到 Register-IntelMpiCredential.ps1' }
    }
    $argLine = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + (Quote-Argument $scriptPath) +
               ' -Peer ' + (Quote-Argument $State.Peer)
    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $argLine -PassThru
        while (-not $process.HasExited) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
        }
        $code = $process.ExitCode
    } catch {
        return @{ Status = 'Fail'; Detail = ('無法啟動帳密註冊：' + $_.Exception.Message) }
    }
    if ($code -eq 0) { return @{ Status = 'Pass'; Detail = '帳密已註冊' } }
    return @{ Status = 'Warn'; Detail = ('註冊回傳 ' + $code + '，稍後的驗證會再確認一次') }
}

function Step-Verify {
    param([hashtable] $State)
    Write-Log '── 步驟 8：雙機驗證 ───────────────────────────'
    $result = Invoke-ChildScript -ScriptName 'Register-IntelMpiCredential.ps1' `
        -Arguments @('-Peer', (Quote-Argument $State.Peer), '-VerifyOnly') -TimeoutSeconds 300
    if ($result.ExitCode -eq 0) { return @{ Status = 'Pass'; Detail = 'MPI 帳密、RSM、Hydra、兩節點 hostname 全通' } }
    Write-Log '  驗證沒過。依現場經驗，先查這三件事：'
    Write-Log '    1. 兩台的本機帳號名稱與密碼是否逐字相同'
    Write-Log '    2. 對端的 Electromagnetics RSM 與 Intel Hydra 服務是否在跑（去對端跑一次步驟 6）'
    Write-Log '    3. 對端防火牆是否放行（步驟 6 會建規則，但要在對端那一台執行才算數）'
    return @{ Status = 'Fail'; Detail = ('驗證回傳 ' + $result.ExitCode) }
}

function Step-BuildConfig {
    param([hashtable] $State)
    Write-Log '── 步驟 9：產生機器清單與批次命令 ─────────────'
    if ($State.Role -ne 'Primary') {
        Write-Log '  這台是協力節點，不產生機器清單。請在主控機執行這一步。'
        return @{ Status = 'Skip'; Detail = '協力節點不需要' }
    }
    $configOut = Join-Path $State.OutDir 'cluster-config'
    $arguments = @('-From', (Quote-Argument $State.MergeDir), '-OutDir', (Quote-Argument $configOut))
    if ($State.ProjectPath) { $arguments += @('-Project', (Quote-Argument $State.ProjectPath)) }
    $result = Invoke-ChildScript -ScriptName 'New-AedtClusterConfig.ps1' -Arguments $arguments -TimeoutSeconds 180
    if ($result.ExitCode -lt 0) { return @{ Status = 'Fail'; Detail = '設定產生失敗' } }
    if ($result.ExitCode -eq 3) {
        # 離開碼 3 = 有節點報告讀不到。機器清單還是會產生，但可能少一台，
        # 而少一台的清單看起來完全正常——所以這裡不能報成功。
        Write-Log '  有節點報告讀不到，機器清單可能少了機器。請看待辦清單，確認檔案完整後重跑這一步。'
        return @{ Status = 'Fail'; Detail = '有節點報告讀不到，清單可能少機器' }
    }
    if ($result.ExitCode -ne 0) { return @{ Status = 'Warn'; Detail = ('設定產生回傳 ' + $result.ExitCode) } }
    $State.ConfigDir = $configOut
    Write-Log ('  輸出：' + $configOut)
    Write-Log '  第一次使用前請先跑 verify-batchoptions.cmd 確認選項拼法，再解開 run-batch.cmd 的註解。'
    return @{ Status = 'Pass'; Detail = $configOut }
}

# ============================================================================
#  視窗
# ============================================================================

$form = New-Object Windows.Forms.Form
$form.Text = $TOOL_NAME
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(1000, 780)
$form.MinimumSize = New-Object Drawing.Size(820, 660)
$form.BackColor = [Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Object Drawing.Font('Microsoft JhengHei', 10)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 88
$header.BackColor = [Drawing.Color]::FromArgb(20, 49, 82)
$form.Controls.Add($header)

$title = New-Object Windows.Forms.Label
$title.Text = '兩台電腦一鍵串機'
$title.ForeColor = [Drawing.Color]::White
$title.Font = New-Object Drawing.Font('Microsoft JhengHei', 20, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(24, 14); $title.AutoSize = $true
$header.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = '兩台各按一次「開始」即可。不關閉防火牆、不保存密碼、不自動送出求解。'
$subtitle.ForeColor = [Drawing.Color]::FromArgb(205, 220, 236)
$subtitle.Location = New-Object Drawing.Point(27, 55); $subtitle.AutoSize = $true
$header.Controls.Add($subtitle)

$hostLabel = New-Object Windows.Forms.Label
$hostLabel.Text = '本機：' + $env:COMPUTERNAME
$hostLabel.ForeColor = [Drawing.Color]::White
$hostLabel.AutoSize = $true
$hostLabel.Anchor = 'Top, Right'
$hostLabel.Location = New-Object Drawing.Point(760, 22)
$header.Controls.Add($hostLabel)

$pairLabel = New-Object Windows.Forms.Label
$pairLabel.ForeColor = [Drawing.Color]::FromArgb(255, 214, 102)
$pairLabel.AutoSize = $true
$pairLabel.Anchor = 'Top, Right'
$pairLabel.Location = New-Object Drawing.Point(760, 48)
$pairLabel.Visible = $false
$header.Controls.Add($pairLabel)

$inputPanel = New-Object Windows.Forms.Panel
$inputPanel.Location = New-Object Drawing.Point(18, 100)
$inputPanel.Size = New-Object Drawing.Size(964, 118)
$inputPanel.Anchor = 'Top, Left, Right'
$inputPanel.BackColor = [Drawing.Color]::White
$form.Controls.Add($inputPanel)

$peerLabel = New-Object Windows.Forms.Label
$peerLabel.Text = '另一台的電腦名稱或 IP'
$peerLabel.Location = New-Object Drawing.Point(20, 20)
$peerLabel.Size = New-Object Drawing.Size(200, 28)
$inputPanel.Controls.Add($peerLabel)

$peerBox = New-Object Windows.Forms.TextBox
$peerBox.Location = New-Object Drawing.Point(224, 16)
$peerBox.Size = New-Object Drawing.Size(320, 30)
$peerBox.Font = New-Object Drawing.Font('Calibri', 12)
$inputPanel.Controls.Add($peerBox)

$testPeerButton = New-Object Windows.Forms.Button
$testPeerButton.Text = '測試這個名稱'
$testPeerButton.Location = New-Object Drawing.Point(556, 15)
$testPeerButton.Size = New-Object Drawing.Size(140, 32)
$inputPanel.Controls.Add($testPeerButton)

$peerHint = New-Object Windows.Forms.Label
$peerHint.Text = '在另一台的「設定 > 系統」最上方可以看到它的電腦名稱。'
$peerHint.Location = New-Object Drawing.Point(706, 21)
$peerHint.Size = New-Object Drawing.Size(240, 40)
$peerHint.ForeColor = [Drawing.Color]::FromArgb(110, 110, 110)
$peerHint.Anchor = 'Top, Left, Right'
$inputPanel.Controls.Add($peerHint)

$roleLabel = New-Object Windows.Forms.Label
$roleLabel.Text = '這台的角色'
$roleLabel.Location = New-Object Drawing.Point(20, 64)
$roleLabel.Size = New-Object Drawing.Size(200, 28)
$inputPanel.Controls.Add($roleLabel)

$primaryRadio = New-Object Windows.Forms.RadioButton
$primaryRadio.Text = '主控（我要在這台開 AEDT 送求解）'
$primaryRadio.Location = New-Object Drawing.Point(224, 62)
$primaryRadio.Size = New-Object Drawing.Size(330, 30)
$primaryRadio.Checked = $true
$inputPanel.Controls.Add($primaryRadio)

$secondaryRadio = New-Object Windows.Forms.RadioButton
$secondaryRadio.Text = '協力（這台只出核心與記憶體）'
$secondaryRadio.Location = New-Object Drawing.Point(560, 62)
$secondaryRadio.Size = New-Object Drawing.Size(300, 30)
$inputPanel.Controls.Add($secondaryRadio)

$stepList = New-Object Windows.Forms.ListView
$stepList.Location = New-Object Drawing.Point(18, 228)
$stepList.Size = New-Object Drawing.Size(964, 232)
$stepList.Anchor = 'Top, Left, Right'
$stepList.View = 'Details'
$stepList.FullRowSelect = $true
$stepList.GridLines = $false
$stepList.HeaderStyle = 'Nonclickable'
$stepList.Columns.Add('', 44) | Out-Null
$stepList.Columns.Add('步驟', 300) | Out-Null
$stepList.Columns.Add('結果', 596) | Out-Null
$form.Controls.Add($stepList)

$stepDefinitions = @(
    @{ Name = '1. 前置檢查（帳號、AEDT、權限）'; Action = 'Step-Preflight' },
    @{ Name = '2. 對端連通（解析、共用、RSM 埠）'; Action = 'Step-PeerReach' },
    @{ Name = '3. 本機節點檢查';                   Action = 'Step-NodeCheck' },
    @{ Name = '4. 交換兩台的節點報告';             Action = 'Step-Exchange' },
    @{ Name = '5. 跨機彙整比對';                   Action = 'Step-Merge' },
    @{ Name = '6. 修復（系統管理員）';             Action = 'Step-Repair' },
    @{ Name = '7. Intel MPI 帳密註冊';             Action = 'Step-MpiCredential' },
    @{ Name = '8. 雙機驗證';                       Action = 'Step-Verify' },
    @{ Name = '9. 產生機器清單與批次命令';         Action = 'Step-BuildConfig' }
)
$script:StepStatus = @{}
foreach ($definition in $stepDefinitions) {
    $item = New-Object Windows.Forms.ListViewItem('·')
    $item.SubItems.Add($definition.Name) | Out-Null
    $item.SubItems.Add('') | Out-Null
    $item.ForeColor = [Drawing.Color]::FromArgb(90, 90, 90)
    $stepList.Items.Add($item) | Out-Null
}

$startButton = New-Object Windows.Forms.Button
$startButton.Text = '開始'
$startButton.Location = New-Object Drawing.Point(18, 470)
$startButton.Size = New-Object Drawing.Size(220, 54)
$startButton.BackColor = [Drawing.Color]::FromArgb(0, 103, 184)
$startButton.ForeColor = [Drawing.Color]::White
$startButton.FlatStyle = 'Flat'
$startButton.Font = New-Object Drawing.Font('Microsoft JhengHei', 13, [Drawing.FontStyle]::Bold)
$form.Controls.Add($startButton)

$openOutputButton = New-Object Windows.Forms.Button
$openOutputButton.Text = '開啟報告資料夾'
$openOutputButton.Location = New-Object Drawing.Point(250, 478)
$openOutputButton.Size = New-Object Drawing.Size(170, 40)
$openOutputButton.Enabled = $false
$form.Controls.Add($openOutputButton)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Location = New-Object Drawing.Point(436, 480)
$statusLabel.Size = New-Object Drawing.Size(546, 44)
$statusLabel.Anchor = 'Top, Left, Right'
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(38, 89, 130)
$statusLabel.Text = '填入另一台的電腦名稱後按「開始」。'
$form.Controls.Add($statusLabel)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(18, 534)
$logBox.Size = New-Object Drawing.Size(964, 208)
$logBox.Anchor = 'Top, Bottom, Left, Right'
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.BackColor = [Drawing.Color]::FromArgb(252, 252, 252)
$logBox.Font = New-Object Drawing.Font('Consolas', 9.5)
$form.Controls.Add($logBox)

$testPeerButton.Add_Click({
    $peer = $peerBox.Text.Trim()
    if (-not (Test-HostNameFormat $peer)) {
        [Windows.Forms.MessageBox]::Show($form, '請輸入正確的電腦名稱或 IP（只能有英數、點與連字號）。', '請修正輸入',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    try {
        $entry = [Net.Dns]::GetHostEntry($peer)
        $addresses = @($entry.AddressList | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
        Write-Log ('名稱測試：' + $peer + ' → ' + $entry.HostName + '（' + ($addresses -join ', ') + '）')
        $statusLabel.Text = '對端名稱可以解析，可以按「開始」。'
    } catch {
        Write-Log ('名稱測試失敗：' + $_.Exception.Message)
        $statusLabel.Text = '這個名稱解析不出來。改填 IP，或確認兩台在同一個網段。'
    }
})

$openOutputButton.Add_Click({
    if ($script:State -and $script:State.OutDir -and (Test-Path -LiteralPath $script:State.OutDir)) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-Argument $script:State.OutDir) | Out-Null
    }
})

$startButton.Add_Click({
    if ($script:Busy) { return }
    $peer = $peerBox.Text.Trim()
    if (-not (Test-HostNameFormat $peer)) {
        [Windows.Forms.MessageBox]::Show($form, '請先填入另一台的電腦名稱或 IP。', '請修正輸入',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($peer -eq $env:COMPUTERNAME) {
        [Windows.Forms.MessageBox]::Show($form, '對端不能填自己的電腦名稱。', '請修正輸入',
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    $script:Busy = $true
    $startButton.Enabled = $false
    $logBox.Clear()

    $caseId = New-PairCaseId -LocalName $env:COMPUTERNAME -PeerName $peer
    $base   = Join-Path $script:ToolRoot ('oneclick\' + $caseId)
    $script:State = @{
        Peer           = $peer
        CaseId         = $caseId
        Role           = $(if ($primaryRadio.Checked) { 'Primary' } else { 'Secondary' })
        LocalReportDir = (Join-Path $base 'local')
        MergeDir       = (Join-Path $base 'merge')
        OutDir         = (Join-Path $base 'out')
        ProjectPath    = ''
    }
    Write-Log ($TOOL_NAME + '  v' + $TOOL_VERSION + '   ' + $VENDOR_NAME)
    Write-Log ('案件編號（兩台會算出同一個）：' + $caseId)
    Write-Log ('工作資料夾：' + $base)
    Write-Log ''

    for ($index = 0; $index -lt $stepDefinitions.Count; $index++) { Set-StepStatus -Index $index -Status 'Pending' -Detail '' }

    $stopped = $false
    for ($index = 0; $index -lt $stepDefinitions.Count; $index++) {
        if ($stopped) { Set-StepStatus -Index $index -Status 'Skip' -Detail '前一步未過，未執行'; continue }
        Set-StepStatus -Index $index -Status 'Running' -Detail '執行中…'
        $statusLabel.Text = '執行中：' + $stepDefinitions[$index].Name
        [Windows.Forms.Application]::DoEvents()
        $outcome = $null
        try {
            $outcome = & $stepDefinitions[$index].Action $script:State
        } catch {
            Write-Log ('  步驟發生例外：' + $_.Exception.Message)
            $outcome = @{ Status = 'Fail'; Detail = $_.Exception.Message }
        }
        if ($null -eq $outcome) { $outcome = @{ Status = 'Warn'; Detail = '沒有回傳結果' } }
        Set-StepStatus -Index $index -Status $outcome.Status -Detail $outcome.Detail
        Write-Log ''
        if ($outcome.Status -eq 'Fail' -or $outcome.Status -eq 'Wait') { $stopped = $true }
    }

    $overall = Resolve-OverallOutcome -Statuses @($script:StepStatus.Values)
    switch ($overall) {
        'Pass' { $statusLabel.Text = '全部通過。可以在主控機開 AEDT，用 cluster-config 裡的機器清單送求解。' }
        'Warn' { $statusLabel.Text = '大致完成，但有需要注意的項目。請看上方清單標成 △ 的那幾列。' }
        'Wait' { $statusLabel.Text = '請到另一台執行一次（對端填本機名稱），回來再按一次「開始」。' }
        'Fail' { $statusLabel.Text = '卡住了。看上方標成 ✗ 的那一列，以及下方輸出的處理建議。' }
        default { $statusLabel.Text = '流程結束。' }
    }
    Write-Log '─────────────────────────────────────────────'
    Write-Log ('結論：' + $statusLabel.Text)
    Write-Log 'AEDT 沒有被本工具關閉或啟動；求解命令也沒有被自動送出。'

    $openOutputButton.Enabled = $true
    $startButton.Enabled = $true
    $script:Busy = $false
})

$form.Add_Shown({
    $form.Activate()
    Write-Log ($TOOL_NAME + '  v' + $TOOL_VERSION)
    Write-Log ''
    Write-Log '用法：兩台各開一次這支工具，各自填「另一台」的電腦名稱，各按一次「開始」。'
    Write-Log '第一台會停在步驟 4 等對端；第二台做完後回到第一台再按一次「開始」就會接下去。'
    Write-Log ''

    if ($script:PairList.Count -ge 2) {
        $pairText = ($script:PairList -join ' ↔ ')
        $pairLabel.Text = '指定機組：' + $pairText
        $pairLabel.Visible = $true
        $autoPeer = Resolve-PeerFromPair -PairHosts $script:PairList -LocalName $env:COMPUTERNAME
        if ($autoPeer) {
            $peerBox.Text = $autoPeer
            Write-Log ('指定機組：' + $pairText)
            Write-Log ('本機是 ' + $env:COMPUTERNAME + '，已自動把對端填成 ' + $autoPeer + '。直接按「開始」。')
            $statusLabel.Text = '對端已自動填入 ' + $autoPeer + '，直接按「開始」。'
            $startButton.Focus()
        } else {
            # 名字打錯、機器換過、或工具被複製到第三台——三種都會走到這裡，
            # 而且都不能默默挑一台繼續，否則會在錯的機器上跑完九步還以為成功。
            $pairLabel.ForeColor = [Drawing.Color]::FromArgb(178, 34, 34)
            Write-Log ('指定機組是 ' + $pairText + '，但本機叫 ' + $env:COMPUTERNAME + '，不在名單裡。')
            Write-Log '沒有自動填入對端。請確認你是不是在正確的機器上，或自己填對端名稱。'
            $statusLabel.Text = '本機不在指定機組裡，沒有自動填入。請確認機器或自行填寫。'
            $peerBox.Focus()
        }
        Write-Log ''
    } else {
        $peerBox.Focus()
    }
})

[void]$form.ShowDialog()
$form.Dispose()
