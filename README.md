# Ansys License 連線診斷工具（內部說明）

給客戶執行的自助診斷工具。客戶端的操作說明請看 [給客戶的說明.md](給客戶的說明.md)，
這一份是給我們自己看的。

---

## 設計原則

這五條是設計時定下來的，改動任何功能前請先確認沒有違反：

1. **全程唯讀。** 工具不修改客戶任何設定，只產生自己的報告檔。偵測到根因時輸出修復
   指令讓客戶自己貼。這句「本工具唯讀」是通過客戶資安審查的關鍵。
2. **結論分信心分級。** 【確定】只在證據能唯一解釋現象時使用。不確定就標【可疑】或
   【需人工】。**工具講錯話的成本不對稱**——講對省一趟支援，講錯要賠信任。
3. **原始碼可審閱。** 用 PowerShell 而非打包成 exe，就是為了讓客戶資安部門看得到內容。
   不要改成編譯式散布。
4. **未驗證的架構不下結論。** 2020 R2 以前的 Interconnect 架構我們沒有測試環境，
   偵測到就退化成純收集模式。
5. **`.bat` 全 ASCII。** 包含註解。中文在 `chcp 65001` 下會被 console 吃字或重複。

---

## 檔案

| 檔案 | 說明 |
| --- | --- |
| `Check-AnsysLicense.ps1` | 主程式。**必須是 UTF-8 with BOM**，否則 PowerShell 5.1 會用 cp950 解讀中文而壞掉 |
| `執行診斷.bat` | 啟動器。**必須全 ASCII** |
| `給客戶的說明.md` | 隨工具寄給客戶 |
| `expected.json` | 基線檔（**不進版本庫**，含客戶識別資訊） |
| `reports/` | 報告輸出（**不進版本庫**） |

---

## 參數

| 參數 | 用途 |
| --- | --- |
| `-CaseId <字串>` | 案件編號。伺服器端與用戶端兩份報告要用同一個才對得起來 |
| `-Feature <名稱[,名稱]>` | 實際測試能否取得該 feature（會短暫借一張再還） |
| `-Server <埠@主機[,...]>` | 覆寫要測試的伺服器，不動客戶設定。用來驗證特定一台 |
| `-Expected <路徑>` | 指定基線檔，預設抓腳本旁的 `expected.json` |
| `-SaveBaseline` | 建立基線（裝機驗收時用） |
| `-Anonymize` | 去識別化：使用者帳號、內網 IP、第三方程式名稱雜湊處理 |
| `-NoCheckout` | 即使給了 `-Feature` 也不做實際取用測試 |
| `-OutDir <路徑>` | 報告輸出目錄，預設 `reports\` |

---

## 標準流程

### 裝機驗收時（建立基線）

在客戶端與伺服器端各跑一次：

```powershell
.\Check-AnsysLicense.ps1 -SaveBaseline -CaseId <客戶代號>
```

把產生的 `expected.json` 跟工具一起留在客戶機器上。

**這一步是整個工具最有價值的地方。** 有基線之後，日後故障時工具不需要猜什麼是對的，
只要指出什麼變了：

> 授權伺服器設定消失：`1055@SRV-A`
> 授權伺服器設定新增：`1055@SRV-B`

### 客戶回報故障時

寄工具（含 `expected.json`，如果之前有建立）給客戶，請他們執行：

```powershell
.\Check-AnsysLicense.ps1 -CaseId <案件編號>
```

要驗證特定產品能不能取得授權時，加上 feature 名稱：

```powershell
.\Check-AnsysLicense.ps1 -CaseId <案件編號> -Feature ansys,anshpc
```

### 遠端指導時

要單獨驗證某一台伺服器，不必動客戶設定：

```powershell
.\Check-AnsysLicense.ps1 -Server 1055@LICSRV01
```

---

## 檢查 SOP

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
        lmstat -a（issued/in-use）→ 有空閒且有指定 feature → lmdiag（端到端 + 到期日）
階段 4  伺服器端（角色=Server 才做）
        服務 / 程序 / 埠占用者 / .lic 的 hostname 與 HostID / .opt / 防火牆
階段 5  基線差異比對
階段 6  判定分級 → HTML + TXT 報告
```

### WinSock 子代碼是關鍵

`lmstat` 失敗時的 WinSock 子代碼可以把 FlexNet `-15` 再切開，這比只看 `-15` 準得多：

