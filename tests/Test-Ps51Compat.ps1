#Requires -Version 5.1
<#
.SYNOPSIS
    Check-Ps51Compat.ps1 的自我驗證。

.DESCRIPTION
    偵測器最危險的失效方式是「永遠 pass」——看起來每次都綠燈，實際上什麼也沒在看。
    這種假保險比沒有保險更糟，因為它讓人不再自己檢查。

    所以這組測試餵給它的是**刻意寫壞的樣本**，斷言它真的擋得下來；
    同時餵一組**合法但長得很像**的樣本，斷言它不會亂報。

    三類斷言：

      1. 壞樣本必須被擋（exit 1），而且理由要指到對的構造
      2. 好樣本必須通過（exit 0）——包含註解與字串裡出現運算子、
         以及 5.1 本來就合法、只是參數名稱撞名的寫法
      3. $SEVEN_ONLY_PARAMS 裡的每一條，都在真的 5.1 上用 Get-Command 查證
         該 cmdlet 確實沒有那個參數（在 5.1 上跑時才做）

    第 3 類是為了擋掉 -NoNewline 那種錯法：憑印象把一個 5.1 本來就有的參數
    列進黑名單，結果檢查器開始擋合法的程式碼。

.NOTES
    虎門科技股份有限公司 Taiwan Auto-Design Co.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir  = Split-Path -Parent $TestsDir
$Checker  = Join-Path $RepoDir 'tools\Check-Ps51Compat.ps1'

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([string] $Name, [bool] $Condition, [string] $Detail)
    if ($Condition) {
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ('         ' + $Detail) -ForegroundColor DarkGray }
        $script:Fail++
    }
}

