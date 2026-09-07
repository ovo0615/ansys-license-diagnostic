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

# 參數名稱 -> 說明。比對時只看真的被剖析成 CommandParameterAst 的部分。
$SEVEN_ONLY_PARAMS = @{
    'asbytestream'         = 'Get-Content / Set-Content -AsByteStream（5.1 用 -Encoding Byte）'
    'ashashtable'          = 'ConvertFrom-Json -AsHashtable'
    'skipcertificatecheck' = 'Invoke-WebRequest / Invoke-RestMethod -SkipCertificateCheck'
    'skiphttperrorcheck'   = 'Invoke-WebRequest / Invoke-RestMethod -SkipHttpErrorCheck'
    'stable'               = 'Sort-Object -Stable'
    'targetname'           = 'Test-Connection -TargetName'
    'nonewline'            = 'Out-File / Add-Content -NoNewline（5.1 只有 Write-Host 有）'
    'noelement'            = 'Format-Custom -NoElement'
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
    Push-Location $RepoDir
    try {
        $tracked = @(& git ls-files '*.ps1' 2>$null)
    } finally {
        Pop-Location
    }
    foreach ($t in $tracked) {
        $full = Join-Path $RepoDir $t
        if (Test-Path -LiteralPath $full) { $targets += $full }
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

        $params = $ast.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandParameterAst]
        }, $true)
        foreach ($n in $params) {
            $key = ([string]$n.ParameterName).ToLower()
            if ($SEVEN_ONLY_PARAMS.ContainsKey($key)) {
                $hits += [pscustomobject]@{
                    Line = $n.Extent.StartLineNumber; What = '7.x 專用參數'
                    Detail = $SEVEN_ONLY_PARAMS[$key]
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
