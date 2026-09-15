# AEDT 兩機串接 SOP（沒有網域／工作群組環境）

適用：客戶兩台電腦**不在網域裡**（工作群組、或用 Microsoft 帳戶登入）。

> **這份的來源說明**：步驟 3 以後與〈現場串機SOP〉相同，那些都是 2026-09-15 在
> 網域環境實測過的。**步驟 0～2 是工作群組特有的部分**，依據是 Intel MPI 官方文件
> 與 Windows 的既有行為，**尚未在客戶現場實測**。第一次用請預留除錯時間。

---

## 為什麼工作群組比較麻煩

網域環境裡，兩台電腦信任同一個網域控制站，`<網域>\<帳號>` 在哪台都是同一個人。

工作群組沒有這個共同信任。Windows 的做法是「**同名同密碼**就當成同一個人」——
所以兩台必須各自建立一個**名稱與密碼逐字相同**的本機帳號。

---

## 步驟 0　建立共用的本機帳號

**在兩台上各做一次**：

1. 設定 → 帳戶 → 其他使用者 → **新增帳戶**
2. 選「**我沒有這位人員的登入資訊**」→「**新增沒有 Microsoft 帳戶的使用者**」
3. 帳號名稱與密碼**兩台逐字相同**（建議 `ansys`）
4. 建好後把它改成「**系統管理員**」
5. **用這個帳號登入過一次**（建立使用者設定檔，之後註冊 MPI 帳密要用）

### Microsoft 帳戶不能用

如果客戶現在是用 Microsoft 帳戶（`@outlook.com`、公司 Microsoft 365）登入，
**不能拿它來做串機**：密碼存在雲端，兩台沒辦法設成一致，Intel MPI 的跨機認證過不去。

> 這是本工具會直接擋下來的情況之一——不要在這上面耗時間，建本機帳號比較快。

### 不用改客戶現在的登入習慣

客戶平常還是用他自己的帳號。這個 `ansys` 帳號只是拿來跑求解服務用的，
**不需要**叫他改用這個帳號登入日常工作。

---

## 步驟 1　讓遠端管理能動

工作群組下，**本機系統管理員帳號的遠端管理預設被 UAC 擋掉**——
`\對端\C$`、WMI 遠端查詢都會拒絕存取，即使帳密正確。

**在兩台上各執行一次**（系統管理員 PowerShell）：

```powershell
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWord -Force
```

**驗收**（從其中一台，用 `ansys` 帳號）：

```powershell
Test-Path '\對端\C$\Windows'
```

要回 `True`。

> 這一步不做的話，本工具的遠端檢查全部會失敗，而且錯誤訊息只會說「存取被拒」，
> 很容易誤判成密碼打錯。

---

## 步驟 2　名稱解析與網路位置

### 2-1　兩台要叫得到對方的名字

沒有網域就沒有 DNS。**先測**：

```powershell
Test-Connection -ComputerName 對端 -Count 2
```

不通的話，在**兩台**的 `C:\Windows\System32\drivers\etc\hosts` 各加一行對方的
IP 與電腦名稱（系統管理員權限才能存檔）：

```
192.168.10.21    WS02
```

> 之後的所有設定一律用**電腦名稱**，不要用 IP——AEDT 與 MPI 的機器清單都是用名稱比對。

### 2-2　網路位置必須是「私人」

「公用」網路下防火牆規則套不到，而且網路探索是關的。

```powershell
Get-NetConnectionProfile
```

`NetworkCategory` 要是 **Private**。是 Public 的話：

```powershell
Set-NetConnectionProfile -InterfaceAlias '乙太網路' -NetworkCategory Private
```

---

## 步驟 3 以後

**與〈現場串機SOP〉完全相同**，只有兩個地方要改寫法：

### MPI 帳密註冊時的帳號格式

工作群組沒有網域名稱，帳號填 `電腦名稱\ansys` 或 `.\ansys`：

```powershell
$mpi = 'C:\Program Files\ANSYS Inc\v261\AnsysEM\common\fluent_mpi\multiport\mpi\win64\intel21\bin\mpiexec.exe'
& $mpi -register
# account (domain\user): WS02\ansys
```

**一樣要在每一台上各註冊一次，而且要互動登入那台。** 這一點與網域環境完全相同，
而且是最容易漏的一步——漏了就會卡在
「Determining memory availability on distributed machines」不動、不報錯。

### RSM Service Options 的 Domain 欄位

| 欄位 | 填什麼 |
|---|---|
| User Name | `ansys` |
| Password | 該帳號的密碼 |
| Domain/Workgroup | **該台電腦自己的名稱**（例 `WS02`），不是工作群組名稱 |

---

## 工作群組環境的驗收

跟網域環境一樣，但**這兩項一定要先過**再往下：

```powershell
# 1. 遠端管理通不通（在 A 上跑）
Test-Path '\B\C$\Windows'                              # 要 True

# 2. MPI 雙向都要通
& $mpi -hosts A,B -n 2 -ppn 1 hostname                  # 在 A 上
& $mpi -hosts B,A -n 2 -ppn 1 hostname                  # 在 B 上
```

---

## 出發前請客戶準備

| 項目 | 說明 |
|---|---|
| 兩台各建一個**同名同密碼的本機系統管理員帳號** | 建議 `ansys`，**不能是 Microsoft 帳戶** |
| 該帳號**在兩台都登入過一次** | 沒有使用者設定檔就註冊不了 MPI 帳密 |
| 兩台的**遠端桌面都先開好** | 否則現場還要動對方電腦的安全性設定 |
| 兩台在**同一個網段、網路位置設為私人** | 公用網路下防火牆規則套不到 |

把這四項寄給客戶的 IT，比到現場再談省很多時間。

---

## 與網域環境的差異一覽

| 項目 | 網域 | 工作群組 |
|---|---|---|
| 帳號 | 一個網域帳號，兩台都設為本機系統管理員 | 兩台各建同名同密碼的本機帳號 |
| Microsoft 帳戶 | 不影響 | **不能用** |
| `LocalAccountTokenFilterPolicy` | 不需要 | **必須設為 1** |
| 名稱解析 | DNS 自動 | 可能要寫 `hosts` |
| `-register` 帳號格式 | `<網域>\<帳號>` | `WS02\ansys` |
| RSM 的 Domain 欄位 | 網域名稱 | 該台電腦名稱 |
| 每台都要各自 `-register` | **是** | **是**（完全相同） |
