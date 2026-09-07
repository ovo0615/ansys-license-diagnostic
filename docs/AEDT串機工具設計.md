# AEDT 多工作站串機工具設計

把兩台以上的工作站串起來一起算 AEDT（HFSS / Maxwell / Q3D / Icepak），
能不能做成一個「按一下就連上」的工具？

**可以做，但不能做成單一顆按鈕。** 這份文件說明為什麼，以及該切成哪幾塊。

---

## 一、先把名詞分清楚

客戶說「串機」時，通常指三件不同的事。三件事的門檻差很多：

| 說法 | 實際機制 | 跨機時用不用 MPI |
| --- | --- | --- |
| 掃參數掃得快一點 | **DSO**（Distributed Solve Option）：把參數表的每一列丟到不同機器各算各的 | 純 DSO 分列時**不走 MPI** |
| 一個太大的模型單機記憶體不夠 | **DDM / 域分解**：把同一個模型的網格切開，分散到多台機器的記憶體 | **走 MPI**，機器之間要一直通訊 |
| 頻率掃描分散 | 頻點分散求解 | 走 MPI |

差別的實務意義：

- 只是要**掃得快**（多個變數組合、多個頻點），DSO 就夠，串機門檻相對低。
- 是**單一模型塞不進一台機器的 RAM**，才非 DDM + MPI 不可，這時網路品質直接決定成敗。

多數客戶其實只需要第一種，卻照著第二種的教學在設定，這是常見的卡點。
工具要做的第一件事就是問清楚是哪一種。

> 註：HFSS 若使用 solver domains 或有限陣列，頻率掃描就不會用 DSO 完成。

---

## 二、串機成立的必要條件

以下任何一項不成立，串機就會失敗，而 AEDT 的錯誤訊息通常不會直接告訴你是哪一項。
這份清單就是工具的檢查項目來源。

### 軟體與路徑

1. 每台機器裝**同一版本**的 AEDT。
2. 安裝路徑**每台相同**（或改成共用目錄）。
3. 每台都做過 **Register with RSM**（多版本共存時每個版本都要註冊）。
4. **temp 目錄每台路徑相同、但各自為本機磁碟**。
   設定在 `...\AnsysEM\AnsysEMxxx\Win64\config\default.cfg`，例如 `tempdirectory='C:\Temp'`。
   這一項是實務上最常被漏掉的。

### 帳號與權限

5. 每台機器**同一組使用者帳號與密碼**。
6. 若本機不參與求解、只負責派工，必須在
   `Tools > Options > General Options > Remote Analysis` 填入帳號密碼。

### 網路

7. 主機名稱可正確解析為 IP，每台機器**只有一張有效網卡在同一網段**
   （多網卡、VPN、Hyper-V 虛擬網卡是常見肇因）。
8. 防火牆放行：
   - **TCP 32958** — `AnsoftRSMService`（可在 Remote Analysis Options 改，預設就是它）
   - MPI 自己用的埠
   初次測試時建議先整個關掉，確認能通再逐條收緊。

### MPI

9. 選定 MPI 廠商並在**每台**裝好：
   - **Intel MPI**（近版預設）：Windows 上需要 `hydra_service.exe` 安裝且執行中，
     且 hydra_service 的版本要與要用的 Intel MPI 版本相符。
   - **Microsoft MPI**：AEDT 未指定廠商時的預設值。在
     `HPC and Analysis Options > Options` 設 `MPI Vendor = Microsoft`。
   - 舊版流程用的是 **IBM Platform MPI**。
   - **走 VPN 時 Intel MPI 容易失敗**，這種環境改用 MS-MPI 較穩。
10. Intel MPI 要註冊帳密：`mpiexec -register`，再用 `mpiexec -validate` 確認。

### 授權

