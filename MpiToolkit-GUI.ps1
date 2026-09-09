#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RunningProcess = $null
$script:StdOutTask = $null
$script:StdErrTask = $null
$script:CurrentOutputDir = ''
$script:CurrentAction = ''

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Normalize-PathInput {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return $Value.Trim().Trim('"').TrimEnd('\')
}

function Test-AsciiPath {
    param([string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
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

function Show-InputError {
    param([string] $Message)
    [Windows.Forms.MessageBox]::Show(
        $form, $Message, '請修正輸入',
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function Add-Log {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $logBox.AppendText($Text.TrimEnd() + [Environment]::NewLine)
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Select-Folder {
    param([Windows.Forms.TextBox] $Target)
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = '選擇資料夾'
    $current = Normalize-PathInput $Target.Text
    if ($current -and (Test-Path -LiteralPath $current -PathType Container)) {
        $dialog.SelectedPath = $current
    }
    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $Target.Text = $dialog.SelectedPath
    }
    $dialog.Dispose()
}

function Select-ProjectFile {
    param([Windows.Forms.TextBox] $Target)
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = '選擇測試用 AEDT 專案複本'
    $dialog.Filter = 'AEDT project (*.aedt)|*.aedt|All files (*.*)|*.*'
    $dialog.CheckFileExists = $true
    if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
        $Target.Text = $dialog.FileName
    }
    $dialog.Dispose()
}

function Add-Field {
    param(
        [Windows.Forms.Control] $Parent,
        [string] $Label,
        [int] $Top,
        [string] $Default = '',
        [switch] $BrowseFolder,
        [switch] $BrowseFile
    )
    $caption = New-Object Windows.Forms.Label
    $caption.Text = $Label
    $caption.Location = New-Object Drawing.Point(24, $Top)
    $caption.Size = New-Object Drawing.Size(180, 28)
    $caption.Anchor = 'Top, Left'
    $Parent.Controls.Add($caption)

    $box = New-Object Windows.Forms.TextBox
    $box.Text = $Default
    $box.Location = New-Object Drawing.Point(205, ($Top - 3))
    $box.Size = New-Object Drawing.Size(525, 30)
    $box.Anchor = 'Top, Left, Right'
    $box.Font = New-Object Drawing.Font('Calibri', 11)
    $Parent.Controls.Add($box)

    if ($BrowseFolder -or $BrowseFile) {
        $browse = New-Object Windows.Forms.Button
        $browse.Text = '瀏覽…'
        $browse.Location = New-Object Drawing.Point(743, ($Top - 4))
        $browse.Size = New-Object Drawing.Size(92, 31)
        $browse.Anchor = 'Top, Right'
        if ($BrowseFolder) { $browse.Add_Click({ Select-Folder $box }.GetNewClosure()) }
        if ($BrowseFile) { $browse.Add_Click({ Select-ProjectFile $box }.GetNewClosure()) }
        $Parent.Controls.Add($browse)
    }
    return $box
}

function Set-RunningState {
    param([bool] $Running, [string] $Message)
    foreach ($button in @($runNodeButton, $runMergeButton, $runConfigButton, $demoButton, $verifyButton, $openProjectButton, $copyMachineButton, $mpiCredentialButton)) {
        $button.Enabled = -not $Running
    }
    $progressBar.Visible = $Running
    $statusLabel.Text = $Message
}

function Start-ToolProcess {
    param(
        [string] $ScriptName,
        [string[]] $Arguments,
        [string] $OutputDirectory,
        [string] $ActionName
    )
    if ($script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        Show-InputError '已有工具正在執行，請先等待完成。'
        return
    }
    $scriptPath = Join-Path $script:ToolRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Show-InputError ('找不到必要檔案：' + $ScriptName)
        return
    }
    $outputPath = Normalize-PathInput $OutputDirectory
    if (-not (Test-AsciiPath $outputPath)) {
        Show-InputError '輸出路徑不可空白，而且完整路徑只能使用 ASCII 字元。'
        return
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' +
                      (Quote-Argument $scriptPath) + ' ' + ($Arguments -join ' ')
    $info.WorkingDirectory = $script:ToolRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::Default
    $info.StandardErrorEncoding = [Text.Encoding]::Default
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info

    $logBox.Clear()
    Add-Log ('開始：' + $ActionName)
    Add-Log ('輸出資料夾：' + $outputPath)
    Add-Log ('-' * 68)
    try {
        if (-not $process.Start()) { throw '無法啟動檢查工具。' }
        $script:RunningProcess = $process
        $script:StdOutTask = $process.StandardOutput.ReadToEndAsync()
        $script:StdErrTask = $process.StandardError.ReadToEndAsync()
        $script:CurrentOutputDir = $outputPath
        $script:CurrentAction = $ActionName
        Set-RunningState $true ('執行中：' + $ActionName)
        $processTimer.Start()
    } catch {
        $process.Dispose()
        Show-InputError $_.Exception.Message
        Set-RunningState $false '啟動失敗'
    }
}

function Open-OutputFolder {
    $path = Normalize-PathInput $script:CurrentOutputDir
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        Show-InputError '目前還沒有可開啟的輸出資料夾。'
        return
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-Argument $path) | Out-Null
}

function Open-GeneratedFile {
    param([string] $FileName)
    $folder = Normalize-PathInput $configOutBox.Text
    $path = Join-Path $folder $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Show-InputError '請先在「③ 建立串機設定」產生設定檔。'
        return
    }
    Start-Process -FilePath $path -WorkingDirectory $folder | Out-Null
    $statusLabel.Text = '已開啟：' + $FileName + '。請依畫面核對 AEDT 選項。'
}

function Open-AedtProject {
    $project = Normalize-PathInput $projectBox.Text
    if (-not (Test-Path -LiteralPath $project -PathType Leaf)) {
        Show-InputError '請先在「③ 建立串機設定」選擇 AEDT 小模型複本。'
        return
    }
    if (-not (Test-AsciiPath $project)) {
        Show-InputError 'AEDT 專案的完整路徑不得包含中文。'
        return
    }
    Start-Process -FilePath $project | Out-Null
    $statusLabel.Text = '已要求 Windows 開啟 AEDT 小模型。AEDT 啟動可能需要數分鐘。'
}

function Copy-MachineListArgument {
    $file = Join-Path (Normalize-PathInput $configOutBox.Text) 'machines.txt'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Show-InputError '找不到 machines.txt。請先在「③ 建立串機設定」產生設定檔。'
        return
    }
    [Windows.Forms.Clipboard]::SetText('-MachineList file="' + $file + '"')
    $statusLabel.Text = '已複製 Machine List 參數，可直接貼到核對中的 AEDT 批次命令。'
}

function Open-Guide {
    $guide = Join-Path $script:ToolRoot 'START_HERE.html'
    if (-not (Test-Path -LiteralPath $guide -PathType Leaf)) {
        $guide = Join-Path $script:ToolRoot 'docs\AEDT_2026R1_Two_PC_Setup_Guide.html'
    }
    if (-not (Test-Path -LiteralPath $guide -PathType Leaf)) {
        Show-InputError '找不到 START_HERE.html。請重新解壓縮完整 ZIP。'
        return
    }
    Start-Process -FilePath $guide | Out-Null
}

function Start-ElevatedRepair {
    $scriptPath = Join-Path $script:ToolRoot 'Repair-AedtClusterNode.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Show-InputError '找不到 Repair-AedtClusterNode.ps1。請重新解壓縮完整工具。'
        return
    }
    $tempPath = Normalize-PathInput $repairTempBox.Text
    $peerName = $repairPeerBox.Text.Trim()
    if (-not (Test-AsciiPath $tempPath) -or -not [IO.Path]::IsPathRooted($tempPath)) {
        Show-InputError '共同暫存路徑必須是本機 ASCII 絕對路徑。'
        return
    }
    if ($peerName -and $peerName -notmatch '^[A-Za-z0-9.-]+$') {
        Show-InputError '對端電腦名稱格式不正確。'
        return
    }
    $reportPath = Join-Path $script:ToolRoot 'repair_reports'
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
                 (Quote-Argument $scriptPath) + ' -TempDirectory ' + (Quote-Argument $tempPath) +
                 ' -ReportDirectory ' + (Quote-Argument $reportPath) +
                 ' -ConfigureNetworkPorts -ShowResult'
    if ($peerName) { $arguments += ' -Peer ' + (Quote-Argument $peerName) }
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments `
            -Verb RunAs -WindowStyle Hidden | Out-Null
        $script:CurrentOutputDir = $reportPath
        $statusLabel.Text = '已送出管理員修復。請在 UAC 視窗按「是」，完成後會顯示結果。'
    } catch {
        Show-InputError ('無法啟動管理員修復：' + $_.Exception.Message)
    }
}

function Start-MpiCredentialRegistration {
    $scriptPath = Join-Path $script:ToolRoot 'Register-IntelMpiCredential.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Show-InputError '找不到 Register-IntelMpiCredential.ps1。請重新解壓縮完整工具。'
        return
    }
    $peerName = $repairPeerBox.Text.Trim()
    if ($peerName -notmatch '^[A-Za-z0-9.-]+$') {
        Show-InputError '請先輸入對端電腦名稱。'
        return
    }
    $arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ' +
                 (Quote-Argument $scriptPath) + ' -Peer ' + (Quote-Argument $peerName) + ' -ShowResult'
    try {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments `
            -WindowStyle Hidden | Out-Null
        $statusLabel.Text = '請依 Intel MPI 帳密視窗輸入目前帳號與密碼；工具不會接收或保存密碼。'
    } catch {
        Show-InputError ('無法啟動 MPI 帳密註冊：' + $_.Exception.Message)
    }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'AEDT Multi-PC Toolkit'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object Drawing.Size(980, 760)
$form.MinimumSize = New-Object Drawing.Size(760, 640)
$form.BackColor = [Drawing.Color]::FromArgb(246, 248, 251)
$form.Font = New-Object Drawing.Font('Microsoft JhengHei', 10)

$header = New-Object Windows.Forms.Panel
$header.Dock = 'Top'; $header.Height = 92
$header.BackColor = [Drawing.Color]::FromArgb(20, 49, 82)
$form.Controls.Add($header)
$title = New-Object Windows.Forms.Label
$title.Text = 'AEDT 兩台電腦串機工具'
$title.ForeColor = [Drawing.Color]::White
$title.Font = New-Object Drawing.Font('Microsoft JhengHei', 20, [Drawing.FontStyle]::Bold)
$title.Location = New-Object Drawing.Point(24, 17); $title.AutoSize = $true
$header.Controls.Add($title)
$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = '檢查＋建立設定｜限定防火牆規則｜不關閉 AEDT｜不需要安裝其他套件'
$subtitle.ForeColor = [Drawing.Color]::FromArgb(205, 220, 236)
$subtitle.Location = New-Object Drawing.Point(27, 59); $subtitle.AutoSize = $true
$header.Controls.Add($subtitle)
$adminLabel = New-Object Windows.Forms.Label
$adminLabel.AutoSize = $true; $adminLabel.ForeColor = [Drawing.Color]::White
$adminLabel.Location = New-Object Drawing.Point(748, 33)
$adminLabel.Anchor = 'Top, Right'
$adminLabel.Text = $(if (Test-IsAdministrator) { '✓ 系統管理員權限' } else { '△ 一般權限，部分資訊可能讀不到' })
$header.Controls.Add($adminLabel)

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(18, 108)
$tabs.Size = New-Object Drawing.Size(944, 382)
$tabs.Anchor = 'Top, Left, Right'
$form.Controls.Add($tabs)

$nodeTab = New-Object Windows.Forms.TabPage
$nodeTab.Text = '① 節點檢查'; $nodeTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($nodeTab) | Out-Null
$nodeHint = New-Object Windows.Forms.Label
$nodeHint.Text = '本機名稱：' + $env:COMPUTERNAME + '。兩台都要執行；對端電腦名稱請填另一台顯示的名稱。'
$nodeHint.Location = New-Object Drawing.Point(24, 20); $nodeHint.Size = New-Object Drawing.Size(820, 30)
$nodeHint.Anchor = 'Top, Left, Right'
$nodeHint.ForeColor = [Drawing.Color]::FromArgb(38, 89, 130)
$nodeTab.Controls.Add($nodeHint)
$caseBox = Add-Field $nodeTab '案件編號（兩台相同）' 64 'INTERNAL-TEST'
$peerBox = Add-Field $nodeTab '對端電腦名稱' 108 ''
$nodeOutBox = Add-Field $nodeTab '報告輸出資料夾' 152 (Join-Path $script:ToolRoot 'reports_raw') -BrowseFolder
$modeLabel = New-Object Windows.Forms.Label
$modeLabel.Text = '串機模式'; $modeLabel.Location = New-Object Drawing.Point(24, 201); $modeLabel.Size = New-Object Drawing.Size(180, 28)
$nodeTab.Controls.Add($modeLabel)
$modeBox = New-Object Windows.Forms.ComboBox
$modeBox.DropDownStyle = 'DropDownList'; $modeBox.Items.AddRange(@('DDM','DSO','Unknown')); $modeBox.SelectedIndex = 0
$modeBox.Location = New-Object Drawing.Point(205, 197); $modeBox.Size = New-Object Drawing.Size(160, 30)
$nodeTab.Controls.Add($modeBox)
$anonymizeBox = New-Object Windows.Forms.CheckBox
$anonymizeBox.Text = '報告匿名化（傳給外部前使用）'; $anonymizeBox.Location = New-Object Drawing.Point(400, 198); $anonymizeBox.Size = New-Object Drawing.Size(300, 30)
$nodeTab.Controls.Add($anonymizeBox)
$demoButton = New-Object Windows.Forms.Button
$demoButton.Text = '載入本機示範值'; $demoButton.Location = New-Object Drawing.Point(24, 252); $demoButton.Size = New-Object Drawing.Size(170, 42)
$demoButton.Add_Click({ $caseBox.Text='DEMO-LOCAL'; $peerBox.Text=$env:COMPUTERNAME; $nodeOutBox.Text=Join-Path $script:ToolRoot 'demo_reports'; $anonymizeBox.Checked=$true })
$nodeTab.Controls.Add($demoButton)
$runNodeButton = New-Object Windows.Forms.Button
$runNodeButton.Text = '開始節點檢查'; $runNodeButton.Location = New-Object Drawing.Point(647, 246); $runNodeButton.Size = New-Object Drawing.Size(188, 50)
$runNodeButton.Anchor = 'Top, Right'
$runNodeButton.BackColor = [Drawing.Color]::FromArgb(0,103,184); $runNodeButton.ForeColor = [Drawing.Color]::White; $runNodeButton.FlatStyle = 'Flat'
$runNodeButton.Add_Click({
    $caseId=$caseBox.Text.Trim(); $peer=$peerBox.Text.Trim(); $outDir=Normalize-PathInput $nodeOutBox.Text
    if($caseId -notmatch '^[A-Za-z0-9._-]+$'){Show-InputError '案件編號只能使用英文字母、數字、點、底線或連字號。';return}
    if($peer -notmatch '^[A-Za-z0-9.-]+$'){Show-InputError '請輸入另一台電腦的 hostname。';return}
    $args=@('-CaseId',(Quote-Argument $caseId),'-Peers',(Quote-Argument $peer),'-Mode',[string]$modeBox.SelectedItem,'-Json','-OutDir',(Quote-Argument $outDir))
    if($anonymizeBox.Checked){$args+='-Anonymize'}
    Start-ToolProcess 'Test-AedtCluster.ps1' $args $outDir '節點檢查'
})
$nodeTab.Controls.Add($runNodeButton)

$mergeTab = New-Object Windows.Forms.TabPage
$mergeTab.Text = '② 彙整報告'; $mergeTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($mergeTab) | Out-Null
$mergeHint = New-Object Windows.Forms.Label
$mergeHint.Text = '把兩台產生的 .node.json 放進同一個資料夾，再於任一台執行。'
$mergeHint.Location = New-Object Drawing.Point(24, 24); $mergeHint.Size = New-Object Drawing.Size(820, 30); $mergeHint.ForeColor = [Drawing.Color]::FromArgb(38,89,130)
$mergeHint.Anchor = 'Top, Left, Right'
$mergeTab.Controls.Add($mergeHint)
$mergeInBox = Add-Field $mergeTab '節點 JSON 資料夾' 78 (Join-Path $script:ToolRoot 'merge_input') -BrowseFolder
$mergeOutBox = Add-Field $mergeTab '彙整輸出資料夾' 126 (Join-Path $script:ToolRoot 'merged_raw') -BrowseFolder
$mergeAnonBox = New-Object Windows.Forms.CheckBox
$mergeAnonBox.Text = '彙整報告匿名化'; $mergeAnonBox.Location = New-Object Drawing.Point(205,178); $mergeAnonBox.Size = New-Object Drawing.Size(240,30)
$mergeTab.Controls.Add($mergeAnonBox)
$runMergeButton = New-Object Windows.Forms.Button
$runMergeButton.Text = '開始彙整'; $runMergeButton.Location = New-Object Drawing.Point(647,230); $runMergeButton.Size = New-Object Drawing.Size(188,50)
$runMergeButton.Anchor = 'Top, Right'
$runMergeButton.BackColor = [Drawing.Color]::FromArgb(0,120,90); $runMergeButton.ForeColor = [Drawing.Color]::White; $runMergeButton.FlatStyle = 'Flat'
$runMergeButton.Add_Click({
    $inputDir=Normalize-PathInput $mergeInBox.Text; $outDir=Normalize-PathInput $mergeOutBox.Text
    if(-not(Test-Path -LiteralPath $inputDir -PathType Container)){Show-InputError '找不到節點 JSON 資料夾。';return}
    if(@(Get-ChildItem -LiteralPath $inputDir -Filter '*.node.json' -File).Count -lt 2){Show-InputError '資料夾內至少需要兩個 .node.json。';return}
    if(-not(Test-AsciiPath $inputDir)){Show-InputError '輸入路徑不得包含中文。';return}
    $args=@('-Merge',(Quote-Argument $inputDir),'-Json','-OutDir',(Quote-Argument $outDir)); if($mergeAnonBox.Checked){$args+='-Anonymize'}
    Start-ToolProcess 'Test-AedtCluster.ps1' $args $outDir '彙整報告'
})
$mergeTab.Controls.Add($runMergeButton)

$configTab = New-Object Windows.Forms.TabPage
$configTab.Text = '③ 建立串機設定'; $configTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($configTab) | Out-Null
$configHint = New-Object Windows.Forms.Label
$configHint.Text = '彙整通過後使用：建立 machines.txt、選項驗證工具與批次命令，不會直接送出求解。'
$configHint.Location = New-Object Drawing.Point(24,20); $configHint.Size = New-Object Drawing.Size(820,30); $configHint.ForeColor = [Drawing.Color]::FromArgb(38,89,130)
$configHint.Anchor = 'Top, Left, Right'
$configTab.Controls.Add($configHint)
$configInBox = Add-Field $configTab '節點 JSON 資料夾' 64 (Join-Path $script:ToolRoot 'merge_input') -BrowseFolder
$projectBox = Add-Field $configTab 'AEDT 小模型複本' 108 '' -BrowseFile
$configOutBox = Add-Field $configTab '設定輸出資料夾' 152 (Join-Path $script:ToolRoot 'cluster_config') -BrowseFolder
$resourceLabel = New-Object Windows.Forms.Label
$resourceLabel.Text='每台：Tasks'; $resourceLabel.Location=New-Object Drawing.Point(24,205); $resourceLabel.AutoSize=$true; $configTab.Controls.Add($resourceLabel)
$tasksBox = New-Object Windows.Forms.NumericUpDown
$tasksBox.Minimum=1; $tasksBox.Maximum=256; $tasksBox.Value=1; $tasksBox.Location=New-Object Drawing.Point(135,201); $tasksBox.Width=75; $configTab.Controls.Add($tasksBox)
$coresLabel = New-Object Windows.Forms.Label
$coresLabel.Text='Cores（0＝自動）'; $coresLabel.Location=New-Object Drawing.Point(240,205); $coresLabel.AutoSize=$true; $configTab.Controls.Add($coresLabel)
$coresBox = New-Object Windows.Forms.NumericUpDown
$coresBox.Minimum=0; $coresBox.Maximum=512; $coresBox.Value=0; $coresBox.Location=New-Object Drawing.Point(390,201); $coresBox.Width=75; $configTab.Controls.Add($coresBox)
$ratioLabel = New-Object Windows.Forms.Label
$ratioLabel.Text='RAM％'; $ratioLabel.Location=New-Object Drawing.Point(500,205); $ratioLabel.AutoSize=$true; $configTab.Controls.Add($ratioLabel)
$ratioBox = New-Object Windows.Forms.NumericUpDown
$ratioBox.Minimum=1; $ratioBox.Maximum=99; $ratioBox.Value=90; $ratioBox.Location=New-Object Drawing.Point(565,201); $ratioBox.Width=75; $configTab.Controls.Add($ratioBox)
$runConfigButton = New-Object Windows.Forms.Button
$runConfigButton.Text='建立串機設定'; $runConfigButton.Location=New-Object Drawing.Point(647,246); $runConfigButton.Size=New-Object Drawing.Size(188,50)
$runConfigButton.Anchor = 'Top, Right'
$runConfigButton.BackColor=[Drawing.Color]::FromArgb(113,73,154); $runConfigButton.ForeColor=[Drawing.Color]::White; $runConfigButton.FlatStyle='Flat'
$runConfigButton.Add_Click({
    $inputDir=Normalize-PathInput $configInBox.Text; $project=Normalize-PathInput $projectBox.Text; $outDir=Normalize-PathInput $configOutBox.Text
    if(-not(Test-Path -LiteralPath $inputDir -PathType Container)){Show-InputError '找不到節點 JSON 資料夾。';return}
    if(-not(Test-Path -LiteralPath $project -PathType Leaf)){Show-InputError '請使用「瀏覽…」選擇 AEDT 專案複本。';return}
    foreach($path in @($inputDir,$project,$outDir)){if(-not(Test-AsciiPath $path)){Show-InputError 'Ansys 路徑不得包含中文。';return}}
    if([int]$coresBox.Value -gt 0 -and [int]$tasksBox.Value -ge [int]$coresBox.Value){Show-InputError 'Tasks 必須小於 Cores。';return}
    $args=@('-From',(Quote-Argument $inputDir),'-Project',(Quote-Argument $project),'-TasksPerNode',[string]$tasksBox.Value,'-CoresPerNode',[string]$coresBox.Value,'-Ratio',[string]$ratioBox.Value,'-OutDir',(Quote-Argument $outDir))
    Start-ToolProcess 'New-AedtClusterConfig.ps1' $args $outDir '產生設定檔'
})
$configTab.Controls.Add($runConfigButton)

$applyTab = New-Object Windows.Forms.TabPage
$applyTab.Text = '④ 套用與驗證'; $applyTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($applyTab) | Out-Null
$applyHint = New-Object Windows.Forms.Label
$applyHint.Text = '設定檔建立完成後照順序操作；每個會修改或執行的動作都由你親自按下。'
$applyHint.Location = New-Object Drawing.Point(24,20); $applyHint.Size = New-Object Drawing.Size(840,30); $applyHint.ForeColor = [Drawing.Color]::FromArgb(38,89,130)
$applyHint.Anchor = 'Top, Left, Right'
$applyTab.Controls.Add($applyHint)
$applySteps = @(
    '1．先執行「驗證命令選項」，核對這台 AEDT 接受的參數。',
    '2．開啟 AEDT 小模型，在 HPC and Analysis Options 建立兩台機器。',
    '3．使用「複製 Machine List 參數」貼入批次命令或留作核對。',
    '4．在 AEDT 按 Test Machines，最後跑一次真正的雙機小模型。'
)
for ($index = 0; $index -lt $applySteps.Count; $index++) {
    $stepLabel = New-Object Windows.Forms.Label
    $stepLabel.Text = $applySteps[$index]
    $stepLabel.Location = New-Object Drawing.Point(32, (67 + $index * 39))
    $stepLabel.Size = New-Object Drawing.Size(840,30)
    $stepLabel.Anchor = 'Top, Left, Right'
    $stepLabel.ForeColor = [Drawing.Color]::FromArgb(45,52,60)
    $applyTab.Controls.Add($stepLabel)
}
$verifyButton = New-Object Windows.Forms.Button
$verifyButton.Text='驗證命令選項'; $verifyButton.Location=New-Object Drawing.Point(32,238); $verifyButton.Size=New-Object Drawing.Size(190,48)
$verifyButton.BackColor=[Drawing.Color]::FromArgb(0,103,184); $verifyButton.ForeColor=[Drawing.Color]::White; $verifyButton.FlatStyle='Flat'
$verifyButton.Add_Click({ Open-GeneratedFile 'verify-batchoptions.cmd' })
$applyTab.Controls.Add($verifyButton)
$openProjectButton = New-Object Windows.Forms.Button
$openProjectButton.Text='開啟 AEDT 小模型'; $openProjectButton.Location=New-Object Drawing.Point(240,238); $openProjectButton.Size=New-Object Drawing.Size(190,48)
$openProjectButton.BackColor=[Drawing.Color]::FromArgb(0,120,90); $openProjectButton.ForeColor=[Drawing.Color]::White; $openProjectButton.FlatStyle='Flat'
$openProjectButton.Add_Click({ Open-AedtProject })
$applyTab.Controls.Add($openProjectButton)
$copyMachineButton = New-Object Windows.Forms.Button
$copyMachineButton.Text='複製 Machine List 參數'; $copyMachineButton.Location=New-Object Drawing.Point(448,238); $copyMachineButton.Size=New-Object Drawing.Size(210,48)
$copyMachineButton.BackColor=[Drawing.Color]::FromArgb(113,73,154); $copyMachineButton.ForeColor=[Drawing.Color]::White; $copyMachineButton.FlatStyle='Flat'
$copyMachineButton.Add_Click({ Copy-MachineListArgument })
$applyTab.Controls.Add($copyMachineButton)
$guideButton = New-Object Windows.Forms.Button
$guideButton.Text='開啟完整操作說明'; $guideButton.Location=New-Object Drawing.Point(676,238); $guideButton.Size=New-Object Drawing.Size(190,48)
$guideButton.Anchor = 'Top, Right'
$guideButton.Add_Click({ Open-Guide })
$applyTab.Controls.Add($guideButton)
$safetyLabel = New-Object Windows.Forms.Label
$safetyLabel.Text = '安全界線：不會自動關閉防火牆、不會寫入未公開的 .acf，也不會自動送出正式求解。'
$safetyLabel.Location = New-Object Drawing.Point(32,310); $safetyLabel.Size = New-Object Drawing.Size(840,28); $safetyLabel.ForeColor = [Drawing.Color]::FromArgb(174,91,0)
$safetyLabel.Anchor = 'Top, Left, Right'
$applyTab.Controls.Add($safetyLabel)

$repairTab = New-Object Windows.Forms.TabPage
$repairTab.Text = '⑤ 連線修復'; $repairTab.BackColor = [Drawing.Color]::White
$tabs.TabPages.Add($repairTab) | Out-Null
$repairHint = New-Object Windows.Forms.Label
$repairHint.Text = '兩台電腦都要各執行一次。會跳出 Windows UAC；只要按「是」，不必輸入指令。'
$repairHint.Location = New-Object Drawing.Point(24,20); $repairHint.Size = New-Object Drawing.Size(840,30); $repairHint.ForeColor = [Drawing.Color]::FromArgb(38,89,130)
$repairHint.Anchor = 'Top, Left, Right'
$repairTab.Controls.Add($repairHint)
$repairTempBox = Add-Field $repairTab '共同暫存路徑' 72 'C:\AnsysWork\AedtTemp' -BrowseFolder
$repairPeerBox = Add-Field $repairTab '對端電腦名稱' 120 ''
$repairInfo = New-Object Windows.Forms.Label
$repairInfo.Text = "依序執行：① 完整修復 TEMP／連接埠／防火牆。② 在 Intel MPI 視窗註冊帳密並驗證對端。`r`n密碼由 Intel MPI 直接讀取，工具不會接收、保存或寫入檔案；不會改 hosts。"
$repairInfo.Location = New-Object Drawing.Point(24,168); $repairInfo.Size = New-Object Drawing.Size(840,58); $repairInfo.ForeColor = [Drawing.Color]::FromArgb(45,52,60)
$repairInfo.Anchor = 'Top, Left, Right'
$repairTab.Controls.Add($repairInfo)
$repairButton = New-Object Windows.Forms.Button
$repairButton.Text='套用完整修復（管理員）'; $repairButton.Location=New-Object Drawing.Point(520,246); $repairButton.Size=New-Object Drawing.Size(315,50)
$repairButton.Anchor = 'Top, Right'
$repairButton.BackColor=[Drawing.Color]::FromArgb(190,82,44); $repairButton.ForeColor=[Drawing.Color]::White; $repairButton.FlatStyle='Flat'
$repairButton.Add_Click({ Start-ElevatedRepair })
$repairTab.Controls.Add($repairButton)
$mpiCredentialButton = New-Object Windows.Forms.Button
$mpiCredentialButton.Text='註冊 MPI 帳密並驗證'; $mpiCredentialButton.Location=New-Object Drawing.Point(24,246); $mpiCredentialButton.Size=New-Object Drawing.Size(315,50)
$mpiCredentialButton.BackColor=[Drawing.Color]::FromArgb(0,103,184); $mpiCredentialButton.ForeColor=[Drawing.Color]::White; $mpiCredentialButton.FlatStyle='Flat'
$mpiCredentialButton.Add_Click({ Start-MpiCredentialRegistration })
$repairTab.Controls.Add($mpiCredentialButton)
$repairGuide = New-Object Windows.Forms.Label
$repairGuide.Text = '兩台都完成完整修復與 MPI 驗證後，重新啟動 Windows，再回到「① 節點檢查」。'
$repairGuide.Location = New-Object Drawing.Point(24,315); $repairGuide.Size = New-Object Drawing.Size(840,30); $repairGuide.ForeColor = [Drawing.Color]::FromArgb(174,91,0)
$repairGuide.Anchor = 'Top, Left, Right'
$repairTab.Controls.Add($repairGuide)

$logLabel = New-Object Windows.Forms.Label
$logLabel.Text='執行結果'; $logLabel.Location=New-Object Drawing.Point(20,505); $logLabel.AutoSize=$true; $logLabel.Font=New-Object Drawing.Font('Microsoft JhengHei',11,[Drawing.FontStyle]::Bold)
$form.Controls.Add($logLabel)
$openFolderButton = New-Object Windows.Forms.Button
$openFolderButton.Text='開啟輸出資料夾'; $openFolderButton.Location=New-Object Drawing.Point(787,498); $openFolderButton.Size=New-Object Drawing.Size(170,34); $openFolderButton.Add_Click({Open-OutputFolder})
$openFolderButton.Anchor = 'Top, Right'
$form.Controls.Add($openFolderButton)
$logBox = New-Object Windows.Forms.RichTextBox
$logBox.Location=New-Object Drawing.Point(20,540); $logBox.Size=New-Object Drawing.Size(937,158); $logBox.ReadOnly=$true; $logBox.BackColor=[Drawing.Color]::FromArgb(25,33,42); $logBox.ForeColor=[Drawing.Color]::FromArgb(225,232,239); $logBox.Font=New-Object Drawing.Font('Microsoft JhengHei',9); $logBox.WordWrap=$false
$logBox.Anchor = 'Top, Bottom, Left, Right'
$form.Controls.Add($logBox)
$progressBar = New-Object Windows.Forms.ProgressBar
$progressBar.Style='Marquee'; $progressBar.MarqueeAnimationSpeed=35; $progressBar.Location=New-Object Drawing.Point(20,711); $progressBar.Size=New-Object Drawing.Size(180,16); $progressBar.Visible=$false
$progressBar.Anchor = 'Bottom, Left'
$form.Controls.Add($progressBar)
$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Text='準備完成。請先執行「① 節點檢查」。'; $statusLabel.Location=New-Object Drawing.Point(218,706); $statusLabel.Size=New-Object Drawing.Size(735,30); $statusLabel.ForeColor=[Drawing.Color]::FromArgb(70,78,86)
$statusLabel.Anchor = 'Bottom, Left, Right'
$form.Controls.Add($statusLabel)

foreach ($tabPage in @($nodeTab, $mergeTab, $configTab, $applyTab, $repairTab)) {
    $tabPage.AutoScroll = $true
    $tabPage.AutoScrollMinSize = New-Object Drawing.Size(900, 340)
}

function Update-ResponsiveLayout {
    $clientWidth = $form.ClientSize.Width
    $clientHeight = $form.ClientSize.Height
    $contentWidth = [Math]::Max(700, $clientWidth - 36)
    $tabs.Height = [Math]::Max(300, [Math]::Floor($clientHeight * 0.5))
    $tabs.Width = $contentWidth

    $logTop = $tabs.Bottom + 12
    $logLabel.Top = $logTop + 7
    $openFolderButton.Top = $logTop
    $openFolderButton.Left = [Math]::Max(570, $clientWidth - 193)

    $logBox.Top = $logTop + 42
    $logBox.Width = [Math]::Max(700, $clientWidth - 43)
    $logBox.Height = [Math]::Max(78, $clientHeight - $logBox.Top - 62)

    $progressBar.Top = $clientHeight - 49
    $statusLabel.Top = $clientHeight - 54
    $statusLabel.Width = [Math]::Max(475, $clientWidth - 245)
}

$form.Add_Resize({ Update-ResponsiveLayout })
Update-ResponsiveLayout

$processTimer = New-Object Windows.Forms.Timer
$processTimer.Interval=250
$processTimer.Add_Tick({
    if(-not $script:RunningProcess -or -not $script:RunningProcess.HasExited){return}
    $processTimer.Stop(); $exitCode=$script:RunningProcess.ExitCode; $stdout=$script:StdOutTask.Result; $stderr=$script:StdErrTask.Result
    if($stdout){Add-Log $stdout}; if($stderr){Add-Log ('錯誤輸出：'+[Environment]::NewLine+$stderr)}
    Add-Log ('-'*68); Add-Log ('完成，離開代碼：'+$exitCode)
    if($exitCode -eq 0){Set-RunningState $false ('完成：'+$script:CurrentAction+'。請閱讀報告內容。')}else{Set-RunningState $false ('未通過：'+$script:CurrentAction+'。請查看上方錯誤。')}
    $script:RunningProcess.Dispose(); $script:RunningProcess=$null
})
$form.Add_FormClosing({if($script:RunningProcess -and -not $script:RunningProcess.HasExited){$_.Cancel=$true;[Windows.Forms.MessageBox]::Show($form,'工具仍在執行，完成後才能關閉視窗。','請稍候')|Out-Null}})
[void]$form.ShowDialog()
