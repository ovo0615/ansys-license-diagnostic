# Ansys License 連線診斷工具

Ansys 軟體跳出「無法連上授權伺服器」時，在客戶端或授權伺服器上跑一次，
自動找出連線失敗的原因並產生報告。

**全程唯讀，不會修改任何設定。** 偵測到根因時只把修復指令列出來，由管理者自行判斷是否執行。

```
.\執行診斷.bat -Product HFSS
```

---

## 為什麼需要這個

使用者回報「軟體打不開」時，畫面上通常只有一句話——
`Workbench could not connect to a valid licensing server`、`Error -15`、`Connection time out`。

這句話不會告訴你是伺服器沒開、埠被別的軟體占走、防火牆擋住、License 過期、
HostID 對不上、授權被借光，還是用戶端指到了錯的主機。這支工具的作用，是把那一句話
變成一條可以走完的路徑。

---

## 三個等級的結論

工具只在證據充分時才下定論，不臆測：

| 等級 | 意義 | 例子 |
| --- | --- | --- |
| **【確定】** | 證據可唯一解釋現象 | 1055 埠被 `ptc_d.exe` 占用，所以 lmgrd 起不來 |
| **【可疑】** | 有異常但無法斷言是主因 | 連線逾時——**通常**是防火牆，但也可能是路由或負載 |
| **【需人工】** | 資料不足或架構未經驗證 | 偵測到 2020 R2 以前的舊架構 |

「講對省一趟支援，講錯要賠信任」——這個成本不對稱是整個設計的出發點。

---

## 需求

- Windows 10 / 11 或 Windows Server
- Windows 內建的 PowerShell 5.1（**不需要安裝任何東西**）
- 建議以系統管理員身分執行（一般權限也能跑，但查不到占用連接埠的程序名稱）

---

## 快速開始

1. 下載本專案（Code → Download ZIP）並解壓縮
2. 對 `執行診斷.bat` 按右鍵 → **以系統管理員身分執行**
3. 看畫面上的結論，報告會產生在 `reports\` 資料夾

要指定產品或案件編號時，從命令列執行（**`.\` 前綴不能省略**）：

```powershell
.\執行診斷.bat -Product HFSS -CaseId ACME-20260828
```

被資安軟體擋住時，改用：

```powershell
powershell -ExecutionPolicy Bypass -File .\Check-AnsysLicense.ps1
```

---

## 參數

| 參數 | 用途 |
| --- | --- |
| `-Product <名稱[,名稱]>` | 打不開的產品，例 `-Product HFSS`。需要 `feature_map.json`（見下方） |
| `-Feature <名稱[,名稱]>` | 已知 FlexNet increment 名稱時才用，例 `-Feature ansys` |
| `-CaseId <字串>` | 案件編號。伺服器端與用戶端兩份報告用同一個才對得起來 |
| `-Server <埠@主機[,...]>` | 只測指定的伺服器，不動用戶端設定。用來驗證特定一台 |
| `-SaveBaseline` | 在系統正常時建立基線，日後故障可做變更比對 |
| `-Expected <路徑>` | 指定基線檔，預設抓腳本旁的 `expected.json` |
| `-Anonymize` | 去識別化：使用者帳號、內網 IP、第三方程式名稱雜湊處理 |
| `-NoCheckout` | 不做實際取得授權的測試，只觀察 |
| `-OutDir <路徑>` | 報告輸出目錄，預設 `reports\` |

---

## 基線比對：最有用的功能

系統正常時（例如裝機驗收當天）先拍一張快照：

```powershell
.\Check-AnsysLicense.ps1 -SaveBaseline -CaseId ACME
```

日後故障時，工具就不需要猜「什麼才是對的」，直接指出**什麼變了**：

```
組態與基線不符，偵測到 3 項變更
  - 授權伺服器設定消失：1055@SRV-A
  - 授權伺服器設定新增：1055@SRV-B
```

很多案例本質上就是「本來好好的，有人改了什麼」。

---

## `-Product`：把「HFSS 打不開」翻成 increment

使用者只會說產品名稱，不會說 `elec_solve_hfss`。這個參數會查對照表找出該產品需要的
所有 increment，逐一比對伺服器上是否存在、是否已被借完，然後挑鑑別度最高的幾項
做實際取得測試。

只要缺少任何一項，該產品就開不起來，所以能分辨三種情況：

| 現象 | 判定 |
| --- | --- |
| 某些 increment 授權中根本沒有 | **確定**：未購買此產品，或 License 未更新 |
| 全部都有但某些已借完 | **確定**：目前被占用，附上查是誰在用的方法 |
| 全部都有且有空閒 | 正常：問題不在授權內容，往連線或設定查 |

### 對照表需要自行產生

`-Product` 需要 `feature_map.json`。這份對照表的內容是 **Ansys 專有資訊，
不隨本專案散布**，必須由你自己從原廠文件產生：

1. 登入 Ansys Customer Portal，取得 **Product to License Increment Mapping** PDF
   （Downloads → Installation and Licensing Help and Tutorials → Licensing）
2. 產生對照表：

```bash
pip install pymupdf
```

```bash
python tools/parse_feature_map.py "C:\path\to\Product To Feature Map.pdf"
```

沒有這個檔案時工具仍可正常運作，只是 `-Product` 會停用。

---

## 檢查流程

```
階段 0  環境與角色
        ANSYSLIC_DIR → 角色（lmgrd.exe / CVD 服務）→ 架構（ansysli_server.exe 存在?）
        舊架構 → 收集模式，跳過所有判定