11. Electronics Desktop 每份授權**內含 4 個 HPC unit**，第 5 個核心起才開始吃 HPC 授權。
12. HPC Pack 是**倍增**而非線性：第 1 個 pack 多開 8 核、第 2 個到 36 核、第 3 個到 132 核。
    因此**集中比分散划算**——同樣 4 個 pack：
    - 集中在 1 台：512 核
    - 分給 2 台（各 2 個）：72 核
    - 分給 4 台（各 1 個）：48 核

    第 12 項會直接推翻客戶的串機計畫：手上只有少量 HPC Pack 時，
    把 pack 攤到多台機器，總可用核心數反而變少。工具必須在動手前就把這件事講出來。

---

## 三、三條可行路徑

| 路徑 | 適用 | 代價 |
| --- | --- | --- |
| **RSM + AEDT GUI 機器清單** | 2～4 台工作站，沒有排程器 | 每台都要註冊 RSM、開 32958 埠 |
| **命令列 `-machinelist`** | 要排進批次、無人值守 | 需先把 MPI 與帳密弄好 |
| **排程器**（LSF / PBS / SGE / Windows HPC / Slurm） | 已有機房叢集 | 機器名由排程器給，不自己列 |

### 命令列的形態

批次分散求解用 `-BatchSolve` 搭配 `-Distributed`，機器由 `-MachineList` 指定。
`-MachineList` 只有在 `-Remote` 或 `-Distributed` 存在時才有意義，三種寫法：

1. **直接列**：`list="<機器1>,<機器2>,..."`，每台可再帶
   `主機:每節點task數:每節點核心數:使用率上限`（例如 `host:1:8:90%`）
2. **檔案**：一行一台機器名稱或位址
3. **排程器**：不列機器名，只指定要用幾個 distributed engine

完整選項以 `ansysedt -help` / `ansysedt -Batchoptions` 在目標版本上實際列出為準——
選項在版本之間有差異，工具不應硬寫。

### GUI 這一側

機器清單在 `HPC and Analysis Options` 的 machine list 分頁，可逐台填、也可從檔案匯入。
整組設定可匯出成 **`.acf`**，再匯入到別台機器或別的 design type。

原本規劃把 `.acf` 當成交付物，實作時放棄了——它的欄位結構沒有公開規格，
猜出來的檔案匯入後可能靜默套用錯誤設定。改成交付 `machines.txt`
（機器清單檔的格式在官方文件裡是明確的），由客戶匯入 machine list 分頁後
自己匯出一次 `.acf`。

---

## 四、工具怎麼切

沿用 License 診斷工具的分法：**唯讀的放公開、會改機器的放私有。**

### 1. `Test-AedtCluster.ps1`（公開，唯讀）— **已實作**

在每台預定參與的機器上各跑一次，輸出一份結構化 JSON；再由一台彙整比對。

檢查項直接對應第二節的 12 條：

| 檢查 | 做法 |
| --- | --- |
| AEDT 版本與安裝路徑 | 讀登錄檔 / 檔案系統 |
| RSM 是否註冊並執行 | 查 `AnsoftRSMService` 服務狀態 |
| temp 目錄設定 | 讀 `default.cfg` 的 `tempdirectory` |
| MPI 廠商與版本 | 查 `hydra_service` 服務、MS-MPI 安裝狀態 |
| 32958 埠可達 | 從彙整機對每台做 TCP 連線測試 |
| 網卡張數與網段 | 列出有效介面，多網段時標記 |
| 帳號一致性 | 比對各機回報的帳號名（不傳密碼） |
| 授權與 HPC Pack | 沿用現有 License 診斷工具的取得結果 |

輸出沿用現有的三級結論（**確定 / 可疑 / 需人工**）。
「講對省一趟支援，講錯要賠信任」在這裡同樣成立，甚至更嚴重——
串機設錯不是打不開，是算到一半掉，客戶損失的是機時。

彙整時的**跨機比對**才是這支工具真正的價值：
版本不一致、路徑不一致、temp 路徑不一致、網段不同——
這些單機自己看永遠看不出來。

實作後的兩點修正：

- **時鐘偏移拿掉了。** 各節點是在不同時間收集的，事後無法還原偏移；
  要做得靠遠端 WMI，那需要額外權限又會拖慢執行，代價不划算。
