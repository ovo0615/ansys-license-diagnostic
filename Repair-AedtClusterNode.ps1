#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $AedtRoot = '',
    [string] $TempDirectory = 'C:\AnsysWork\AedtTemp',
    [string] $Peer = '',
    [string] $ReportDirectory = '',
    [switch] $SkipAdminCheck,
    [switch] $SkipServiceChanges,
    [switch] $SkipConnectivityChecks,
    [switch] $ConfigureNetworkPorts,
    [switch] $NetworkPlanOnly,
    [switch] $ShowResult
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AsciiText {
    param([string] $Value)
    foreach ($character in $Value.ToCharArray()) {
        if ([int][char]$character -gt 127) { return $false }
    }
    return $true
}

function Test-TcpPort {
    param([string] $ComputerName, [int] $Port, [int] $TimeoutMs = 3000)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return [pscustomobject]@{ Ok = $false; Detail = 'timeout' }
        }
        $client.EndConnect($async)
        return [pscustomobject]@{ Ok = $true; Detail = 'connected' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    } finally {
        $client.Close()
    }
}

function Grant-TempAccess {
    <#
        讓目前使用者與 SYSTEM 對暫存目錄有寫入權；AEDT 的求解器是以 SYSTEM
        起的服務去寫這個目錄，只給使用者權限不夠。

        兩個地方刻意不照直覺寫：

        1. 用 SID 不用帳號名稱。名稱（TADC\jeff.hong）要向網域控制站翻成 SID；
           網域筆電帶出去、連不到 DC 的時候翻不動，會丟
           「這項工作只有主要與次要領域間的信任關係才能執行」。
           去客戶端做串機正是這個情境，所以這條路不能走。

        2. 用 SetAccessControl('Access') 而不是 Set-Acl。Set-Acl 會連 Owner 一起寫回去，
           而 Get-Acl 拿到的 Owner 是帳號名稱，於是又回到第 1 點的翻譯。
           只寫 DACL 就不會碰到擁有者。

        改權限失敗不該讓整支修復停住——真正重要的是「這個目錄寫不寫得進去」，
        那個由呼叫端的寫入測試負責判定。這裡失敗只回報，不丟例外。
    #>
    param([string] $Path)
    $inheritance = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $currentSid  = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid   = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $acl  = $item.GetAccessControl('Access')
        $rules = @(
            (New-Object Security.AccessControl.FileSystemAccessRule(
                $currentSid, 'Modify', $inheritance, $propagation, 'Allow')),
            (New-Object Security.AccessControl.FileSystemAccessRule(
                $systemSid, 'FullControl', $inheritance, $propagation, 'Allow'))
        )
        foreach ($rule in $rules) { $acl.SetAccessRule($rule) }
        $item.SetAccessControl($acl)
        return [pscustomobject]@{ Granted = $true; Reason = '' }
    } catch {
        return [pscustomobject]@{ Granted = $false; Reason = $_.Exception.Message }
    }
}

function Get-HydraServicePort {
    $hydra = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'hydra' -or $_.DisplayName -match 'Hydra Process Manager'
    } | Select-Object -First 1)
    if ($hydra.Count -eq 0) { return 8680 }
    if ($hydra[0].ProcessId) {
        $listen = @(Get-NetTCPConnection -State Listen -OwningProcess $hydra[0].ProcessId -ErrorAction SilentlyContinue |
            Where-Object { $_.LocalAddress -eq '0.0.0.0' -or $_.LocalAddress -eq '::' } |
            Sort-Object LocalPort | Select-Object -First 1)
        if ($listen.Count -gt 0) { return [int]$listen[0].LocalPort }
    }
    return 8680
}

function Set-ToolkitFirewallRule {
    param(
        [string] $DisplayName,
        [string] $LocalPort
    )
    $existing = @(Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        New-NetFirewallRule -DisplayName $DisplayName -Group 'AEDT Multi-PC Toolkit' `
            -Direction Inbound -Action Allow -Enabled True -Profile Domain,Private `
            -Protocol TCP -LocalPort $LocalPort -RemoteAddress LocalSubnet | Out-Null
    } else {
        $existing | Set-NetFirewallRule -Direction Inbound -Action Allow -Enabled True `
            -Profile Domain,Private -RemoteAddress LocalSubnet | Out-Null
        $existing | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter `
            -Protocol TCP -LocalPort $LocalPort | Out-Null
    }
}

if (-not $SkipAdminCheck -and -not (Test-IsAdministrator)) {
    throw '此修復必須以系統管理員身分執行。請由 GUI 的「套用本機修復」按鈕啟動。'
}

