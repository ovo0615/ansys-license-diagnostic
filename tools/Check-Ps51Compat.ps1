#Requires -Version 5.1
<#
.SYNOPSIS
    檢查 .ps1 有沒有用到 PowerShell 7 才有的語法。

.DESCRIPTION
    這個專案的目標執行環境是 Windows 內建的 PowerShell 5.1——客戶機器上不會有
    別的東西，也不能要求客戶去裝。開發時卻很容易在 7.x 上寫出 5.1 跑不動的語法，
    而且這種錯誤在 5.1 上是**載入時就整支掛掉**，不是執行到那一行才壞。

    用 PowerShell 自己的語法剖析器判斷，不是用字串比對——`&&` 出現在註解或
    字串裡不算問題，只有真的被剖析成運算子才算。

    檢查項目：
      -  ??   ??=   ?.   ?[]        （null 合併、null 條件存取）
      -  &&   ||                    （管線鏈結運算子）
      -  a ? b : c                  （三元運算子）
      -  7.x 才有的參數             （見 $SEVEN_ONLY_PARAMS）

    偵測不到的部分：7.x 新增的 cmdlet、5.1 沒有的 .NET API、
    以及行為差異（例如 ConvertTo-Json 的預設深度）。這些只能靠實機驗。

.PARAMETER Path
    要檢查的檔案或目錄，可多個。預設為版本庫內所有 git 追蹤中的 .ps1。

.EXAMPLE
    pwsh -File tools\Check-Ps51Compat.ps1

.NOTES
    虎門科技股份有限公司 Taiwan Auto-Design Co.
