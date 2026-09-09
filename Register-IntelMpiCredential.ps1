#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Peer = '',
    [string] $AedtRoot = '',
    [switch] $DiscoverOnly,
    [switch] $VerifyOnly,
    [switch] $ShowResult
)

$ErrorActionPreference = 'Stop'
$verificationBlocked = $false

trap {
    $failureMessage = 'Intel MPI 帳密註冊／驗證失敗：' + $_.Exception.Message
    if ($ShowResult) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [Windows.Forms.MessageBox]::Show(
                $failureMessage,
                'Intel MPI 驗證',
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        } catch {
            [Console]::Error.WriteLine($failureMessage)
        }
    } else {
        [Console]::Error.WriteLine($failureMessage)
    }
    exit 2
}

function Quote-ProcessArgument {
    param([string] $Value)
    if ($Value -match '"') { throw '帳號或主機名稱不可包含雙引號。' }
    return '"' + $Value + '"'
}

function Invoke-IntelMpiProcess {
    param(
        [string] $FilePath,
        [string] $Arguments,
        [int] $TimeoutSeconds = 30
    )
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw '無法啟動 Intel MPI。' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            throw 'Intel MPI 等待逾時。'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdoutTask.Result
            StdErr = $stderrTask.Result
        }
    } finally {
        $process.Dispose()
    }
}