- **安裝路徑與 temp 的比對不放在「有共通版本」的分支裡。** 版本不一致時
  這些問題依然存在，客戶統一版本後會馬上撞上——一次講完比讓他跑第二輪划算。

### 2. `New-AedtClusterConfig.ps1`（公開，唯讀輸出）— **已實作**

吃節點報告，產生：

- `machines.txt` — `-MachineList file=` 用的機器清單，一行一台
- `verify-batchoptions.cmd` — 第一次使用前的選項驗證步驟
- `run-batch.cmd` — 批次分散求解命令
- `待辦清單.txt` — 還缺什麼、哪幾台被排除與原因

不碰任何機器，只產檔案。客戶可以先看過再決定要不要用。

實作後與原規劃的兩點差異：

- **`cluster.acf` 不產生。** `.acf` 的欄位結構沒有公開規格可以依循，
  猜出來的檔案匯入後可能**靜默套用錯誤設定**——那比沒有 acf 更難查。
  改成在待辦清單裡教客戶用 GUI 匯出一次，之後每台匯入同一份。
  拿到一份真實的 `.acf` 之後才有條件自動產生。
- **`run-batch.cmd` 的求解命令預設是註解掉的。** 選項拼法未經實機驗證，
  猜錯的批次檔會直接失敗，比沒有還糟。強制走一次 `verify-batchoptions.cmd`。

以及一個踩到的坑：**`%` 在 `.cmd` 裡必須寫成 `%%`**。
`list="WS01:1:16:90%,WS02:..."` 沒跳脫的話，`cmd` 會把 `%,WS02:1:16:90%`
當成變數展開，變數不存在就換成空字串——參數被靜默改成 `90`，不會有任何錯誤訊息。

### 3. `Initialize-AedtCluster.ps1`（私有，會修改機器）— 未實作

要以管理員身分在**每一台**跑。做的事：

- 註冊 RSM
- 安裝 / 啟動 `hydra_service`，或安裝 MS-MPI
- 寫入 `default.cfg` 的 `tempdirectory`
- 加防火牆規則（32958 + MPI）

每個動作**必須先備份、可回復**，比照 `docs/修復動作與復原.md` 的規格。
這支不可能無人值守：帳密註冊（`mpiexec -register`）本來就要人輸入。

---

## 五、「一鍵」到什麼程度

誠實的答案：

| 階段 | 能否自動 | 現況 |
| --- | --- | --- |
| 檢查現況、找出缺什麼 | **可以全自動** | 已實作 |
| 產生機器清單與批次命令 | **可以全自動** | 已實作 |
| 產生 `.acf` | 需要一份真實範本才能做 | 未做，見上 |
| 首次佈署（裝 MPI、註冊 RSM、開防火牆） | 半自動，每台要管理員跑一次、要人輸密碼 | 未實作 |
| 佈署完成後的日常連線 | **可以一鍵**——匯入 acf 或跑批次檔即可 | — |

也就是說：**第一次要人，之後才能一鍵。**
賣點應該放在「把兩天的試錯壓成一次檢查」，不是「按一下就串好」。

---

## 六、不做什麼

- **不自動改網路架構**。多網卡、VPN、跨網段是真實的環境限制，工具只指出、不擅自停用網卡。
- **不代客戶決定 HPC Pack 怎麼配**。工具算給他看集中 vs 分散的核心數差異，決定權在客戶。
- **不宣稱能讓串機變快**。串機能不能贏過單機，取決於網路頻寬與模型型態；
  DDM 在千兆網路上常常比單機還慢。這件事要在報告裡明講。

---

## 七、待實機驗證

這份文件的技術細節來自 Ansys 官方說明頁與論壇的公開資料，**尚未在實機驗證**。

已經有自動測試的部分（`tests\Run-AllTests.ps1`，67 項）：
彙整模式的每一條跨機比對規則、純計算函式、以及產生器的輸出安全性。
這些吃的都是 JSON、不碰機器，可以完全用合成資料驗。

**沒有任何自動測試的部分**：`Test-AedtCluster.ps1` 的節點收集模式。
它要讀 Windows 的服務、登錄檔、網卡、防火牆，只能在真的工作站上驗。
第一次到客戶端時要逐項核對報告內容是否與實際狀況相符。

