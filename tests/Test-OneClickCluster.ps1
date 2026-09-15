#Requires -Version 5.1
<#
    Start-OneClickCluster.ps1 的純邏輯單元測試。

    刻意只測沒有副作用的函式：帳號相容性判定、案件編號推導、交換路徑、結論收斂。
    帳號型態改用參數注入（-PrincipalSourceOverride），不去覆寫 Get-LocalUser——
    PowerShell 的模組自動載入會讓同名函式在載入後失效，而且 Get-Command 還會回報成功。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$testRoot  = Split-Path -Parent $MyInvocation.MyCommand.Path
$toolRoot  = Split-Path -Parent $testRoot
$target    = Join-Path $toolRoot 'Start-OneClickCluster.ps1'

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    Write-Host ('找不到 ' + $target) -ForegroundColor Red
    exit 1
}

. $target -LibraryOnly

$script:Passed = 0
$script:Failed = 0

function Assert-Equal {
    param([string] $Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") {
        $script:Passed++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        $script:Failed++
        Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
        Write-Host ('        預期：' + $Expected) -ForegroundColor DarkGray
        Write-Host ('        實際：' + $Actual) -ForegroundColor DarkGray
    }
}

function Assert-True {
    param([string] $Name, $Condition)
    Assert-Equal -Name $Name -Expected $true -Actual ([bool]$Condition)
}

Write-Host ''
Write-Host '  Start-OneClickCluster 純邏輯測試' -ForegroundColor White
Write-Host ''

# ---- 電腦名稱格式 -----------------------------------------------------------
Write-Host '  Test-HostNameFormat' -ForegroundColor Cyan
Assert-True  '接受一般主機名稱'        (Test-HostNameFormat 'DESKTOP-ABC1234')  # scan-ok: 虛構名稱，非任何實際機器
Assert-True  '接受 IPv4'               (Test-HostNameFormat '10.93.13.12')
Assert-True  '接受 FQDN'               (Test-HostNameFormat 'ws02.corp.local')
Assert-Equal '拒絕空字串'        $false (Test-HostNameFormat '')
Assert-Equal '拒絕含空白'        $false (Test-HostNameFormat 'WS 02')
Assert-Equal '拒絕反斜線注入'    $false (Test-HostNameFormat '\\evil\share')
Assert-Equal '拒絕雙引號'        $false (Test-HostNameFormat 'ws02" -Command bad')
Assert-Equal '拒絕中文'          $false (Test-HostNameFormat '工作站一')

# ---- 案件編號兩台必須一致 ---------------------------------------------------
Write-Host ''
Write-Host '  New-PairCaseId' -ForegroundColor Cyan
$fromA = New-PairCaseId -LocalName 'DESKTOP-XYZ9876' -PeerName 'DESKTOP-ABC1234'  # scan-ok: 虛構名稱
$fromB = New-PairCaseId -LocalName 'DESKTOP-ABC1234' -PeerName 'DESKTOP-XYZ9876'  # scan-ok: 虛構名稱
Assert-Equal '兩台各自推導出同一個編號' $fromA $fromB
Assert-True  '編號通過 Test-AedtCluster 的 -CaseId 格式' ($fromA -match '^[A-Za-z0-9._-]+$')
Assert-True  '編號含兩台名稱'           ($fromA -like '*XYZ9876*' -and $fromA -like '*ABC1234*')
$longCase = New-PairCaseId -LocalName ('A' * 40) -PeerName ('B' * 40)
Assert-True  '過長名稱被截斷後仍合法'   ($longCase -match '^[A-Za-z0-9._-]+$')