$TempDirectory = $TempDirectory.Trim().Trim('"').TrimEnd('\')
if (-not [IO.Path]::IsPathRooted($TempDirectory) -or -not (Test-AsciiText $TempDirectory)) {
    throw '暫存資料夾必須是本機 ASCII 絕對路徑，例如 C:\AnsysWork\AedtTemp。'
}
if ($TempDirectory -match '^\\\\') { throw '暫存資料夾不可使用 UNC 或網路路徑。' }
if ($Peer -and $Peer -notmatch '^[A-Za-z0-9.-]+$') { throw '對端名稱格式不正確。' }

if (-not $AedtRoot) {
    if ($env:ANSYSEM_ROOT261) {
        $AedtRoot = $env:ANSYSEM_ROOT261
    } else {
        $AedtRoot = 'C:\Program Files\Ansys Inc\v261\AnsysEM'
    }
}
$AedtRoot = $AedtRoot.Trim().Trim('"').TrimEnd('\')
if (-not (Test-Path -LiteralPath $AedtRoot -PathType Container)) {
    throw ('找不到 AEDT 2026 R1 安裝目錄：' + $AedtRoot)
}
$cfgPath = Join-Path $AedtRoot 'config\default.cfg'
if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) {
    throw ('找不到設定檔：' + $cfgPath)
}

if (-not $ReportDirectory) { $ReportDirectory = Join-Path $toolRoot 'repair_reports' }
if (-not (Test-AsciiText $ReportDirectory)) { throw '修復報告路徑必須使用 ASCII。' }
if (-not (Test-Path -LiteralPath $ReportDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $ReportDirectory | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $toolRoot 'repair_backup'
if (-not (Test-Path -LiteralPath $backupRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
}
$backupDir = Join-Path $backupRoot ($env:COMPUTERNAME + '_' + $stamp + '_' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $backupDir | Out-Null
$backupCfg = Join-Path $backupDir 'default.cfg.original'
Copy-Item -LiteralPath $cfgPath -Destination $backupCfg

if (-not (Test-Path -LiteralPath $TempDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $TempDirectory | Out-Null
}
$grant = Grant-TempAccess -Path $TempDirectory
# 權限有沒有設成功是次要的，能不能寫才是結論——所以無論如何都做一次真的寫入測試。
$probe = Join-Path $TempDirectory ('.write_test_' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($probe, 'ok', [Text.Encoding]::ASCII)
} catch {
    $detail = '暫存目錄寫不進去：' + $TempDirectory
    if (-not $grant.Granted) { $detail += '（權限設定也失敗：' + $grant.Reason + '）' }
    throw $detail
} finally {
    if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
}

$original = [IO.File]::ReadAllText($cfgPath)
$cfgValue = $TempDirectory.Replace('\','/')
$cfgLine = "`ttempdirectory='$cfgValue'"
if ($original -match '(?m)^\s*tempdirectory\s*=.*$') {
    $updated = [regex]::Replace($original, '(?m)^\s*tempdirectory\s*=.*$', $cfgLine, 1)
} else {
    $endPattern = '(?m)^\s*\$end\s+''Config''\s*$'
    if ($original -notmatch $endPattern) {
        throw 'default.cfg 格式不符，未進行覆寫。原檔已備份。'
    }
    $updated = [regex]::Replace($original, $endPattern, $cfgLine + "`r`n" + '$end ''Config''', 1)
}
$configChanged = $updated -ne $original
if ($configChanged) {
    $staging = Join-Path (Split-Path -Parent $cfgPath) ('.default.cfg.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($staging, $updated, [Text.Encoding]::ASCII)
        Move-Item -LiteralPath $staging -Destination $cfgPath -Force
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
}

$serviceResults = @()
if (-not $SkipServiceChanges) {
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -eq 'AnsoftRSMService' -or $_.Name -match 'hydra'
    })
    foreach ($service in $services) {
        try {
            Set-Service -Name $service.Name -StartupType Automatic
            if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
            $after = Get-Service -Name $service.Name
            $serviceResults += [pscustomobject]@{ Name = $service.Name; Status = [string]$after.Status; Ok = $after.Status -eq 'Running' }
        } catch {
            $serviceResults += [pscustomobject]@{ Name = $service.Name; Status = $_.Exception.Message; Ok = $false }
        }
    }
}

$hydraPort = Get-HydraServicePort
$networkTargets = [ordered]@{
    ANSYS_EM_EXEC_DIR = $AedtRoot
    ANSYSEM_LISTEN_PORT_RANGE = '55000:55499'
    I_MPI_PORT_RANGE = '55500:55999'
    I_MPI_HYDRA_SERVICE_PORT = [string]$hydraPort
}
$firewallRules = @(
    [pscustomobject]@{ DisplayName = 'AEDT MPI Toolkit - RSM'; LocalPort = '32958'; Profiles = 'Domain,Private'; RemoteAddress = 'LocalSubnet' },
    [pscustomobject]@{ DisplayName = 'AEDT MPI Toolkit - Hydra'; LocalPort = [string]$hydraPort; Profiles = 'Domain,Private'; RemoteAddress = 'LocalSubnet' },
    [pscustomobject]@{ DisplayName = 'AEDT MPI Toolkit - AnsoftCOM'; LocalPort = '55000-55499'; Profiles = 'Domain,Private'; RemoteAddress = 'LocalSubnet' },
    [pscustomobject]@{ DisplayName = 'AEDT MPI Toolkit - Intel MPI'; LocalPort = '55500-55999'; Profiles = 'Domain,Private'; RemoteAddress = 'LocalSubnet' }
)
$networkSettings = [ordered]@{}
$networkApplied = $false
if ($ConfigureNetworkPorts) {
    foreach ($name in $networkTargets.Keys) {
        $before = [Environment]::GetEnvironmentVariable($name, 'Machine')
        $target = [string]$networkTargets[$name]
        if (-not $NetworkPlanOnly) {
            [Environment]::SetEnvironmentVariable($name, $target, 'Machine')
        }
        $after = if ($NetworkPlanOnly) { $before } else { [Environment]::GetEnvironmentVariable($name, 'Machine') }
        $networkSettings[$name] = [ordered]@{ before = $before; target = $target; after = $after }
    }
    if (-not $NetworkPlanOnly) {
        foreach ($rule in $firewallRules) {
            Set-ToolkitFirewallRule -DisplayName $rule.DisplayName -LocalPort $rule.LocalPort
        }
        $networkApplied = $true
    }
}

$actualLine = @(Get-Content -LiteralPath $cfgPath | Where-Object { $_ -match '^\s*tempdirectory\s*=' })
$localRsm = if ($SkipConnectivityChecks) {
    [pscustomobject]@{ Ok = $null; Detail = 'skipped' }
} else {
    Test-TcpPort -ComputerName '127.0.0.1' -Port 32958
}
$peerDns = $null
$peerTcp = $null
if ($Peer -and -not $SkipConnectivityChecks) {
    try { $peerDns = @([Net.Dns]::GetHostAddresses($Peer) | ForEach-Object { $_.IPAddressToString }) } catch { $peerDns = @() }
    $peerTcp = Test-TcpPort -ComputerName $Peer -Port 32958
}

$result = [ordered]@{
    schemaVersion = 1
    timestamp = (Get-Date).ToString('o')
    computerName = $env:COMPUTERNAME
    aedtRoot = $AedtRoot
    configPath = $cfgPath
    backupPath = $backupCfg
    tempDirectory = $TempDirectory
    configChanged = $configChanged
    configVerified = $actualLine.Count -eq 1 -and $actualLine[0] -match [regex]::Escape($cfgValue)
    localRsmPort32958 = $localRsm.Ok
    services = $serviceResults
    peer = $Peer
    peerAddresses = $peerDns
    peerRsmPort32958 = $(if ($peerTcp) { $peerTcp.Ok } else { $null })
    networkConfigured = [bool]$ConfigureNetworkPorts
    networkPlanOnly = [bool]$NetworkPlanOnly
    networkApplied = $networkApplied
    networkSettings = $networkSettings
    firewallRules = $(if ($ConfigureNetworkPorts) { $firewallRules } else { @() })
    restartRequired = [bool]($ConfigureNetworkPorts -and -not $NetworkPlanOnly)
}
$reportPath = Join-Path $ReportDirectory ('AedtClusterRepair_' + $env:COMPUTERNAME + '_' + $stamp + '.json')
$result | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $reportPath -Encoding UTF8

$serviceFailure = @($serviceResults | Where-Object { -not $_.Ok }).Count -gt 0
$connectivityOk = $SkipConnectivityChecks -or $result.localRsmPort32958
$ok = $result.configVerified -and $connectivityOk -and -not $serviceFailure
$message = if ($ok) {
    if ($result.restartRequired) {
        '完整修復完成。請在兩台電腦都執行後重新啟動 Windows，再執行節點檢查。'
    } else {
        '本機修復完成。請在另一台電腦執行相同步驟，之後重新執行節點檢查。'
    }
} else {
    '修復已執行，但仍有未通過項目。請開啟 repair_reports 內的最新報告。'
}
Write-Host $message
Write-Host ('設定：' + $actualLine[0])
Write-Host ('備份：' + $backupCfg)
Write-Host ('報告：' + $reportPath)

if ($ShowResult) {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show(
        $message + [Environment]::NewLine + [Environment]::NewLine +
        'TEMP：' + $TempDirectory + [Environment]::NewLine +
        'RSM MPI 目錄：' + $AedtRoot + [Environment]::NewLine +
        'RSM 32958：' + $(if ($result.localRsmPort32958) { '正常' } else { '失敗' }) + [Environment]::NewLine +
        $(if ($result.restartRequired) { '下一步：兩台電腦都要重新啟動 Windows。' + [Environment]::NewLine } else { '' }) +
        '備份：' + $backupCfg,
        'AEDT 串機修復',
        [Windows.Forms.MessageBoxButtons]::OK,
        $(if ($ok) { [Windows.Forms.MessageBoxIcon]::Information } else { [Windows.Forms.MessageBoxIcon]::Warning })
    ) | Out-Null
}

exit $(if ($ok) { 0 } else { 2 })
