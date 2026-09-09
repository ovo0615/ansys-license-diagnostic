#Requires -Version 5.1
<#
    測試共用的節點報告產生器。

    Test-AedtCluster.ps1 的彙整模式與 New-AedtClusterConfig.ps1 吃的是同一種
    .node.json，所以兩邊的測試共用這一份 fixture——兩份各自維護的話，
    很快就會漂移成兩種不一樣的「節點報告」，測試就不再代表真實輸入了。

    這個檔案只定義函式，不執行任何測試。
#>

function New-Node {
    param(
        [string] $Name,
        [string] $Release  = '2024 R2',
        [string] $Root     = 'C:\Program Files\AnsysEM\v242\Win64',
        [string] $TempDir  = 'C:\Temp',
        [bool]   $RsmRunning = $true,
        [string] $Mpi      = 'IntelMPI',
        [bool]   $MpiRunning = $true,
        [string] $MpiVersion = '2021.8.0',
        [string] $User     = 'ansys',
        [string] $Ip       = '192.168.10.10',
        [string] $Network  = '192.168.10.0/24',
        [string] $Os       = 'Microsoft Windows 11 Pro',
        [string] $OsVersion= '10.0.26100',
        [string] $OsBuild  = '26100',
        [int]    $RealNics = 1,
        [int]    $VirtualNics = 0,
        [object[]] $Peers  = @(),
        [string] $CaseId   = 'TEST-001',
        [int]    $Schema   = 1,
        [bool]   $NoAedt   = $false,
        [bool]   $NoTempDir= $false
    )

    $adapters = @()
    for ($i = 0; $i -lt $RealNics; $i++) {
        $adapters += [pscustomobject]@{
            alias = ('Ethernet' + $i); description = 'Intel Ethernet'
            ipv4 = $Ip; prefixLength = 24; gateway = '192.168.10.1'
            isVirtual = $false; network = $Network; networkGuessed = $false
        }
    }
    for ($i = 0; $i -lt $VirtualNics; $i++) {
        $adapters += [pscustomobject]@{
            alias = ('vEthernet ' + $i); description = 'Hyper-V Virtual Ethernet Adapter'
            ipv4 = '172.20.5.1'; prefixLength = 20; gateway = $null
            isVirtual = $true; network = '172.20.0.0/20'; networkGuessed = $false
        }
    }

    $aedt = @()
    if (-not $NoAedt) {
        $aedt += [pscustomobject]@{
            root = $Root; token = 'v242'; release = $Release; fileVersion = '24.2'
            sources = @('env'); cfgFound = $true
            tempDir = $(if ($NoTempDir) { $null } else { $TempDir })
            tempKind = 'local'; tempExists = $true; tempFreeGB = 400
        }
    }

    $mpiDetected = @()
    if ($Mpi) {
        $mpiDetected += [pscustomobject]@{
            vendor = $Mpi; kind = 'service'; name = 'hydra_service'
            status = $(if ($MpiRunning) { 'Running' } else { 'Stopped' })
            running = $MpiRunning; path = 'C:\x\hydra_service.exe'; version = $MpiVersion
        }
    }

    return [pscustomobject]@{
        schemaVersion = $Schema
        tool     = [pscustomobject]@{ name = 'AEDT 串機檢查工具'; version = '0.1.0' }
        caseId   = $CaseId
        generatedAt = '2026-09-07T10:00:00+08:00'
        anonymized  = $false
        facts    = [pscustomobject]@{}
        findings = @()
        actionable = @()
        notAutomatable = @()
        node = [pscustomobject]@{
            computerName = $Name; userName = $User; domain = 'WORKGROUP'
            os = $Os; osCaption = $Os; osVersion = $OsVersion; osBuildNumber = $OsBuild
            isAdmin = $true; mode = 'DDM'
            physicalCores = 16; logicalCores = 32; memoryGB = 128
            collectedAt = '2026-09-07T10:00:00+08:00'
            aedt = $aedt
            rsm  = [pscustomobject]@{
                installed = $true; running = $RsmRunning
                status = $(if ($RsmRunning) { 'Running' } else { 'Stopped' })
                services = @(); portListening = $RsmRunning; port = 32958
            }
            mpi  = [pscustomobject]@{ detected = $mpiDetected; binaries = @() }
            adapters = $adapters
            selfResolve = @($Ip)
            firewall = [pscustomobject]@{
                profiles = @(); anyProfileOff = $false; clusterRules = @()
            }
            peerProbes = $Peers
        }
    }
}