# ---- 指定機組自動帶入對端 ---------------------------------------------------
Write-Host ''
Write-Host '  Resolve-PeerFromPair' -ForegroundColor Cyan
Assert-Equal '在 NODEA 上自動帶出 NODEB' 'NODEB' (Resolve-PeerFromPair -PairHosts @('NODEA', 'NODEB') -LocalName 'NODEA')
Assert-Equal '在 NODEB 上自動帶出 NODEA' 'NODEA' (Resolve-PeerFromPair -PairHosts @('NODEA', 'NODEB') -LocalName 'NODEB')
Assert-Equal '大小寫不同也認得出自己'    'NODEB' (Resolve-PeerFromPair -PairHosts @('nodea', 'NODEB') -LocalName 'NODEA')
# powershell -File 會把 "NODEA,NODEB" 整串當成一個字串傳進來，不會幫忙拆成陣列。
# 這個差異不報錯，只會讓自動帶入靜靜地不作用，所以一定要有測試釘住。
Assert-Equal '整串逗號字串也要拆得開'    'NODEB' (Resolve-PeerFromPair -PairHosts @('NODEA,NODEB') -LocalName 'NODEA')
Assert-Equal '整串字串在對面那台也要對'  'NODEA' (Resolve-PeerFromPair -PairHosts @('NODEA,NODEB') -LocalName 'NODEB')
Assert-Equal '整串字串但本機不在裡面'    '' (Resolve-PeerFromPair -PairHosts @('NODEA,NODEB') -LocalName 'NODEZ')
Assert-Equal '前後空白不影響'            'NODEB' (Resolve-PeerFromPair -PairHosts @(' NODEA ', ' NODEB ') -LocalName 'NODEA')
# 在第三台上絕對不能挑一台當對端——會在錯的機器上跑完九步還以為成功。
Assert-Equal '本機不在名單裡時不猜'      '' (Resolve-PeerFromPair -PairHosts @('NODEA', 'NODEB') -LocalName 'DESKTOP-OTHER')
Assert-Equal '名單只有一台時不猜'        '' (Resolve-PeerFromPair -PairHosts @('NODEA') -LocalName 'NODEA')
Assert-Equal '名單是空的時候不猜'        '' (Resolve-PeerFromPair -PairHosts @() -LocalName 'NODEA')
Assert-Equal '名單兩個都是自己時不猜'    '' (Resolve-PeerFromPair -PairHosts @('NODEA', 'NODEA') -LocalName 'NODEA')

# ---- 帳號型態判定 -----------------------------------------------------------
Write-Host ''
Write-Host '  Get-LocalAccountKind' -ForegroundColor Cyan
Assert-Equal '網域帳號（USERDOMAIN 不等於電腦名）' 'Domain' `
    (Get-LocalAccountKind -UserName 'jeff' -ComputerName 'WS01' -UserDomain 'CORP')
Assert-Equal 'Microsoft 帳戶' 'MicrosoftAccount' `
    (Get-LocalAccountKind -UserName 'jeff' -ComputerName 'WS01' -UserDomain 'WS01' -PrincipalSourceOverride 'MicrosoftAccount')
Assert-Equal '本機帳戶' 'Local' `
    (Get-LocalAccountKind -UserName 'admin' -ComputerName 'WS01' -UserDomain 'WS01' -PrincipalSourceOverride 'Local')
Assert-Equal 'Azure AD' 'AzureAd' `
    (Get-LocalAccountKind -UserName 'jeff' -ComputerName 'WS01' -UserDomain 'WS01' -PrincipalSourceOverride 'AzureAd')

# ---- 帳號相容性：現場最容易卡住的地方 ---------------------------------------
Write-Host ''
Write-Host '  Get-AccountCompatibility' -ForegroundColor Cyan

$msa = Get-AccountCompatibility -LocalKind 'MicrosoftAccount' -LocalUser 'jeff'
Assert-Equal '本機是 Microsoft 帳戶要擋下來'      'BLOCK' $msa.Level
Assert-True  '並且要給出建立本機帳號的步驟'       ($msa.Advice.Count -gt 0)

$peerMsa = Get-AccountCompatibility -LocalKind 'Local' -LocalUser 'ansys' -PeerKind 'MicrosoftAccount' -PeerUser 'jeff'
Assert-Equal '對端是 Microsoft 帳戶也要擋下來'    'BLOCK' $peerMsa.Level

