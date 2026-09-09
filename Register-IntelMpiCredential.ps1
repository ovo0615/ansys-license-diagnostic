#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $Peer = '',
    [string] $AedtRoot = '',
    [switch] $DiscoverOnly,
    [switch] $ShowResult
)

$ErrorActionPreference = 'Stop'

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

$registerExitCode = Start-IntelMpiCredentialPrompt -FilePath $mpiExe
if ($registerExitCode -ne 0) {
    throw ('Intel MPI 帳密註冊未完成，離開代碼：' + $registerExitCode)
}

$validateArgs = '-validate -host ' + (Quote-ProcessArgument $Peer)
$validated = Invoke-IntelMpiProcess -FilePath $mpiExe -Arguments $validateArgs
if ($validated.ExitCode -ne 0) {
    throw ('Intel MPI 對端驗證失敗，請確認帳號可登入 ' + $Peer + '。離開代碼：' + $validated.ExitCode)
}

$message = 'Intel MPI 帳密註冊完成，對端 ' + $Peer + ' 驗證成功。'
Write-Host $message
if ($ShowResult) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show(
        $message,
        'Intel MPI 驗證',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}