逐項的實機驗證步驟寫在 **[串機工具-現場驗證清單](串機工具-現場驗證清單.md)**，
帶去現場照著打勾即可。

還必須在實機確認的事：

| # | 要確認什麼 | 沒確認的後果 | 目前怎麼處理 |
| --- | --- | --- | --- |
| 1 | `-MachineList` 各種寫法在**目標版本**的實際語法 | 批次檔直接失敗 | 求解命令產成註解，強制先跑 `verify-batchoptions.cmd` |
| 2 | `.acf` 的實際欄位結構 | 匯入後靜默套用錯誤設定 | 不產生，改教客戶自己匯出 |
| 3 | 近版 AEDT 是否預設帶 Intel MPI、`hydra_service` 是否隨裝 | 誤報「沒安裝 MPI」 | 服務找不到時只報【可疑】，並同時列出安裝目錄裡找到的 MPI 執行檔 |
| 4 | 2023 R1 之後 RSM 的角色是否有變 | 誤報「沒註冊 RSM」 | 同上，一律報【可疑】不報【確定】 |
| 5 | MPI 實際使用的埠範圍 | 防火牆規則開不準 | 只檢查 32958，MPI 的埠在建議裡寫成「所選 MPI 用的埠」 |

第 1、2 項的處理方式是刻意的：**產生器照樣做，但把不確定的部分留在關掉的狀態**，
比「等驗證完再做」早交付，也比「猜了就直接給客戶跑」安全。

---

## 參考資料

- [Running Ansys Electronics Desktop From a Command Line](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v242/en/Subsystems/Maxwell/Content/RunningMaxwellFromaCommandLine.htm)
- [Distributed Analysis (HFSS)](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v251/en/Subsystems/HFSS/Content/HPC/DistributedAnalysis.htm)
- [Setting up HFSS and Running Distributed Memory Solutions](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v251/en/Subsystems/HFSS/Content/HFSS/SettingupHFSSandRunningDistributedMemorySolutions.htm)
- [Setting HPC and Analysis Options](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v242/en/Subsystems/Mechanical/Content/Variables/SettingHPCandAnalysisOptions.htm)
- [Ansys EM Suite Windows Installation Guide](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v242/en/PDFs/AnsysEMInstallGuide-Windows.pdf)
- [How to install MS-MPI service on stand-alone machines（VPN 下 Intel MPI 會失敗）](https://innovationspace.ansys.com/knowledge/forums/topic/how-to-install-ms-mpi-service-on-stand-alone-machines-vpn-usage-may-result-in-analysis-failure-when-using-the-default-intel-mpi/)
- [Intel MPI Configuration for Remote Simulations](https://optics.ansys.com/hc/en-us/articles/5615899829907-Intel-MPI-Configuration-for-Remote-Simulations)
- [Best way to create a cluster of 4 computers for AEDT](https://forum.ansys.com/forums/topic/best-way-to-create-a-cluster-of-4-computers-for-ansys-electronics-desktopto-share-memory-and-cores)
- [HFSS HPC Setup 2021 R2 with Intel MPI](https://innovationspace.ansys.com/forum/forums/topic/hfss-hpc-setup-2021-r2-with-intel-mpi/)
- [Problem with parallel simulation using RSM in ANSYS EDT](https://forum.ansys.com/discussion/16581/problem-with-parallel-simulation-using-rsm-in-ansys-edt)
- [Ansys HPC Packs Explained（HPC Pack 倍增規則）](https://www.exxactcorp.com/blog/engineering-mpd/ansys-hpc-pack-for-cpus-and-gpus-explained)
- [Looking Under the Hood of Ansys HPC Licensing — PADT](https://www.padtinc.com/2024/02/16/ansys-hpc-licensing-explained/)
- [AnsysEDT — Alliance Doc（命令列與排程器整合）](https://docs.alliancecan.ca/wiki/AnsysEDT/en)
- [PyAEDT 文件](https://aedt.docs.pyansys.com/)