$nameMismatch = Get-AccountCompatibility -LocalKind 'Local' -LocalUser 'admin' -PeerKind 'Local' -PeerUser 'user'
Assert-Equal '兩台本機帳號不同名要擋下來'          'BLOCK' $nameMismatch.Level

$sameName = Get-AccountCompatibility -LocalKind 'Local' -LocalUser 'ansys' -PeerKind 'Local' -PeerUser 'ANSYS'
Assert-Equal '同名不分大小寫視為一致'              'OK' $sameName.Level
Assert-True  '仍要提醒密碼無法驗證'                ($sameName.Advice.Count -gt 0)

$noPeer = Get-AccountCompatibility -LocalKind 'Local' -LocalUser 'ansys'
Assert-Equal '對端資料還沒到時不下定論'            'MANUAL' $noPeer.Level

$bothDomain = Get-AccountCompatibility -LocalKind 'Domain' -LocalUser 'jeff' -PeerKind 'Domain' -PeerUser 'jeff'
Assert-Equal '兩台都是網域帳號可以往下做'          'OK' $bothDomain.Level

# 網域帳號不必兩台同名：對端是拿送過去的帳密去登入，不看它自己登入的是誰。
# 同事的機器上登著同事的帳號，是正常的，不該被擋。
$domainDiffUser = Get-AccountCompatibility -LocalKind 'Domain' -LocalUser 'jeff' `
    -PeerKind 'Domain' -PeerUser 'amy' -LocalDomain 'CORP' -PeerDomain 'CORP'
Assert-Equal '同網域但兩台登入者不同名仍可以'      'OK' $domainDiffUser.Level

# 但不同網域一定不行。這種組合畫面上看起來完全正常，會一路做到第 8 步才失敗，
# 而且訊息長得像網路問題——所以要在第 1 步就擋。
$crossDomain = Get-AccountCompatibility -LocalKind 'Domain' -LocalUser 'jeff' `
    -PeerKind 'Domain' -PeerUser 'jeff' -LocalDomain 'CORP' -PeerDomain 'OTHERCORP'
Assert-Equal '兩台在不同網域要擋下來'              'BLOCK' $crossDomain.Level
Assert-True  '並且要講出是哪兩個網域'              ($crossDomain.Summary -match 'CORP' -and $crossDomain.Summary -match 'OTHERCORP')

$sameDomainCase = Get-AccountCompatibility -LocalKind 'Domain' -LocalUser 'jeff' `
    -PeerKind 'Domain' -PeerUser 'jeff' -LocalDomain 'corp' -PeerDomain 'CORP'
Assert-Equal '網域名稱大小寫不同視為同一個'        'OK' $sameDomainCase.Level

# 只有一邊拿得到網域名稱時不能下定論——沒有證據就不該擋，也不該說沒問題。
$partialDomain = Get-AccountCompatibility -LocalKind 'Domain' -LocalUser 'jeff' `
    -PeerKind 'Domain' -PeerUser 'jeff' -LocalDomain 'CORP' -PeerDomain ''
Assert-Equal '對端網域不明時不擋'                  'OK' $partialDomain.Level
Assert-True  '網域情況要提醒連得到網域控制站'      (($bothDomain.Advice -join '') -match '網域控制站')

$mixed = Get-AccountCompatibility -LocalKind 'Domain' -LocalUser 'jeff' -PeerKind 'Local' -PeerUser 'ansys'
Assert-Equal '一邊網域一邊本機要擋下來'            'BLOCK' $mixed.Level

$unknown = Get-AccountCompatibility -LocalKind 'Unknown' -LocalUser 'jeff'
Assert-Equal '判不出來時不能講成 OK'               'MANUAL' $unknown.Level