| WinSock | 意義 | 判定 |
| --- | --- | --- |
| `10061` Connection refused | 主機活著，但該埠沒人聽 → lmgrd 沒起來或埠號錯 | **確定** |
| `11001` Host not found | 名稱解析失敗 | **確定** |
| `10060` Timed out | 封包被丟棄，**通常**是防火牆 | 可疑（不能斷言） |
| `10051` / `10065` / `10032` | 網路不可達 | **確定**（網路層問題） |

**拒絕（refused）與逾時（timeout）的差別就是「服務沒起來」與「防火牆擋住」的差別。**

---

## 已驗證的事實

以下都在實機上驗證過，不是照文件推測的：

- `lmutil lmstat -c <埠>@<主機>` **從用戶端就能看到伺服器狀態**，包含 lmgrd 與
  vendor daemon 分別的死活。很多「伺服器端根因」在客戶端就測得到。
- `lmutil lmdiag -c ... -n <feature>` 會**實際嘗試取得授權**，並回傳到期日與
  `This license can be checked out`。這是唯一能端到端驗證的方法。
- 不指定 feature 時 `lmdiag` 會測**全部** feature（實機上 373 個），所以一定要指定。
- `lmutil lmhostid` 取得本機 HostID，用來比對 License 檔案 SERVER 行綁定是否失效。
- **2021 R1 起 Common Licensing（CVD）取代 Licensing Interconnect**，`ansysli_server`
  不再存在、2325 不再使用。判定「舊架構」就看 `ansysli_server.exe` 在不在。
- **生效的 `ansyslmd.ini` 由 `ANSYSLIC_DIR` 決定。** 機器上常有多份殘留（舊 `AnsysEM\`
  安裝樹、Motor-CAD），改到殘留那份就是「改了沒效果」。
- **沒有 `redirect.lic`。** 電磁與結構流體共用同一份 `ansyslmd.ini`。
- 使用者層級 `%AppData%\.ansys_licensing\ansyslmd.ini` 優先度高於全域設定。

---

## 開發注意事項

### PowerShell 5.1 限制

目標環境是 Windows 內建的 PowerShell 5.1，**不要用 7.x 才有的語法**：
沒有 `??`、沒有三元運算子、沒有 `&&` / `||`。

### 兩個踩過的坑

**不要用 `$Args` 當參數名稱。** 那是 PowerShell 的自動變數。而且 `Start-Job
-ArgumentList` 會把陣列攤平，導致參數傳不進去——外部命令會靜默地收不到參數，
不會報錯。目前 `Invoke-Exe` 改用 `System.Diagnostics.Process`，順便拿到真正的逾時控制。

**`Get-Content` 的回傳值不是單純字串。** 它帶有 `PSPath`、`PSProvider` 等
NoteProperty，直接丟給 `ConvertTo-Json` 會把整個 provider 物件圖序列化出來——
實測基線檔從 913 bytes 爆成 **7.9 MB**。存進 JSON 前一定要 `.ToString()`。

### 編碼

```powershell
# .ps1 改完後確認 BOM 還在
$b = [IO.File]::ReadAllBytes('Check-AnsysLicense.ps1')
$b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF

# .bat 確認全 ASCII（檔名是中文沒關係，內容必須全 ASCII）
@([IO.File]::ReadAllBytes('執行診斷.bat') | Where-Object { $_ -gt 127 }).Count -eq 0
```

### 中文檔名沒有問題，但命令列要加 `.\`

`執行診斷.bat` 的中文檔名經實測可正常執行，console 中文在 `chcp 65001` 下也沒有
吃字或重複（維持每行 60 字元以內就不會觸發雙寬字元自動換行的問題）。

但**命令列呼叫時 `.\` 前綴不能省略**：

```powershell
.\執行診斷.bat -CaseId XXX      # 可以
執行診斷.bat -CaseId XXX        # 在停用 current-directory-in-path 的機器上找不到
```

這與檔名是不是中文無關，是 Windows 命令路徑解析的設定差異。客戶端說明文件裡的
範例都已經加上 `.\`。

---

## 尚未涵蓋（v2 候選）

- **AEC 雲端彈性授權**：443 埠、CLS ID/PIN、`preferences service` 優先順序、原廠維護
  狀態。這是完整的另一套邏輯，與本地伺服器幾乎不重疊。
- **2020 R2 以前的架構**：目前只做偵測與收集。要真正支援需要一台裝舊版 License Manager
  的測試機。
- **產品名稱對 feature 名稱的對照**：目前要人工指定 feature 名稱。客戶說「HFSS 打不開」
  時，還無法自動翻成 `elec_solve_level3` 之類的 feature 名。

---

虎門科技股份有限公司　Taiwan Auto-Design Co.
技術支援：cae-support@cadmen.com
