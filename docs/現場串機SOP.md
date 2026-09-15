# AEDT 兩機串接 現場 SOP

適用：Windows、AEDT 2026 R1、兩台工作站、同一網域。
每一步都附驗收方式；**沒有通過就不要往下做**，否則最後會卡在一個沒有錯誤訊息的地方。

---

## 出發前

| 要帶的東西 | 說明 |
|---|---|
| 本工具包 | `一鍵串機.bat` 或 `Run-MpiToolkit-GUI.bat` |
| AEDT 安裝媒體 | 兩台版本不一致時要現場補，**同一個 Update 版本** |
| 客戶端要先準備 | 見下表三項，**請客戶在你到場前就弄好** |

### 請客戶先準備的三件事

| 項目 | 為什麼 |
|---|---|
| 一個**同一個網域帳號**，在**兩台都是本機系統管理員** | 註冊 MPI 帳密、啟停服務、開防火牆、改機器層環境變數都需要 |
| **兩台的遠端桌面都先開好** | 沒開的話現場還要動對方電腦的安全性設定，要再找人同意 |
| 該帳號**在兩台都登入過一次** | 沒有使用者設定檔就無法註冊 MPI 帳密 |

### 一台能做多少？

有了上面三項，**除了一件事以外全部可以在自己這台遠端完成**：

| 動作 | 遠端 | 方法 |
|---|---|---|
| 讀／啟停服務 | ✓ | `Get-WmiObject Win32_Service -ComputerName` |
| 讀寫機器層環境變數 | ✓ | `Win32_Environment` |
| 比對兩台檔案版本 | ✓ | `\對端\C$\...` |
| 執行任意指令 | ✓ | `Invoke-WmiMethod -Class Win32_Process -Name Create -ComputerName` |
| 防火牆規則 | ✓ | 透過上面遠端跑 PowerShell |
| 看行程 CPU／記憶體／完整命令列 | ✓ | `Win32_Process` |
| 清殘留行程 | ✓ | `$p.Terminate()` |
| 查 Windows 保留埠 | ✓ | 遠端跑 `netsh` |
| **`mpiexec -register`** | **✗** | **必須遠端桌面登入那台** |

`-register` 不能遠端做的原因：帳密寫在執行者自己的 HKCU；WMI／PsExec 啟動的行程
拿的是**網路登入權杖**，不會載入使用者設定檔。而且 Intel MPI 用 **DPAPI** 加密密碼，
DPAPI 需要使用者的主金鑰，網路登入權杖拿不到——症狀是
`Unable to uncrypt data, error: -2146892987`（`NTE_BAD_DATA`）。

所以現場節奏是：**RDP 進對端一次，只做步驟 3 的註冊與驗證（約 2 分鐘），其餘全部遠端。**

> 網域環境理論上可用 `I_MPI_AUTH_METHOD=delegate`（Kerberos 委派）完全免登入，
> 但需要 AD 把電腦帳戶設為「信任以進行委派」，**未實測**，不要到客戶端才第一次試。

---

## 步驟 1　版本必須逐檔一致

**光看 About 對話框不夠。** Service Pack 有可能宣告安裝成功但實際沒寫進去。

```powershell
# 兩台都跑，三個都要一樣
foreach ($f in 'ansysedt.exe','distrib_query_mpi.exe','HFSSCOMENGINE.exe') {
    $i = Get-Item "C:\Program Files\ANSYS Inc\v261\AnsysEM\$f"
    "{0,-24} {1,-12} {2}" -f $f, $i.VersionInfo.ProductVersion, $i.LastWriteTime
}
```

更嚴格的做法（從其中一台跑，B 換成對端名稱）：

```powershell
$L=@{}; $R=@{}
Get-ChildItem 'C:\Program Files\ANSYS Inc\v261\AnsysEM' -File | Where-Object Extension -match '\.(exe|dll)$' | ForEach-Object { $L[$_.Name]=$_.Length }
Get-ChildItem '\B\C$\Program Files\ANSYS Inc\v261\AnsysEM' -File | Where-Object Extension -match '\.(exe|dll)$' | ForEach-Object { $R[$_.Name]=$_.Length }
$L.Keys | Where-Object { $R[$_] -ne $L[$_] }
```

**驗收**：最後一行沒有輸出。

版本不一致時見〈排錯指南〉的「裝了 Service Pack 但版本沒變」。

---

## 步驟 2　服務

兩台都要：

| 服務 | 狀態 |
|---|---|
| `AnsoftRSMService` | Running、自動啟動 |
| `impi_hydra_*`（Intel MPI hydra） | Running、自動啟動 |

```powershell
Get-Service AnsoftRSMService, impi_hydra_* | Format-Table Name, Status, StartType
```

---

## 步驟 3　MPI 帳密：**每一台都要各自註冊**

這是最容易漏、而且漏了完全看不出來的一步。

**先確認要用哪一支 mpiexec。** AEDT 求解不是用 PATH 上那一支：

```powershell
Get-Item 'C:\Program Files\ANSYS Inc\v261\AnsysEM\common\fluent_mpi\multiport\mpi\win64\intel21\bin\mpiexec.exe'
```

**在每一台上，以實際要跑求解的帳號「互動登入」後執行**（遠端觸發不會載入該使用者的
設定檔，寫不進 HKCU）：