# ---- 交換資料夾路徑 ---------------------------------------------------------
Write-Host ''
Write-Host '  Get-ExchangeShareCandidates / Get-LocalExchangePath' -ForegroundColor Cyan
$candidates = Get-ExchangeShareCandidates -Peer 'WS02' -CaseId 'PAIR-A-B'
Assert-True  '第一順位是內建管理共用 C$'  ($candidates[0] -eq '\\WS02\C$\AnsysWork\MpiToolkit\exchange\PAIR-A-B')
Assert-True  '有第二順位的具名共用'        ($candidates.Count -ge 2)
Assert-Equal '本機收件匣路徑' 'C:\AnsysWork\MpiToolkit\exchange\PAIR-A-B' (Get-LocalExchangePath -CaseId 'PAIR-A-B')
Assert-True  '交換路徑全部是 ASCII'        (Test-AsciiText $candidates[0])

# ---- 結論收斂 ---------------------------------------------------------------
Write-Host ''
Write-Host '  Resolve-OverallOutcome' -ForegroundColor Cyan
Assert-Equal '有 Fail 就是 Fail'            'Fail' (Resolve-OverallOutcome @('Pass', 'Warn', 'Fail'))
Assert-Equal 'Fail 優先於 Wait'             'Fail' (Resolve-OverallOutcome @('Wait', 'Fail'))
Assert-Equal '沒 Fail 但有 Wait 就是 Wait'  'Wait' (Resolve-OverallOutcome @('Pass', 'Wait', 'Warn'))
Assert-Equal '只有 Warn 就是 Warn'          'Warn' (Resolve-OverallOutcome @('Pass', 'Warn', 'Skip'))
Assert-Equal '全過是 Pass'                  'Pass' (Resolve-OverallOutcome @('Pass', 'Pass', 'Skip'))
Assert-Equal '什麼都沒跑是 Pending'         'Pending' (Resolve-OverallOutcome @('Pending', 'Pending'))

# ---- 身分卡片不得外洩憑證 ---------------------------------------------------
Write-Host ''
Write-Host '  New-NodeIdentityRecord' -ForegroundColor Cyan
$record = New-NodeIdentityRecord -ComputerName 'WS01' -UserName 'ansys' -AccountKind 'Local' `
    -UserDomain 'WS01' -IsAdministrator $true -AedtRoot 'C:\Program Files\AnsysEM\v261\Win64' `
    -AedtVersion '26.1' -Role 'Primary' -CaseId 'PAIR-A-B'
$fields = @($record.PSObject.Properties.Name)
Assert-True  '不含 password 欄位'   (-not ($fields -match '(?i)password'))
Assert-True  '不含 credential 欄位' (-not ($fields -match '(?i)credential'))
Assert-True  '不含 secret 欄位'     (-not ($fields -match '(?i)secret'))
Assert-Equal '帶得出帳號名稱給對端比對' 'ansys' $record.userName
Assert-Equal '帶得出帳號型態給對端比對' 'Local' $record.accountKind

# ---- 引數引用 ---------------------------------------------------------------
Write-Host ''
Write-Host '  Quote-Argument' -ForegroundColor Cyan
Assert-Equal '一般值加上引號' '"C:\AnsysWork"' (Quote-Argument 'C:\AnsysWork')
$threw = $false
try { Quote-Argument 'bad" -Command evil' } catch { $threw = $true }
Assert-True '含雙引號的值要丟例外' $threw

# ---- 檔案層：編碼、啟動器、5.1 可解析 ---------------------------------------
Write-Host ''
Write-Host '  檔案層檢查' -ForegroundColor Cyan
$wizardBytes = [IO.File]::ReadAllBytes($target)
Assert-True '精靈腳本是 UTF-8 with BOM' ($wizardBytes[0] -eq 0xEF -and $wizardBytes[1] -eq 0xBB -and $wizardBytes[2] -eq 0xBF)

$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($target, [ref]$null, [ref]$parseErrors)
Assert-Equal '精靈腳本可由 PowerShell 5.1 剖析' 0 (@($parseErrors).Count)

