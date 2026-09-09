#Requires -Version 5.1
<#
.SYNOPSIS
    驗證匿名化函式與所有報告寫檔路徑都有套用防漏處理。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $TestsDir

function Assert-True {
    param([string] $Name, [bool] $Condition)
    if ($Condition) {
        $script:Pass++
        Write-Host ('  [PASS] ' + $Name) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
    }
}

function Get-FunctionDefinition {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw ('無法解析 ' + $Path) }
    $fn = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $fn) { throw ('找不到函式：' + $Name) }
    return $fn.Extent.Text
}

function Test-ProtectText {
    param([string] $ScriptPath)
    Remove-Item Function:\Protect-Value -ErrorAction SilentlyContinue
    Remove-Item Function:\Protect-Text -ErrorAction SilentlyContinue
    Invoke-Expression (Get-FunctionDefinition -Path $ScriptPath -Name 'Protect-Value')
    Invoke-Expression (Get-FunctionDefinition -Path $ScriptPath -Name 'Protect-Text')

    $script:Anonymize = $true
    $script:AnonymizationKey = $null
    $script:SensitiveHosts = @('LICSRV01', 'PEERWS02')
    $sample = $env:COMPUTERNAME + ' ' + $env:USERNAME + ' 192.168.10.25 LICSRV01 PEERWS02'
    $safe = Protect-Text $sample
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：本機名稱已移除') `
        ($safe -notmatch [regex]::Escape($env:COMPUTERNAME))
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：使用者名稱已移除') `
        ($safe -notmatch [regex]::Escape($env:USERNAME))
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：內網 IP 已移除') `
        ($safe -notmatch '192\.168\.10\.25')
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：清單內的主機名稱已移除') `
        ($safe -notmatch 'LICSRV01|PEERWS02')

    $alias1 = Protect-Value -Value 'PEERWS02' -Prefix 'host'
    $alias2 = Protect-Value -Value 'PEERWS02' -Prefix 'host'
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：同一份報告內代碼一致') ($alias1 -eq $alias2)
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：代碼使用 64 位十六進位摘要') `
        ($alias1 -match '^host-[0-9a-f]{16}$')
    $script:AnonymizationKey = $null
    $alias3 = Protect-Value -Value 'PEERWS02' -Prefix 'host'
    Assert-True ((Split-Path -Leaf $ScriptPath) + '：不同執行使用不同案件密鑰') ($alias1 -ne $alias3)

    # 代表三種輸出格式走真正的 Protect-Text，再驗證原始敏感值沒有殘留。
    $node = [ordered]@{
        computerName = $env:COMPUTERNAME
        userName = $env:USERNAME
        peerProbes = @([ordered]@{ target = 'PEERWS02'; address = '192.168.10.25' })
    }
    $representativeOutputs = @(
        ($node | ConvertTo-Json -Depth 5),
        ('Computer=' + $env:COMPUTERNAME + '; Peer=PEERWS02; IP=192.168.10.25'),
        ('<td>' + $env:USERNAME + '</td><td>LICSRV01</td>')
    )
    foreach ($output in $representativeOutputs) {
        $protected = Protect-Text $output
        Assert-True ((Split-Path -Leaf $ScriptPath) + '：代表輸出已清除敏感值') `
            ($protected -notmatch ([regex]::Escape($env:COMPUTERNAME) + '|' +
                                   [regex]::Escape($env:USERNAME) + '|PEERWS02|LICSRV01|192\.168\.10\.25'))
    }
}

Write-Host ''
Write-Host '匿名化回歸測試' -ForegroundColor Cyan
Write-Host ('-' * 60) -ForegroundColor DarkGray

$licensePath = Join-Path $RootDir 'Check-AnsysLicense.ps1'
$clusterPath = Join-Path $RootDir 'Test-AedtCluster.ps1'
Test-ProtectText -ScriptPath $licensePath
Test-ProtectText -ScriptPath $clusterPath

$licenseSource = Get-Content -LiteralPath $licensePath -Raw
$clusterSource = Get-Content -LiteralPath $clusterPath -Raw
Assert-True '授權文字報告寫檔前整體匿名化' `
    ($licenseSource -match '\(Protect-Text \$tb\.ToString\(\)\)\s*\|\s*Out-File')
Assert-True '授權 HTML 報告寫檔前整體匿名化' `
    ($licenseSource -match '\(Protect-Text \$hb\.ToString\(\)\)\s*\|\s*Out-File')
Assert-True '授權 JSON 寫檔前整體匿名化' `
    ($licenseSource -match '\(Protect-Text \$jsonText\)\s*\|\s*Out-File')
Assert-True '節點 tempDir 欄位有匿名化' `
    ($clusterSource -match 'tempDir\s*=\s*Protect-Text\s+\$t\.TempDir')
Assert-True '節點 JSON 寫檔前整體匿名化' `
    ($clusterSource -match '\(Protect-Text \$jsonText\)\s*\|\s*Out-File')
Assert-True '節點工具會把對端主機加入敏感名稱清單' `
    ($clusterSource -match '\$script:SensitiveHosts\s*=\s*@\(\$Peers')

# 實際執行彙整模式並讀回產出的 TXT／HTML／JSON，避免只驗證原始碼字串。
. (Join-Path $TestsDir '_NodeFixture.ps1')
$integrationDir = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('aedt-anon-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $integrationDir | Out-Null
try {
    $nodeDir = Join-Path $integrationDir 'nodes'
    $outDir = Join-Path $integrationDir 'out'
    New-Item -ItemType Directory -Path $nodeDir | Out-Null
    $peer1 = [pscustomobject]@{ target = 'CUSTOMER-WS02'; resolveOk = $true; addresses = @('192.168.50.12'); pingOk = $true; rsmPortOk = $true }
    $peer2 = [pscustomobject]@{ target = 'CUSTOMER-WS01'; resolveOk = $true; addresses = @('192.168.50.11'); pingOk = $true; rsmPortOk = $true }
    (New-Node -Name 'CUSTOMER-WS01' -User 'customer.user' -Ip '192.168.50.11' `
        -Network '192.168.50.0/24' -Peers @($peer1)) |
        ConvertTo-Json -Depth 10 | Out-File (Join-Path $nodeDir 'n1.node.json') -Encoding utf8
    (New-Node -Name 'CUSTOMER-WS02' -User 'customer.user' -Ip '192.168.50.12' `
        -Network '192.168.50.0/24' -Peers @($peer2)) |
        ConvertTo-Json -Depth 10 | Out-File (Join-Path $nodeDir 'n2.node.json') -Encoding utf8

    $global:LASTEXITCODE = 0
    $toolOutput = (& $clusterPath -Merge $nodeDir -OutDir $outDir -Json -Anonymize 2>&1 | Out-String)
    $toolExit = $LASTEXITCODE
    if ($toolExit -ne 0) { Write-Host $toolOutput -ForegroundColor DarkGray }
    Assert-True '實際匿名彙整正常結束' ($toolExit -eq 0)
    $generated = @(Get-ChildItem -LiteralPath $outDir -File)
    Assert-True '實際匿名彙整有產出 TXT 與 JSON' `
        ((@($generated | Where-Object Extension -eq '.txt').Count -gt 0) -and
         (@($generated | Where-Object Extension -eq '.json').Count -gt 0))
    $allContent = ($generated | ForEach-Object {
        Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
    }) -join [Environment]::NewLine
    $leaks = @([regex]::Matches($allContent,
        'CUSTOMER-WS01|CUSTOMER-WS02|customer\.user|192\.168\.50\.(?:11|12)') |
        ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($leaks.Count -gt 0) {
        Write-Host ('  偵測到：' + ($leaks -join '、')) -ForegroundColor DarkGray
        $firstLeak = [regex]::Match($allContent,
            'CUSTOMER-WS01|CUSTOMER-WS02|customer\.user|192\.168\.50\.(?:11|12)')
        $from = [math]::Max(0, $firstLeak.Index - 80)
        $length = [math]::Min(200, $allContent.Length - $from)
        Write-Host ('  內容片段：' + $allContent.Substring($from, $length)) -ForegroundColor DarkGray
    }
    Assert-True '實際匿名彙整的所有報告均無節點名稱、帳號與內網 IP' ($leaks.Count -eq 0)
} finally {
    Remove-Item -LiteralPath $integrationDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ('-' * 60) -ForegroundColor DarkGray
Write-Host ('  通過 ' + $script:Pass + '，失敗 ' + $script:Fail) `
    -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
exit $(if ($script:Fail -eq 0) { 0 } else { 1 })