```powershell
$mpi = 'C:\Program Files\ANSYS Inc\v261\AnsysEM\common\fluent_mpi\multiport\mpi\win64\intel21\bin\mpiexec.exe'
& $mpi -register
```

**驗收**（在每一台上各跑一次）：

```powershell
& $mpi -validate                 # 要印出「這一台」的名字
& $mpi -validate -host <對端>    # 要 SUCCESS
```

> 第一行印出的主機名稱就是你現在所在的機器。如果你以為在 B 卻印出 A，
> 表示你開錯視窗了——這個錯很常犯。

---

## 步驟 4　埠與環境變數

兩台都設機器層環境變數，兩台的範圍**不要重疊**：

| 變數 | A | B |
|---|---|---|
| `ANSYSEM_LISTEN_PORT_RANGE` | 56000:56499 | 55000:55499 |
| `I_MPI_PORT_RANGE` | 56500:56999 | 55500:55999 |
| `I_MPI_HYDRA_SERVICE_PORT` | 8680 | 8680 |
| `ANSYS_EM_EXEC_DIR` | AEDT 安裝路徑 | 同左 |

**選埠之前先看 Windows 的保留範圍**，撞到會綁不到埠（WSAEACCES／10013）：

```powershell
netsh int ipv4 show excludedportrange protocol=tcp
```

設完要重開 AEDT（服務要重啟才會吃到新的機器層變數）。

---

## 步驟 5　防火牆

兩台都要放行（Domain 與 Private 設定檔）：

| 用途 | 埠 |
|---|---|
| RSM | 32958 |
| Intel MPI hydra 服務 | 8680 |
| AnsoftCOM 回連 | 該機的 `ANSYSEM_LISTEN_PORT_RANGE` |
| MPI 資料 | 該機的 `I_MPI_PORT_RANGE` |

**留意既有的 Block 規則。** 以前在 Windows 防火牆彈窗按過「取消」會留下
Inbound Block 規則，而 Block 的優先權高於 Allow：

```powershell
Get-NetFirewallApplicationFilter | Where-Object Program -match 'mpiexec|hydra|hf3d' |
  Get-NetFirewallRule | Where-Object Action -eq 'Block'
```

---

## 步驟 6　網路介面

**把 Hyper-V／WSL／Docker／VPN 的虛擬介面停用。**

AEDT 會挑一個本機位址告訴對端要回連到哪裡；挑到虛擬介面的位址時，對端沒有路由，
連不回來，求解就停在那裡。

```powershell
Disable-NetAdapter -Name 'vEthernet (Default Switch)' -Confirm:$false
# 求解結束後還原：
# Enable-NetAdapter -Name 'vEthernet (Default Switch)' -Confirm:$false
```

**改介面 Metric 沒有用。** 實測過：把虛擬介面 Metric 從 15 改成 60、實體維持 25，
重開 AEDT 之後遠端引擎拿到的仍然是虛擬介面的位址。AEDT 挑位址不看路由優先權，
只能讓那個位址不存在。

**驗收**：

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' }
```

理想狀況只剩下兩台互通的那個網段。

---

## 步驟 7　RSM 的執行身分

在**對端**開啟 RSM 設定（Ansoft RSM Service Options）：

| 欄位 | 值 |
|---|---|
| Ansoft Service Port | 32958 |
| Send analysis request as | **Specified User** |
| User Name / Password / Domain | 步驟 3 註冊的那個帳號 |

---

## 步驟 8　AEDT 的求解設定

**Simulation → HPC Options → Analysis Configuration → Distribution Types**

| 項目 | 設定 |
|---|---|
| Frequencies | 勾選 |
| Domain Solver | **取消** |

理由見〈為何關閉 Domain Solver〉。

**接著一定要改矩陣求解器**：在 Setup 上按右鍵 → Properties → Options → Solver，
把 `Auto Select Direct/Iterative` 改成 **`Direct Solver`**。手動 HPC 設定不接受
自動選擇，不改會直接報錯。

---

## 步驟 9　驗收

### 9-1　MPI 雙向都要通

**兩個方向都要測。** 只測單向會得到假的通過——求解時 mpiexec 跑在哪一台，
取決於 AEDT 把工作派給誰。

在 A 上：

```powershell
& $mpi -hosts A,B -n 2 -ppn 1 hostname
```

在 B 上：

```powershell
& $mpi -hosts B,A -n 2 -ppn 1 hostname
```

**兩次都要回傳兩台的名字、離開碼 0。**

### 9-2　小模型實跑

用一個幾分鐘能跑完的模型實際求解一次，觀察：

- 進度列有在動，不是停在同一行超過幾分鐘
- 對端有 `hf3d.exe` 或 `matrix_solution_*` 在跑，而且 CPU、記憶體會變化
- 求解暫存目錄的檔案時間戳一直在更新

---

## 收尾

| 項目 | 動作 |
|---|---|
| 虛擬網卡 | 還原（`Enable-NetAdapter`） |
| 遠端桌面 | 若為了設定而臨時開啟，記得關回去 |
| 殘留行程 | 清掉對端的 `HFSSCOMENGINE` / `mpiexec` / `hydra_*` |
| 交付 | 把〈為何關閉 Domain Solver〉給客戶 |
