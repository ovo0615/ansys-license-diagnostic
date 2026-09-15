#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
產生要複製到客戶電腦的工具包。

只放現場用得到的東西：入口 bat、核心腳本、SOP 與排錯指南。
測試、開發文件、CI 設定都不進去——客戶不需要，多放只會讓人不知道該點哪個。

用法：python tools/build_package.py
"""
import os
import sys
import zipfile
from datetime import date

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 放進包裡的東西。左邊是版本庫裡的路徑，右邊是解壓後的相對位置。
FILES = [
    # —— 入口 ——
    ('一鍵串機.bat', None),
    ('指定機組啟動器-範本.bat', None),
    ('執行串機檢查.bat', None),
    ('執行診斷.bat', None),
    ('Run-MpiToolkit-GUI.bat', None),
    ('Run-ClusterCheck.bat', None),
    ('Run-LicenseCheck.bat', None),
    # —— 核心腳本 ——
    ('Start-OneClickCluster.ps1', None),
    ('MpiToolkit-GUI.ps1', None),
    ('Test-AedtCluster.ps1', None),
    ('Repair-AedtClusterNode.ps1', None),
    ('New-AedtClusterConfig.ps1', None),
    ('Register-IntelMpiCredential.ps1', None),
    ('Check-AnsysLicense.ps1', None),
    # —— 說明 ——
    ('給客戶的說明.md', None),
    ('PACKAGE_MANIFEST.txt', None),
    ('LICENSE', None),
    ('docs/現場串機SOP.md', '說明文件/現場串機SOP.md'),
    ('docs/現場串機SOP-無網域.md', '說明文件/現場串機SOP-無網域.md'),
    ('docs/串機排錯指南.md', '說明文件/串機排錯指南.md'),
    ('docs/為何關閉Domain Solver.md', '說明文件/為何關閉Domain Solver.md'),
    ('docs/現場一鍵串機操作卡.md', '說明文件/現場一鍵串機操作卡.md'),
    ('docs/客戶端操作與驗證.md', '說明文件/客戶端操作與驗證.md'),
    ('docs/AEDT_2026R1_Two_PC_Setup_Guide.html', '說明文件/START_HERE.html'),
]


def main():
    stamp = date.today().strftime('%Y%m%d')
    out = os.path.join(ROOT, 'AEDT_Multi_PC_Toolkit_%s.zip' % stamp)

    missing = [src for src, _ in FILES if not os.path.isfile(os.path.join(ROOT, src))]
    if missing:
        # 少檔案就不要產生半套的包——帶到客戶端才發現少東西是最貴的。
        print('缺少下列檔案，中止：')
        for m in missing:
            print('  ' + m)
        return 1

    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for src, dst in FILES:
            z.write(os.path.join(ROOT, src), dst or src)

    size = os.path.getsize(out)
    print('已產生 %s' % os.path.basename(out))
    print('  %d 個檔案，%.0f KB' % (len(FILES), size / 1024.0))
    return 0


if __name__ == '__main__':
    sys.exit(main())