階段 1  用戶端設定
        生效的 ansyslmd.ini → 使用者層級 ini → 殘留同名檔 → 環境變數
   1.5  ansysli_util -printlicpath   ← 權威來源，不靠讀檔猜
階段 2  連線（對 1.5 解析出的每台）
        lmutil lmstat -c → WinSock 子代碼分流
階段 3  授權可用性（連得上才做）
        lmstat -a（issued/in-use）
        -Product → 展開成 increment 清單 → 逐一比對 → 挑鑑別度最高的做 lmdiag
階段 4  雲端彈性授權 AEC（偵測到有在用才做）
        443 對外連線 / CLS 憑證 / 服務優先順序 / Proxy（密碼一律遮蔽）
階段 5  伺服器端（角色=Server 才做）
        服務 / 程序 / 埠占用者 / .lic 的 hostname 與 HostID / .opt / 防火牆
階段 6  基線差異比對
階段 7  判定分級 → HTML + TXT 報告
```

### WinSock 子代碼是關鍵

`lmstat` 失敗時的 WinSock 子代碼可以把 FlexNet `-15` 再切開，這比只看 `-15` 準得多：

| WinSock | 意義 | 判定 |
| --- | --- | --- |
| `10061` Connection refused | 主機活著，但該埠沒人聽 → lmgrd 沒起來或埠號錯 | **確定** |
| `11001` Host not found | 名稱解析失敗 | **確定** |
| `10060` Timed out | 封包被丟棄，**通常**是防火牆 | 可疑（不能斷言） |
| `10051` / `10065` / `10032` | 網路不可達 | **確定**（網路層問題） |

**拒絕（refused）與逾時（timeout）的差別，就是「服務沒起來」與「防火牆擋住」的差別。**

---

## 已驗證的技術事實

以下都在實機上驗證過，不是照文件推測的：

- `lmutil lmstat -c <埠>@<主機>` **從用戶端就能看到伺服器狀態**，包含 lmgrd 與
  vendor daemon 分別的死活。很多「伺服器端根因」在客戶端就測得到。
- `lmutil lmdiag -c ... -n <feature>` 會**實際嘗試取得授權**，並回傳到期日與
  `This license can be checked out`。這是唯一能端到端驗證的方法。
  不指定 feature 時會測**全部**（實機上 373 個），所以一定要指定。
- **2021 R1 起 Ansys Common Licensing（CVD）取代 Licensing Interconnect**，
  `ansysli_server` 不再存在、**埠 2325 不再使用**。判斷是不是舊架構就看
  `ansysli_server.exe` 在不在。
- **生效的 `ansyslmd.ini` 由 `ANSYSLIC_DIR` 決定。** 機器上常有多份殘留
  （舊 `AnsysEM\` 安裝樹、Motor-CAD），改到殘留那份就是「改了沒效果」。
- **沒有 `redirect.lic` 這種機制。** 電磁與結構流體共用同一份 `ansyslmd.ini`。
  舊文件說電磁要改 `AnsysEM\admin\redirect.lic` 是錯的。
- 使用者層級的 `%AppData%\.ansys_licensing\ansyslmd.ini` **優先度高於全域設定**。
  取值順序：環境變數 → 使用者 ini → 全域安裝設定。
- `ANSYSLMD_LICENSE_FILE` 是**插到伺服器清單最前面**，不是取代。所以症狀通常是
  「連到錯的伺服器」而非完全連不上。
- 現行版次的工具是 `LicensingSettings.exe`（`<install>\v2xx\licensingclient\winx64\`），
  舊文件說的 `ClientSettings.exe` 與 `Client ANSLIC_ADMIN Utility` 都已不存在。
  它有完整 CLI：`fnp server list/add/set`、`fnp borrow`、`preferences service`、
  `web elastic list`、`diagnostics`。

---

## 隱私

報告包含本機電腦名稱、作業系統、Ansys 安裝路徑與版次、授權伺服器主機名稱與埠號、
授權服務狀態與 feature 使用數量、License 檔案的 SERVER 行。

**不包含授權碼，也不包含 License 檔案的 INCREMENT 內容。**
`LicensingSettings web proxy list` 回傳的 Proxy 密碼欄位**無條件遮蔽**，
不受 `-Anonymize` 影響——報告是要寄出去的，憑證不能跟著走。

報告第一頁會列出該份報告實際包含哪些資訊，讓人確認後再決定是否外傳。
資安要求較嚴格時加上 `-Anonymize`，使用者帳號、內網 IP、第三方程式名稱會雜湊處理。

---

## 設計原則

改動任何功能前請先確認沒有違反：

1. **全程唯讀。** 只產生自己的報告檔。偵測到根因時輸出修復指令讓人自己貼。
   「本工具唯讀」這句話是通過資安審查的關鍵。
2. **結論分信心分級。**【確定】只在證據能唯一解釋現象時使用。
3. **原始碼可審閱。** 用 PowerShell 而非打包成 exe，就是為了讓資安部門看得到內容。
   不要改成編譯式散布。
4. **未驗證的架構不下結論。** 2020 R2 以前的 Interconnect 架構沒有測試環境，
   偵測到就退化成純收集模式。
5. **`.bat` 內容全 ASCII**（包含註解）。中文在 `chcp 65001` 下會被 console 吃字或重複。
   檔名是中文沒關係，是「內容」必須 ASCII。

---

## 開發注意事項

### PowerShell 5.1 限制

目標是 Windows 內建的 5.1，**不要用 7.x 才有的語法**：沒有 `??`、沒有三元運算子、
沒有 `&&` / `||`。

### 發布前檢查

```bash
python tools/check_release.py
```

檢查禁止入庫的檔案（`feature_map.json`、基線、報告、`.lic`）、殘留的客戶識別資訊、
以及編碼規則（`.ps1` 要有 UTF-8 BOM、`.bat` 要全 ASCII）。CI 跑的是同一支。

### 踩過的坑

**不要用 `$Args` 當參數名稱。** 那是 PowerShell 的自動變數。而且
`Start-Job -ArgumentList` 會把陣列攤平，導致外部命令**靜默地收不到參數**，不會報錯。
目前 `Invoke-Exe` 改用 `System.Diagnostics.Process`，順便拿到真正的逾時控制。

**`Get-Content` 的回傳值不是單純字串。** 它帶有 `PSPath`、`PSProvider` 等
NoteProperty，直接丟給 `ConvertTo-Json` 會把整個 provider 物件圖序列化出來——
實測基線檔從 913 bytes 爆成 **7.9 MB**。存進 JSON 前一定要 `.ToString()`。

**`Sort-Object` 不保證穩定排序。** 任何會影響判定結果的排序都要排到完全決定性為止，
否則同樣的輸入會挑到不同答案。

**`ANSYS Inc` 與 `Ansys Inc` 在 Windows 是同一個目錄**，掃描安裝路徑時不去重的話，
每個版次都會被偵測兩次、查詢白跑兩遍。

### 產品名稱有新舊兩套，內容差很多

| 名稱 | 類別 | increment 數 | 求解項 |
| --- | --- | --- | --- |
| `Ansys HFSS` | legacy | 14 | `hfss_solve` |
| `Ansys Electronics Premium HFSS` | commercial | 11 | `elec_solve_hfss` |

兩者只有 5 項相同。**所以比對產品時不能靠名稱猜**——工具把所有候選都比對一遍，
選「缺少項目最少」的那一個（客戶實際擁有的產品缺的一定最少），並在報告列出
所有候選供覆核。

---

## 尚未涵蓋

- **2020 R2 以前的架構**：只做偵測與資料收集，不下判定。要真正支援需要一台
  裝舊版 License Manager 的測試機。
- **AEC 的失敗情境**：解析與遮蔽邏輯已用真實輸出格式逐條驗證，但「AEC 真的壞掉」
  的情況沒有環境可測（開發機未啟用 AEC，而啟用會違反唯讀原則）。
- **對照表版本落差**：新產品或改名過的產品可能查不到，這種情況工具會標【需人工】
  而不會亂猜。

---

## 授權與免責

見 [LICENSE](LICENSE)。

本工具是基於實務經驗的診斷輔助，**非 Ansys 原廠官方文件**。各版次的路徑、選單名稱與
服務行為可能不同，實際操作請以所使用版次的 *Ansys, Inc. Licensing Guide* 為準。

Ansys、HFSS、SIwave、FlexNet 為各該公司之商標，本專案與 Ansys, Inc. 及 Flexera 無官方隸屬關係。

---

虎門科技股份有限公司　Taiwan Auto-Design Co.
技術支援：cae-support@cadmen.com