# 把樣本寫成 UTF-8 with BOM 的 .ps1，跑一次檢查器，回傳離開代碼與輸出。
function Invoke-Checker {
    param([string] $Content)

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('ps51chk_' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $enc = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($tmp, $Content, $enc)

        $out  = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Checker -Path $tmp 2>&1
        $code = $LASTEXITCODE

        return [pscustomobject]@{
            ExitCode = $code
            Text     = ($out | Out-String)
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    }
}

Write-Host ''
Write-Host 'Check-Ps51Compat.ps1 自我驗證' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray

if (-not (Test-Path -LiteralPath $Checker)) {
    Write-Host ('找不到檢查器：' + $Checker) -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 1：壞樣本必須被擋下來' -ForegroundColor White

# Detail 是預期在輸出裡看到的關鍵字，用來確認「擋下來的理由是對的」，
# 而不是剛好因為別的原因失敗。
$badSamples = @(
    @{ Name = '?? null 合併';        Code = '$a = $null' + "`n" + '$b = $a ?? "x"';        Expect = '??' }
    @{ Name = '??= null 合併指定';   Code = '$a = $null' + "`n" + '$a ??= "x"';            Expect = '??=' }
    @{ Name = '?. null 條件成員';    Code = '$x = $null' + "`n" + '$y = $x?.Length';       Expect = '?.' }
    @{ Name = '?[] null 條件索引';   Code = '$x = $null' + "`n" + '$y = $x?[0]';           Expect = '?[]' }
    @{ Name = '&& 管線鏈結';         Code = 'git status && git log';                        Expect = '&&' }
    @{ Name = '|| 管線鏈結';         Code = 'git status || git log';                        Expect = '||' }
    # 三元運算子在 5.1 上根本剖析不過去，會走「語法錯誤」那條路而不是
    # TernaryExpressionAst。兩條都算對——重點是有被擋下來。
    # 這和 ?. 的差別要記住：?. 在 5.1 剖析得過去（$x? 是合法變數名），
    # 所以它非得靠上面那條相鄰性規則不可；三元則是自己就會炸，擋得住。
    @{ Name = '三元運算子';          Code = '$w = $true ? 1 : 2';           Expect = @('三元', '語法錯誤') }
    @{ Name = 'ConvertFrom-Json -AsHashtable'; Code = '$j = "{}" | ConvertFrom-Json -AsHashtable'; Expect = 'AsHashtable' }
    @{ Name = 'Get-Content -AsByteStream';     Code = 'Get-Content a.bin -AsByteStream';           Expect = 'AsByteStream' }
    @{ Name = 'Sort-Object -Stable';           Code = '1,2,3 | Sort-Object -Stable';               Expect = 'Stable' }
    @{ Name = 'Test-Connection -TargetName';   Code = 'Test-Connection -TargetName localhost';     Expect = 'TargetName' }
    @{ Name = '別名 gc -AsByteStream';         Code = 'gc a.bin -AsByteStream';                    Expect = 'AsByteStream' }
)

foreach ($s in $badSamples) {
    $r = Invoke-Checker -Content $s.Code
    Assert-True -Name ($s.Name + ' — 應被擋下') -Condition ($r.ExitCode -eq 1) `
        -Detail ('exit=' + $r.ExitCode + "`n" + $r.Text)
    # 用 Contains 不要用 -like：期待字串裡有 ?[]，而 [] 在萬用字元裡是字元類別，
    # -like '*?[]*' 會直接丟 WildcardPatternException。
    $wanted = @($s.Expect)
    $matched = $false
    foreach ($w in $wanted) { if ($r.Text.Contains($w)) { $matched = $true; break } }
    Assert-True -Name ($s.Name + ' — 理由要指到 ' + ($wanted -join ' 或 ')) `
        -Condition $matched -Detail $r.Text
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 2：合法樣本不可以被亂報' -ForegroundColor White

$goodSamples = @(
    @{ Name = '註解與字串裡的運算子不算'
       Code = '# comment with && and ?? and ?. inside' + "`n" +
              '$s = "text with ?? and || and ?. inside"' + "`n" +
              'Write-Host $s' }

    @{ Name = 'Group-Object -AsHashtable（5.1 合法）'
       Code = '1,2,3 | Group-Object -AsHashtable' }

    @{ Name = 'Group-Object -NoElement（5.1 合法）'
       Code = '1,2,3 | Group-Object -NoElement' }

    @{ Name = 'Write-Error -TargetName（5.1 合法）'
       Code = 'Write-Error -Message "x" -TargetName "y"' }

    @{ Name = 'Out-File -NoNewline（5.1 合法）'
       Code = '"x" | Out-File -FilePath a.txt -NoNewline' }

    @{ Name = 'Set-Content -NoNewline（5.1 合法）'
       Code = 'Set-Content -Path a.txt -Value "x" -NoNewline' }

    @{ Name = '變數名稱結尾有 ? 但後面隔著空白'
       Code = '$ok = $true' + "`n" + 'if ($ok) { Write-Host "y" }' }

    @{ Name = 'ps51-ok 標記可以豁免'
       Code = '$a = $null' + "`n" + '$b = $a ?? "x"   # ps51-ok 這是刻意的' }
)

foreach ($s in $goodSamples) {
    $r = Invoke-Checker -Content $s.Code
    Assert-True -Name ($s.Name + ' — 應該通過') -Condition ($r.ExitCode -eq 0) `
        -Detail ('exit=' + $r.ExitCode + "`n" + $r.Text)
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '案例 3：黑名單裡的參數要真的是 5.1 沒有的' -ForegroundColor White

# 從檢查器的原始碼把 $SEVEN_ONLY_PARAMS 讀出來，不要在測試裡抄一份——
# 抄一份就會各自漂移，而漂移之後這組測試就等於沒測。
$t = $null; $e = $null
$chkAst = [System.Management.Automation.Language.Parser]::ParseFile($Checker, [ref]$t, [ref]$e)
Assert-True -Name '檢查器本身沒有語法錯誤' -Condition ($e.Count -eq 0) `
    -Detail (($e | ForEach-Object { $_.Message }) -join '; ')

$assigns = $chkAst.FindAll({
    param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$SEVEN_ONLY_PARAMS'
}, $true)

Assert-True -Name '讀得到 $SEVEN_ONLY_PARAMS' -Condition ($assigns.Count -eq 1) `
    -Detail ('找到 ' + $assigns.Count + ' 個')

if ($assigns.Count -eq 1) {
    $rules = $assigns[0].Right.Expression.SafeGetValue()

    if ($PSVersionTable.PSVersion.Major -eq 5) {
        foreach ($rule in $rules) {
            foreach ($cmdName in $rule.Commands) {
                $cmd = Get-Command $cmdName -ErrorAction SilentlyContinue
                if (-not $cmd) {
                    Assert-True -Name ($cmdName + ' 在這台機器上找得到') -Condition $false `
                        -Detail '找不到這個 cmdlet，無法查證'
                    continue
                }
                # 參數名稱在清單裡是小寫，Parameters 的 key 是原始大小寫。
                $hasParam = $false
                foreach ($k in $cmd.Parameters.Keys) {
                    if ($k.ToLower() -eq $rule.Param) { $hasParam = $true; break }
                }
                Assert-True -Name ($cmdName + ' -' + $rule.Param + ' 在 5.1 上確實不存在') `
                    -Condition (-not $hasParam) `
                    -Detail '這個參數 5.1 就有，列進黑名單會擋掉合法的程式碼'
            }
        }
    } else {
        Write-Host ('  [跳過] 本機是 PowerShell ' + $PSVersionTable.PSVersion +
                    '，參數查證只在 5.1 上有意義') -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''

if ($script:Fail -gt 0) { exit 1 }
exit 0
