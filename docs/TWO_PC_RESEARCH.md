# AEDT 2026 R1 雙機求解研究紀錄

## 結論

目前證據顯示，RSM 與 Intel MPI 已能跨機啟動；上次未完成不能直接判定為網路故障，因為遠端工作站在求解期間離線。明早最穩定的流程是：兩台先清除既有 AEDT／求解器、套用 RSM 的 MPI 環境、重新啟動、執行雙機快速測試，最後只在主控端開啟 AEDT 求解。

## 已核實事實

| 事實 | 依據 |
|---|---|
| RSM 搭配 MPI tight integration 時，`ANSYS_EM_EXEC_DIR` 必須指向 AEDT 安裝目錄，且要存在於 RSM 服務環境。 | [Ansys Windows Installation Guide](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v251/en/PDFs/AnsysEMInstallGuide-Windows.pdf)；本機 2026 R1 Help：`AnsysEMInstallGuide-Windows.pdf` 第 12 頁。 |
| MPI 求解要求各節點的 AEDT 安裝路徑相同；RSM 必須可連線，而且產品引擎必須註冊。 | [Ansys Remote Analysis](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v251/en/Subsystems/Circuit/Content/HPC/RemoteAnalysis.htm)；本機 2026 R1 HFSS Help 第 1822～1824 頁。 |
| 遠端機器需要相同 AEDT／Windows 版本與執行中的 RSM；正式求解前應用 Test Machines 確認沒有其他 Ansys EM 程序。 | [Ansys Distributed Analysis Configuration](https://ansyshelp.ansys.com/public/Views/Secured/Electronics/v252/en/Subsystems/HFSS3DLayout/Content/HPC/DistributedAnalysisConfigurationMachinesTab.htm)；本機 2026 R1 HFSS Help 第 1834～1836 頁。 |
| Intel MPI 的 `-register` 會加密帳密並存入登錄資料庫；`-validate -host` 驗證目前使用者對遠端的加密認證。 | [Intel MPI User Authorization](https://www.intel.com/content/www/us/en/docs/mpi-library/developer-guide-windows/2021-6/user-authorization.html)、[Intel MPI Global Hydra Options](https://www.intel.com/content/www/us/en/docs/mpi-library/developer-reference-windows/2021-13/global-hydra-options.html)。 |

## 本機實測

| 測試 | 結果 |
|---|---|
| Intel MPI 對端認證 | 通過。 |
| 遠端 `hostname`／`whoami` | 通過。 |
| 兩節點 `-n 2 -ppn 1` hostname | 兩台都有回應。 |
| TCP 32958／8680 | 對端在線時通過。 |
| AEDT 實際啟動 | 遠端 RSM 成功啟動 HFSSCOMENGINE 與 Intel MPI 程序鏈。 |
| 未完成原因 | 遠端工作站在測試期間離線，因此沒有完成求解。 |
| 本機缺口 | `ANSYS_EM_EXEC_DIR` 尚未設定；新版修復工具已補上。 |

## 明早判定標準

只有同時符合下列條件才開始正式求解：GUI 雙機快速測試全數通過、兩台沒有既有 AEDT／求解器、AEDT Test Machines 通過。正式求解時只在主控工作站開啟 AEDT；另一台只保留 RSM 與 Intel Hydra 服務。
