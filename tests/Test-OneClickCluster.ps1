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

# ---- AEDT 版本辨識與排序 ----------------------------------------------------
# 實機上原本會「明明裝了 v261 卻報 v251」，三個錯疊在一起：
# 環境變數名稱寫死、取第一個而不是最新的、以及 ANSYS Inc 版面多一層 AnsysEM 沒認到。
# 版本挑錯在串機上是真的會出事：兩台必須同版，修復那步還要把
# ANSYS_EM_EXEC_DIR 指到對的安裝目錄。
Write-Host ''
Write-Host '  Get-AedtTokenFromPath / Get-AedtVersionRank / Get-AedtReleaseLabel' -ForegroundColor Cyan
Assert-Equal '舊版面 AnsysEM\v242\Win64'      'v242' (Get-AedtTokenFromPath 'C:\Program Files\AnsysEM\v242\Win64')
Assert-Equal '新版面 ANSYS Inc\v261\AnsysEM'  'v261' (Get-AedtTokenFromPath 'C:\Program Files\ANSYS Inc\v261\AnsysEM')
Assert-Equal '新版面再多一層 Win64'             'v261' (Get-AedtTokenFromPath 'C:\Program Files\ANSYS Inc\v261\AnsysEM\Win64')
Assert-Equal '結尾有反斜線也要認得'             'v251' (Get-AedtTokenFromPath 'C:\Program Files\ANSYS Inc\v251\AnsysEM\')
Assert-Equal '更舊的 AnsysEM19.2 寫法'          'v192' (Get-AedtTokenFromPath 'C:\Program Files\AnsysEM19.2\Win64')
Assert-Equal '認不出來回空字串'                 ''     (Get-AedtTokenFromPath 'C:\Program Files\Something\Win64')
Assert-Equal '空路徑回空字串'                   ''     (Get-AedtTokenFromPath '')

Assert-Equal 'v261 排序值'  261 (Get-AedtVersionRank 'v261')
Assert-Equal 'v242 排序值'  242 (Get-AedtVersionRank 'v242')
Assert-Equal '認不出來排序值為 0'  0 (Get-AedtVersionRank 'nonsense')
Assert-True  'v261 比 v252 新'  ((Get-AedtVersionRank 'v261') -gt (Get-AedtVersionRank 'v252'))
Assert-True  'v252 比 v251 新'  ((Get-AedtVersionRank 'v252') -gt (Get-AedtVersionRank 'v251'))
Assert-True  'v251 比 v242 新'  ((Get-AedtVersionRank 'v251') -gt (Get-AedtVersionRank 'v242'))

Assert-Equal 'v261 的發行名稱' '2026 R1' (Get-AedtReleaseLabel 'v261')
Assert-Equal 'v242 的發行名稱' '2024 R2' (Get-AedtReleaseLabel 'v242')
Assert-Equal '認不出來就原樣回傳' 'weird' (Get-AedtReleaseLabel 'weird')

# 排序整串，確認最新的真的排第一
$ranked = @('v242', 'v261', 'v251', 'v252') |
    ForEach-Object { [pscustomobject]@{ Token = $_; Rank = (Get-AedtVersionRank $_) } } |
    Sort-Object -Property Rank -Descending
Assert-Equal '排序後第一個是最新版' 'v261' $ranked[0].Token
Assert-Equal '排序後最後一個是最舊版' 'v242' $ranked[3].Token

# ---- 離開碼判定 -------------------------------------------------------------
# 這一段釘住一個實機上真的害人的 PowerShell 語意：
#   Start-Process -PassThru 結束後讀 $process.ExitCode 會得到 $null（不丟例外），
#   而 $null -lt 0 算出來是 True。
# 於是 if ($code -lt 0) { 失敗 } 對一個成功的子程序成立，
# 彙整明明產出了報告、離開碼 0，畫面卻寫「彙整未能執行」。
# 第 5、8、9 步都踩過。
Write-Host ''
Write-Host '  Test-ExitCodeUnknown / Test-ExitCodeFailed' -ForegroundColor Cyan
# 先把那個語意本身釘起來，免得有人日後又寫成 -lt 0
Assert-Equal 'PowerShell 的 $null -lt 0 確實是 True' $true ($null -lt 0)
Assert-Equal '取不到離開碼要判定為未知'  $true  (Test-ExitCodeUnknown $null)
Assert-Equal '0 不是未知'                $false (Test-ExitCodeUnknown 0)
Assert-Equal '未知不等於失敗'            $false (Test-ExitCodeFailed $null)
Assert-Equal '離開碼 0 不是失敗'         $false (Test-ExitCodeFailed 0)
Assert-Equal '離開碼 2 不是失敗（那是有發現）' $false (Test-ExitCodeFailed 2)
Assert-Equal '離開碼 -1 才是失敗'        $true  (Test-ExitCodeFailed -1)

# ---- 節點報告涵蓋率 ---------------------------------------------------------
# 實機真的發生過：按了三次「開始」，彙整資料夾裡有三個檔案，工具說
# 「3 份節點報告已就位」就放行——但三份全是同一台的，對端的根本沒到。
# 下一步的彙整當然失敗，而畫面上那句話看起來完全正常。
# 所以這裡一律算「有幾台」，不算「有幾個檔案」。
Write-Host ''
Write-Host '  Get-NodeOwnerFromFileName / Get-NodeCoverage' -ForegroundColor Cyan
$case = 'PAIR-NODEA-NODEB'
Assert-Equal '從檔名認出是哪一台' 'NODEB' `
    (Get-NodeOwnerFromFileName ('AedtCluster_' + $case + '_NODEB_20260915-094019.node.json') $case)
Assert-Equal '另一台也認得出來'   'NODEA' `
    (Get-NodeOwnerFromFileName ('AedtCluster_' + $case + '_NODEA_20260915-094031.node.json') $case)
Assert-Equal '沒給案件編號時退回切字串' 'NODEB' `
    (Get-NodeOwnerFromFileName ('AedtCluster_' + $case + '_NODEB_20260915-094019.node.json'))
Assert-Equal '空檔名回空字串' '' (Get-NodeOwnerFromFileName '')

# 這就是實機那一次：三個檔案、一台機器
$sameMachine = Get-NodeCoverage -Owners @('NODEB', 'NODEB', 'NODEB') -LocalName 'NODEB' -PeerName 'NODEA'
Assert-Equal '三個檔案同一台只算一台'   1 $sameMachine.Machines
Assert-Equal '同一台三份不算到齊'  $false $sameMachine.Complete
Assert-Equal '要講出還缺哪一台'  'NODEA' ($sameMachine.Missing -join '、')

$both = Get-NodeCoverage -Owners @('NODEB', 'NODEA') -LocalName 'NODEB' -PeerName 'NODEA'
Assert-Equal '兩台各一份就是到齊' $true $both.Complete
Assert-Equal '到齊時沒有缺的'        0 $both.Missing.Count

$dupBoth = Get-NodeCoverage -Owners @('NODEB', 'NODEB', 'NODEA') -LocalName 'NODEB' -PeerName 'NODEA'
Assert-Equal '有重複但兩台都在也算到齊' $true $dupBoth.Complete
Assert-Equal '重複的不重複計算'            2 $dupBoth.Machines

$caseInsensitive = Get-NodeCoverage -Owners @('nodeb', 'NODEA') -LocalName 'NODEB' -PeerName 'nodea'
Assert-Equal '大小寫不同視為同一台' $true $caseInsensitive.Complete

$empty = Get-NodeCoverage -Owners @() -LocalName 'NODEB' -PeerName 'NODEA'
Assert-Equal '什麼都沒有時兩台都缺' 2 $empty.Missing.Count

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
Write-Host '  Get-PeerShareProbe / Get-LocalExchangePath' -ForegroundColor Cyan
$probes = Get-PeerShareProbe -Peer 'WS02' -CaseId 'PAIR-A-B'
Assert-Equal '有兩個探測對象'              2 $probes.Count
Assert-Equal '第一順位探測內建管理共用 C$' '\\WS02\C$' $probes[0].Root
Assert-Equal '第一順位的交換資料夾' '\\WS02\C$\AnsysWork\MpiToolkit\exchange\PAIR-A-B' $probes[0].Exchange
Assert-Equal '第二順位探測具名共用'        '\\WS02\MpiExchange' $probes[1].Root
Assert-Equal '第二順位的交換資料夾' '\\WS02\MpiExchange\PAIR-A-B' $probes[1].Exchange

# 這是實機上真的炸掉的那個 bug：舊版從交換路徑往回 Split-Path 兩層去湊共用根，
# 而 Split-Path -Parent 對 UNC 根會回空字串，再丟進下一個 Split-Path 就丟例外
# 「無法將引數繫結到 'Path' 參數，因為它是個空字串」——整個步驟 2 掛掉，
# 但名稱解析與 RSM 埠其實都是通的。現在直接組出共用根，不做任何 Split-Path。
foreach ($probe in $probes) {
    Assert-True ('共用根不是空字串：' + $probe.Label) (-not [string]::IsNullOrWhiteSpace($probe.Root))
    Assert-True ('共用根是 UNC：' + $probe.Label)     ($probe.Root -like '\\*')
    Assert-True ('交換路徑不是空字串：' + $probe.Label) (-not [string]::IsNullOrWhiteSpace($probe.Exchange))
    Assert-True ('路徑全是 ASCII：' + $probe.Label)   (Test-AsciiText $probe.Exchange)
}

# 沒有案件編號時也不能生出結尾是反斜線的路徑
$noCase = Get-PeerShareProbe -Peer 'WS02'
Assert-Equal '沒有案件編號時的具名共用交換路徑' '\\WS02\MpiExchange' $noCase[1].Exchange
Assert-True  '沒有案件編號時路徑不以反斜線結尾' ($noCase[0].Exchange -notmatch '\\$')

Assert-Equal '本機收件匣路徑' 'C:\AnsysWork\MpiToolkit\exchange\PAIR-A-B' (Get-LocalExchangePath -CaseId 'PAIR-A-B')

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
# C$ 不通在網域與工作群組是兩種完全不同的原因，處理方式也不同。
# 講錯會害人往錯的方向查半天，所以訊息必須分開。
Assert-True '共用不通時要分辨網域與工作群組' ($wizardText -match '不是本機系統管理員')
Assert-True '網域情況要說可以直接往下做'     ($wizardText -match '可以直接往下做')
Assert-True '步驟 2 不再用 Split-Path 湊共用根' ($wizardText -notmatch 'Split-Path -Parent \(Split-Path')
# 一台裝了不只一版時，修復必須知道 ANSYS_EM_EXEC_DIR 要指哪一個，
# 否則它自己挑的可能不是你要跑的那一版。
Assert-True '有讓使用者挑 AEDT 版本'        ($wizardText -match '要用哪一版 AEDT')
Assert-True '版本選單預設最新版'            ($wizardText -match 'Sort-Object -Property Rank -Descending')
Assert-True '修復會收到選定的安裝目錄'      ($wizardText -match "-AedtRoot ' \+ \(Quote-Argument")
Assert-True '環境變數不再寫死版本號'        ($wizardText -notmatch 'ANSYSEM_ROOT251')
Assert-True '兩種安裝版面都要找'            ($wizardText -match 'AnsysEM.Win64.ansysedt\.exe')
# USB 模式下，對端報告只能要求放在一個固定短路徑。
# 叫人往工具解壓目錄底下第四層的 merge 貼檔案，一定有人貼錯，
# 而錯法都表現成「怎麼還是只有一份」，看不出是貼錯地方。
Assert-True 'USB 模式會掃本機收件匣'        ($wizardText -match '從收件匣收到對端報告')
Assert-True 'USB 模式只要求一個固定路徑'    ($wizardText -match '只要記一個路徑，兩台都一樣')
Assert-True '有給省掉搬檔的做法'            ($wizardText -match '本機 Administrators 群組')
# 按第二次「開始」不該讓自己的報告變成兩份。
Assert-True '會先清掉自己的舊報告'          ($wizardText -match 'Remove-Item -LiteralPath \$_\.FullName')
Assert-True '用台數而不是檔案數判斷到齊'    ($wizardText -match 'Get-NodeCoverage -Owners')
Assert-True '缺料時要指名還缺哪一台'        ($wizardText -match '還缺這幾台的報告')
# 只拿到身分卡片卻沒拿到節點報告，是複製時漏檔的典型症狀，要講出來。
Assert-True '只收到身分卡片時要點出來'      ($wizardText -match '的身分卡片')
# Start-Process -PassThru 拿不到離開碼，必須用 Diagnostics.Process。
Assert-True '不再用 Start-Process 取離開碼' ($wizardText -notmatch '-PassThru?
')
Assert-True '子程序改用 Diagnostics.Process' ($wizardText -match 'New-Object Diagnostics\.Process')
Assert-True '離開碼判定走專用函式'          ($wizardText -match 'Test-ExitCodeFailed \$result\.ExitCode')
Assert-True '有區分「沒啟動」與「離開碼異常」' ($wizardText -match '子程序沒有啟動')

Write-Host ''
Write-Host ('  通過 ' + $script:Passed + ' 項，失敗 ' + $script:Failed + ' 項。') -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
Write-Host ''

if ($script:Failed -gt 0) { exit 1 }
exit 0