#>
[CmdletBinding()]
param(
    [string[]] $Path
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir   = Split-Path -Parent $ScriptDir

# TokenKind 名稱。用名稱比對而不是列舉值，因為這些成員在 5.1 的組件裡根本
# 不存在——寫成 [TokenKind]::QuestionQuestion 的話，這支檢查工具自己會在 5.1 上掛掉。
$SEVEN_ONLY_TOKENS = @{
    'QuestionQuestion'       = '?? （null 合併運算子）'
    'QuestionQuestionEquals' = '??= （null 合併指定）'
    'QuestionDot'            = '?. （null 條件成員存取）'
    'QuestionLBracket'       = '?[] （null 條件索引）'
    'AndAnd'                 = '&& （管線鏈結）'
    'OrOr'                   = '|| （管線鏈結）'
}

# 7.x 才有的參數。**必須綁定到特定 cmdlet**，不能只看參數名稱——
# 同一個參數名稱在 5.1 的別支 cmdlet 上可能是合法的：
#   -AsHashtable  ConvertFrom-Json 沒有（7.x 才加），但 Group-Object 5.1 就有
#   -TargetName   Test-Connection 沒有（7.x 才加），但 Write-Error 5.1 就有
#   -NoElement    Format-Custom 沒有，但 Group-Object 5.1 就有
# 只比對參數名稱會把上面三種合法寫法通通誤判成不相容。
#
# 也不要把 -NoNewline 加進來：實測 5.1（5.1.26100）上 Out-File、Add-Content、
# Set-Content 三個都有這個參數。
#
# 這份清單的每一項都由 tests\Test-Ps51Compat.ps1 在真的 5.1 上用
# (Get-Command <cmd>).Parameters.ContainsKey(<param>) 逐一查證，不靠記憶。
$SEVEN_ONLY_PARAMS = @(
    @{ Param = 'asbytestream';         Commands = @('Get-Content', 'Set-Content')
       Detail = 'Get-Content / Set-Content -AsByteStream（5.1 用 -Encoding Byte）' }
    @{ Param = 'ashashtable';          Commands = @('ConvertFrom-Json')
       Detail = 'ConvertFrom-Json -AsHashtable' }
    @{ Param = 'skipcertificatecheck'; Commands = @('Invoke-WebRequest', 'Invoke-RestMethod')
       Detail = 'Invoke-WebRequest / Invoke-RestMethod -SkipCertificateCheck' }
    @{ Param = 'skiphttperrorcheck';   Commands = @('Invoke-WebRequest', 'Invoke-RestMethod')
       Detail = 'Invoke-WebRequest / Invoke-RestMethod -SkipHttpErrorCheck' }
    @{ Param = 'stable';               Commands = @('Sort-Object')
       Detail = 'Sort-Object -Stable' }
    @{ Param = 'targetname';           Commands = @('Test-Connection')
       Detail = 'Test-Connection -TargetName' }
    @{ Param = 'noelement';            Commands = @('Format-Custom')
       Detail = 'Format-Custom -NoElement' }
)

# 常見別名 -> 本名。比對命令時先正規化，免得 gc -AsByteStream 漏掉。
$COMMAND_ALIASES = @{
    'gc' = 'Get-Content'; 'cat' = 'Get-Content'; 'type' = 'Get-Content'
    'sc' = 'Set-Content'; 'set' = 'Set-Content'
    'sort' = 'Sort-Object'; 'iwr' = 'Invoke-WebRequest'; 'irm' = 'Invoke-RestMethod'
    'curl' = 'Invoke-WebRequest'; 'wget' = 'Invoke-WebRequest'
}

# 允許例外：在該行加上這個標記並寫明理由。
$MARKER = 'ps51-ok'

$targets = @()
if ($Path) {
    foreach ($p in $Path) {
        if (Test-Path -LiteralPath $p -PathType Container) {
            $targets += @(Get-ChildItem -LiteralPath $p -Filter '*.ps1' -Recurse -File |
                          ForEach-Object { $_.FullName })
        } elseif (Test-Path -LiteralPath $p) {
            $targets += (Resolve-Path -LiteralPath $p).Path
        } else {
            Write-Host ('找不到：' + $p) -ForegroundColor Yellow
        }
    }
} else {
    # 追蹤中的檔案 + 尚未加入版控的新檔案。
    # 只用 git ls-files 的話，**剛寫好還沒 git add 的檔案不會被檢查**——
    # 而那正是最可能寫出 7.x 語法的檔案。少一個 --others 就是一個靜默的漏洞。
    Push-Location $RepoDir
    try {
        $listed = @(& git ls-files --cached --others --exclude-standard '*.ps1' 2>$null)
    } finally {
        Pop-Location
    }
    foreach ($t in $listed) {
        $full = Join-Path $RepoDir $t
        if (Test-Path -LiteralPath $full) { $targets += $full }
    }
    # git 不在、或這裡不是版本庫時，退回檔案系統掃描，不要靜默地檢查 0 個檔案。
    if ($targets.Count -eq 0) {
        $targets += @(Get-ChildItem -LiteralPath $RepoDir -Filter '*.ps1' -Recurse -File |
                      ForEach-Object { $_.FullName })
    }
}
$targets = @($targets | Select-Object -Unique)

if ($targets.Count -eq 0) {
    Write-Host '沒有找到任何 .ps1。' -ForegroundColor Yellow
    exit 0
}

Write-Host ''
Write-Host ('PowerShell 5.1 相容性檢查　（' + $targets.Count + ' 個檔案）') -ForegroundColor Cyan
Write-Host ('本機剖析器版本：' + $PSVersionTable.PSVersion) -ForegroundColor DarkGray
Write-Host ('-' * 68) -ForegroundColor DarkGray

$problems = @()

foreach ($file in $targets) {
    $rel = $file
    if ($file.StartsWith($RepoDir)) { $rel = $file.Substring($RepoDir.Length).TrimStart('\', '/') }

    $lines = Get-Content -LiteralPath $file -Encoding UTF8
    $tokens = $null
    $errs   = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errs)

    $hits = @()

    if ($errs -and $errs.Count -gt 0) {
        foreach ($e in ($errs | Select-Object -First 5)) {
            $hits += [pscustomobject]@{
                Line = $e.Extent.StartLineNumber; What = '語法錯誤'; Detail = $e.Message
            }
        }
    }

    foreach ($t in $tokens) {
        $kindName = [string]$t.Kind
        if ($SEVEN_ONLY_TOKENS.ContainsKey($kindName)) {
            $hits += [pscustomobject]@{
                Line = $t.Extent.StartLineNumber; What = '7.x 專用運算子'
                Detail = $SEVEN_ONLY_TOKENS[$kindName]
            }
        }
    }

    # ?. 與 ?[] 在 5.1 的剖析器上「不會」產生 QuestionDot / QuestionLBracket。
    # 因為 ? 是 5.1 合法的變數名稱字元，$x?.Length 會被斷成
    #   Variable('$x?')  Dot('.')  Identifier('Length')
    # 所以上面那個 $SEVEN_ONLY_TOKENS 迴圈在 5.1 上對這兩個運算子是死的
    # ——而這支檢查工具本來就是要在 5.1 上跑的。
    #
    # 更糟的是這種寫法在 5.1 不會載入失敗：$x? 是個沒定義的變數，取值得到
    # $null，再取 .Length 還是 $null。整段安靜地回傳錯的答案，沒有任何錯誤訊息。
    #
    # 改用相鄰性判斷：Variable token 以 ? 結尾，且緊接（中間沒有任何空白，
    # 用 offset 比對）一個 Dot 或 LBracket，就是 7.x 的 null 條件存取。
    # 中間有空白的 $x ?.Length、以及 $obj.Foo()?.Bar 這類寫法在 5.1 會產生
    # 語法錯誤，由上面的「語法錯誤」路徑接住，不必在這裡處理。
    $real = @($tokens | Where-Object { [string]$_.Kind -ne 'EndOfInput' })
    for ($i = 0; $i -lt $real.Count - 1; $i++) {
        $cur  = $real[$i]
        $next = $real[$i + 1]
        if ([string]$cur.Kind -ne 'Variable') { continue }
        if (-not ([string]$cur.Text).EndsWith('?')) { continue }
        if ($next.Extent.StartOffset -ne $cur.Extent.EndOffset) { continue }
        $nk = [string]$next.Kind
        if ($nk -eq 'Dot') {
            $hits += [pscustomobject]@{
                Line = $cur.Extent.StartLineNumber; What = '7.x 專用運算子'
                Detail = '?. （null 條件成員存取，5.1 會安靜地回 $null）'
            }
        } elseif ($nk -eq 'LBracket') {
            $hits += [pscustomobject]@{
                Line = $cur.Extent.StartLineNumber; What = '7.x 專用運算子'
                Detail = '?[] （null 條件索引，5.1 會安靜地回 $null）'
            }
        }
    }

    # 三元運算子在 token 層看不出來（? 和 : 各自是別的東西），要從 AST 找。
    # 型別名稱也用字串比對——TernaryExpressionAst 在 5.1 的組件裡不存在。
    if ($ast) {
        $ternary = $ast.FindAll({
            param($n) $n.GetType().Name -eq 'TernaryExpressionAst'
        }, $true)
        foreach ($n in $ternary) {
            $hits += [pscustomobject]@{
                Line = $n.Extent.StartLineNumber; What = '7.x 專用運算子'
                Detail = 'a ? b : c （三元運算子，5.1 請用 if/else）'
            }
        }

        $paramAsts = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandParameterAst]
        }, $true)
        foreach ($n in $paramAsts) {
            $key = ([string]$n.ParameterName).ToLower()

            # 參數所屬的命令。取不到（例如寫在 splat 或非 CommandAst 底下）時
            # 一律不報——寧可漏掉，也不要因為認不出命令就亂報。
            $cmdName = $null
            $parent = $n.Parent
            if ($parent -is [System.Management.Automation.Language.CommandAst]) {
                $cmdName = $parent.GetCommandName()
            }
            if (-not $cmdName) { continue }
            $cmdName = ([string]$cmdName).ToLower()
            if ($COMMAND_ALIASES.ContainsKey($cmdName)) { $cmdName = $COMMAND_ALIASES[$cmdName] }

            foreach ($rule in $SEVEN_ONLY_PARAMS) {
                if ($rule.Param -ne $key) { continue }
                $match = $false
                foreach ($c in $rule.Commands) {
                    if ($c.ToLower() -eq $cmdName.ToLower()) { $match = $true; break }
                }
                if (-not $match) { continue }
                $hits += [pscustomobject]@{
                    Line = $n.Extent.StartLineNumber; What = '7.x 專用參數'
                    Detail = $rule.Detail
                }
            }
        }
    }

    # 標記為已確認的例外就跳過
    $kept = @()
    foreach ($h in $hits) {
        $idx = $h.Line - 1
        if ($idx -ge 0 -and $idx -lt $lines.Count -and $lines[$idx] -like ('*' + $MARKER + '*')) {
            continue
        }
        $kept += $h
    }

    if ($kept.Count -eq 0) {
        Write-Host ('  ok   ' + $rel) -ForegroundColor DarkGray
    } else {
        Write-Host ('  FAIL ' + $rel) -ForegroundColor Red
        foreach ($h in ($kept | Sort-Object Line)) {
            Write-Host ('         L' + $h.Line + '  ' + $h.What + '：' + $h.Detail) -ForegroundColor Red
            $problems += ($rel + ':' + $h.Line + '  ' + $h.Detail)
        }
    }
}

Write-Host ('-' * 68) -ForegroundColor DarkGray
if ($problems.Count -eq 0) {
    Write-Host '  全部通過。' -ForegroundColor Green
    Write-Host ''
    Write-Host '  提醒：這支工具只看得到語法。7.x 才有的 cmdlet、5.1 缺的 .NET API、' -ForegroundColor DarkGray
    Write-Host '  以及行為差異（例如 ConvertTo-Json 的預設深度）仍然只能靠實機驗。' -ForegroundColor DarkGray
    Write-Host ''
    exit 0
}

Write-Host ('  發現 ' + $problems.Count + ' 個問題。') -ForegroundColor Red
Write-Host ''
Write-Host '  確認為誤判時，可在該行加上 ps51-ok 標記並寫明理由。' -ForegroundColor Yellow
Write-Host ''
exit 1