$launcher = Join-Path $toolRoot '一鍵串機.bat'
Assert-True '有一鍵啟動器' (Test-Path -LiteralPath $launcher -PathType Leaf)
if (Test-Path -LiteralPath $launcher -PathType Leaf) {
    # 中文寫進 .bat 會被 cmd 用系統 ANSI 解讀，在不同語系機器上變亂碼甚至讓指令解析壞掉。
    $launcherBytes = [IO.File]::ReadAllBytes($launcher)
    Assert-True '啟動器全 ASCII' (@($launcherBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
    $launcherText = Get-Content -LiteralPath $launcher -Raw
    Assert-True '啟動器指向精靈腳本'   ($launcherText -match 'Start-OneClickCluster\.ps1')
    Assert-True '啟動器使用 STA'       ($launcherText -match '-Sta')
    Assert-True '啟動器繞過執行原則'   ($launcherText -match 'ExecutionPolicy Bypass')
    Assert-True '啟動器不要求使用者打指令' ($launcherText -notmatch 'set /p')
}

# 指定機組的啟動器只以「範本」入庫。真實機器名稱是內部資產資訊，
# 填好的那一份留在本機、由 .gitignore 擋住，不進版本庫。
$pairTemplate = Join-Path $toolRoot '指定機組啟動器-範本.bat'
Assert-True '指定機組啟動器範本存在' (Test-Path -LiteralPath $pairTemplate -PathType Leaf)
if (Test-Path -LiteralPath $pairTemplate -PathType Leaf) {
    $templateBytes = [IO.File]::ReadAllBytes($pairTemplate)
    Assert-True '範本全 ASCII' (@($templateBytes | Where-Object { $_ -gt 127 }).Count -eq 0)
    $templateText = Get-Content -LiteralPath $pairTemplate -Raw
    Assert-True '範本用佔位字串而不是真實機器名' ($templateText -match 'HOSTA,HOSTB')
    Assert-True '範本把機組傳給 -PairHosts'      ($templateText -match '-PairHosts')
    Assert-True '範本指向同一支精靈'             ($templateText -match 'Start-OneClickCluster\.ps1')
    Assert-True '範本使用 STA'                   ($templateText -match '-Sta')
    # 沒改就跑會拿 "HOSTA" 當對端，錯誤訊息還會指向網路——要擋在最前面。
    Assert-True '沒改就執行會被擋下來'           ($templateText -match 'findstr /C:"HOSTA"')
}

$wizardText = Get-Content -LiteralPath $target -Raw
Assert-True '精靈接受 -PairHosts'          ($wizardText -match '\[string\[\]\]\s*\$PairHosts')
Assert-True '本機不在機組時要明講'          ($wizardText -match '不在名單裡')
Assert-True '精靈會呼叫既有的節點檢查核心' ($wizardText -match 'Test-AedtCluster\.ps1')
Assert-True '精靈會呼叫既有的修復核心'     ($wizardText -match 'Repair-AedtClusterNode\.ps1')
Assert-True '精靈會呼叫既有的帳密註冊核心' ($wizardText -match 'Register-IntelMpiCredential\.ps1')
Assert-True '精靈會呼叫既有的設定產生器'   ($wizardText -match 'New-AedtClusterConfig\.ps1')
# 求解必須由人自己送出：工具產生命令但不執行，猜錯選項的批次檔比沒有更糟。
Assert-True '精靈不自動送出求解'           ($wizardText -notmatch 'run-batch\.cmd.*Start-Process')
Assert-True '精靈不關閉 AEDT'              ($wizardText -notmatch 'taskkill')
Assert-True '精靈不接收密碼'               ($wizardText -notmatch '(?i)\$password')

Write-Host ''
Write-Host ('  通過 ' + $script:Passed + ' 項，失敗 ' + $script:Failed + ' 項。') -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ''

if ($script:Failed -gt 0) { exit 1 }
exit 0