function Test-TcpPort {
    param([string] $ComputerName, [int] $Port, [int] $TimeoutMs = 3000)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Get-AnsysProcessNames {
    param([string] $Text)
    $patterns = @(
        'ansysedt\.exe', 'HFSSCOMENGINE\.exe', 'desktopjob\.exe',
        'Q3DCOMENGINE\.exe', 'EXTRACTOR2DCOMENGINE\.exe', 'ICEPAKCOMENGINE\.exe',
        'MAXWELLCOMENGINE\.exe', 'MAXWELL2DCOMENGINE\.exe', 'MECHANICALCOMENGINE\.exe',
        'ENSCOMENGINE\.exe', 'RMXPRTCOMENGINE\.exe', 'SimplorerCOMEngine\.exe', 'nexxim\.exe'
    )
    $found = @()
    foreach ($pattern in $patterns) {
        if ($Text -match ('(?i)\b' + $pattern + '\b')) {
            $found += $pattern.Replace('\.exe', '.exe')
        }
    }
    return @($found | Select-Object -Unique)
}

function Start-IntelMpiCredentialPrompt {
    param([string] $FilePath)

    Add-Type -AssemblyName System.Windows.Forms
    $instructions = @"
即將開啟 Intel MPI 帳密視窗：

1．account 顯示目前帳號時，直接按 Enter。
2．輸入目前 Windows 密碼，再按 Enter。
3．再次輸入相同密碼確認，再按 Enter。

輸入密碼時畫面不會顯示任何字元，這是正常的。
"@
    [Windows.Forms.MessageBox]::Show(
        $instructions,
        'Intel MPI 帳密註冊',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /c ""' + $FilePath + '" -register"'
    $info.WorkingDirectory = Split-Path -Parent $FilePath
    $info.UseShellExecute = $true
    $info.CreateNoWindow = $false
    $info.WindowStyle = 'Normal'
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw '無法開啟 Intel MPI 帳密視窗。' }
        $process.WaitForExit()
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

if (-not $AedtRoot) {
    if ($env:ANSYSEM_ROOT261) { $AedtRoot = $env:ANSYSEM_ROOT261 }
    else { $AedtRoot = 'C:\Program Files\Ansys Inc\v261\AnsysEM' }
}
$AedtRoot = $AedtRoot.Trim().Trim('"').TrimEnd('\')
$mpiCandidates = @(
    (Join-Path $AedtRoot 'common\fluent_mpi\multiport\mpi\win64\intel21\bin\mpiexec.exe'),
    (Join-Path $AedtRoot 'common\fluent_mpi\multiport\mpi\win64\intel\bin\mpiexec.exe')
)
$mpiExe = $mpiCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $mpiExe) { throw '找不到 AEDT 2026 R1 內附的 Intel MPI mpiexec.exe。' }

if ($DiscoverOnly) {
    [pscustomobject]@{ MpiExe = $mpiExe; SupportsRegister = $true; SupportsValidate = $true } |
        ConvertTo-Json
    exit 0
}

$Peer = $Peer.Trim()
if ($Peer -notmatch '^[A-Za-z0-9.-]+$') { throw '請輸入對端電腦名稱。' }

$hydraPort = 8680
if ($VerifyOnly) {
    $rsmMpiRoot = [Environment]::GetEnvironmentVariable('ANSYS_EM_EXEC_DIR', 'Machine')
    if ($rsmMpiRoot) { $rsmMpiRoot = $rsmMpiRoot.Trim().Trim('"').TrimEnd('\') }
    if (-not $rsmMpiRoot -or $rsmMpiRoot -ine $AedtRoot) {
        throw ('RSM 的 ANSYS_EM_EXEC_DIR 尚未生效。請先按「① 完整修復（管理員）」並重新啟動 Windows。')
    }
    $hydraPortText = [Environment]::GetEnvironmentVariable('I_MPI_HYDRA_SERVICE_PORT', 'Machine')
    $parsedHydraPort = 0
    if ([int]::TryParse($hydraPortText, [ref]$parsedHydraPort) -and $parsedHydraPort -gt 0 -and $parsedHydraPort -le 65535) {
        $hydraPort = $parsedHydraPort
    }
    if (-not (Test-TcpPort -ComputerName $Peer -Port 32958)) {
        throw ('對端 ' + $Peer + ' 的 RSM TCP 32958 無法連線。')
    }
    if (-not (Test-TcpPort -ComputerName $Peer -Port $hydraPort)) {
        throw ('對端 ' + $Peer + ' 的 Intel Hydra TCP ' + $hydraPort + ' 無法連線。')
    }
}

if (-not $VerifyOnly) {
    $registerExitCode = Start-IntelMpiCredentialPrompt -FilePath $mpiExe
    if ($registerExitCode -ne 0) {
        throw ('Intel MPI 帳密註冊未完成，離開代碼：' + $registerExitCode)
    }
}

$validateArgs = '-validate -host ' + (Quote-ProcessArgument $Peer)
$validated = Invoke-IntelMpiProcess -FilePath $mpiExe -Arguments $validateArgs
if ($validated.ExitCode -ne 0) {
    throw ('Intel MPI 對端驗證失敗，請確認帳號可登入 ' + $Peer + '。離開代碼：' + $validated.ExitCode)
}

if ($VerifyOnly) {
    $hostList = $env:COMPUTERNAME + ',' + $Peer
    $hostnameExe = Join-Path $env:SystemRoot 'System32\hostname.exe'
    $smokeArgs = '-n 2 -ppn 1 -hosts ' + (Quote-ProcessArgument $hostList) + ' ' + (Quote-ProcessArgument $hostnameExe)
    $smoke = Invoke-IntelMpiProcess -FilePath $mpiExe -Arguments $smokeArgs -TimeoutSeconds 45
    if ($smoke.ExitCode -ne 0) {
        throw ('雙節點 MPI 啟動失敗。離開代碼：' + $smoke.ExitCode + '。' + $smoke.StdErr.Trim())
    }
    $hostOutput = @(($smoke.StdOut -split '\r?\n') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $localShort = $env:COMPUTERNAME.Split('.')[0]
    $peerShort = $Peer.Split('.')[0]
    if (@($hostOutput | Where-Object { $_ -ieq $localShort }).Count -eq 0 -or
        @($hostOutput | Where-Object { $_ -ieq $peerShort }).Count -eq 0) {
        throw ('雙節點 MPI 已執行，但輸出未同時包含 ' + $localShort + ' 與 ' + $peerShort + '。實際輸出：' + ($hostOutput -join '、'))
    }

    $busyPatterns = @(
        'ansysedt', 'HFSSCOMENGINE', 'desktopjob', 'Q3DCOMENGINE', 'EXTRACTOR2DCOMENGINE',
        'ICEPAKCOMENGINE', 'MAXWELLCOMENGINE', 'MAXWELL2DCOMENGINE', 'MECHANICALCOMENGINE',
        'ENSCOMENGINE', 'RMXPRTCOMENGINE', 'SimplorerCOMEngine', 'nexxim'
    )
    $localBusy = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $busyPatterns -icontains $_.ProcessName } |
        Select-Object -ExpandProperty ProcessName -Unique)
    $tasklistExe = Join-Path $env:SystemRoot 'System32\tasklist.exe'
    $taskArgs = '-n 1 -host ' + (Quote-ProcessArgument $Peer) + ' ' + (Quote-ProcessArgument $tasklistExe)
    $tasklist = Invoke-IntelMpiProcess -FilePath $mpiExe -Arguments $taskArgs -TimeoutSeconds 45
    if ($tasklist.ExitCode -ne 0) {
        throw ('無法確認 ' + $Peer + ' 是否有既有 Ansys 程序。離開代碼：' + $tasklist.ExitCode + '。' + $tasklist.StdErr.Trim())
    }
    $remoteBusy = @(Get-AnsysProcessNames -Text $tasklist.StdOut)

    $lines = @(
        '雙機快速測試通過。',
        ('MPI 帳密：' + $Peer + ' 驗證成功'),
        'RSM：TCP 32958 通過',
        ('Intel Hydra：TCP ' + $hydraPort + ' 通過'),
        ('雙節點 MPI：' + $localShort + '、' + $peerShort + ' 都有回應')
    )
    if ($localBusy.Count -gt 0 -or $remoteBusy.Count -gt 0) {
        $verificationBlocked = $true
        $lines += ''
        $lines[0] = '雙機連線通過，但求解前清場未通過。'
        $lines += '偵測到既有 Ansys 程序：'
        if ($localBusy.Count -gt 0) { $lines += ($localShort + '：' + ($localBusy -join '、')) }
        if ($remoteBusy.Count -gt 0) { $lines += ($peerShort + '：' + ($remoteBusy -join '、')) }
        $lines += '正式求解前，請關閉兩台既有 AEDT／求解器，只在主控電腦開啟 AEDT。'
    } else {
        $lines += '求解前清場：通過，兩台都沒有既有 AEDT／求解器。'
    }
    $message = $lines -join [Environment]::NewLine
} else {
    $message = 'Intel MPI 帳密註冊完成，對端 ' + $Peer + ' 驗證成功。'
}
Write-Host $message
if ($VerifyOnly -and $verificationBlocked) { exit 3 }
if ($ShowResult) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show(
        $message,
        'Intel MPI 驗證',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}
