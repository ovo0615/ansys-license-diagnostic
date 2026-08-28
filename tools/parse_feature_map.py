# -*- coding: utf-8 -*-
"""從 Ansys 原廠的 Product to License Increment Mapping PDF 產生 feature_map.json。

為什麼要自己產生
----------------
`-Product` 參數需要一份「產品 → increment」對照表。這份對照表的內容是 Ansys 的
專有資訊，**不隨本工具散布**，必須由你自己從原廠取得的 PDF 產生。

取得原廠 PDF
------------
登入 Ansys Customer Portal，於下列位置取得（各版次名稱略有不同）：
    Downloads > Installation and Licensing Help and Tutorials > Licensing
    尋找 "Product to License Increment Mapping"

用法
----
    python tools/parse_feature_map.py "C:\\path\\to\\Product To Feature Map.pdf"

產生的 feature_map.json 會放在本工具的根目錄，`-Product` 即可使用。
沒有這個檔案時工具仍可正常運作，只是 `-Product` 會停用。

需要的套件
----------
    pip install pymupdf
"""
import argparse
import json
import os
import re
import sys

try:
    import fitz  # PyMuPDF
except ImportError:
    print('缺少 pymupdf 套件，請先安裝：')
    print('    pip install pymupdf')
    sys.exit(2)

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# 這些頁碼是 2024-01-08 版（Reference Date 2023-12-21）的表格範圍。
# 原廠改版後頁數會變，程式會自動偵測；偵測失敗才退回這組預設值。
DEFAULT_TABLES = [('commercial', 2, 36), ('academic', 37, 179), ('legacy', 180, 184)]
DEFAULT_DESC = (185, 193)

SKIP_PAT = re.compile(
    r'^(Table \d:|Product$|Increment$|Count$|Description$|'
    r'.*ANSYS, Inc\. All rights reserved|of ANSYS, Inc\..*|'
    r'.*proprietary and confidential.*|'
    r'ansysinfo@ansys\.com|.*Southpointe.*|\(T\) \+1.*|Reference Date:)',
    re.I)

INC_PAT = re.compile(r'^[a-z0-9][A-Za-z0-9_.:+-]*$')
NUM_PAT = re.compile(r'^\d+$')

TABLE_TITLES = {
    1: 'commercial',
    2: 'academic',
    3: 'legacy',
    4: 'descriptions',
}


def detect_ranges(doc):
    """從每頁的 "Table N:" 標題自動推出四張表的頁碼範圍。"""
    first_page = {}
    for i in range(len(doc)):
        m = re.search(r'Table (\d):', doc[i].get_text())
        if m:
            n = int(m.group(1))
            if n not in first_page:
                first_page[n] = i + 1

    if not all(n in first_page for n in (1, 2, 3, 4)):
        return None, None

    tables = []
    for n in (1, 2, 3):
        start = first_page[n]
        end = first_page[n + 1] - 1
        tables.append((TABLE_TITLES[n], start, end))
    return tables, (first_page[4], len(doc))


def page_lines(doc, pno):
    out = []
    for raw in doc[pno - 1].get_text().split('\n'):
        s = raw.strip()
        if not s or SKIP_PAT.match(s):
            continue
        out.append(s)
    return out


def main():
    ap = argparse.ArgumentParser(
        description='從 Ansys Product to License Increment Mapping PDF 產生 feature_map.json')
    ap.add_argument('pdf', help='原廠 PDF 的路徑')
    ap.add_argument('-o', '--out', default=None,
                    help='輸出路徑，預設為工具根目錄的 feature_map.json')
    args = ap.parse_args()

    if not os.path.isfile(args.pdf):
        print('找不到檔案：%s' % args.pdf)
        sys.exit(1)

    out_path = args.out
    if not out_path:
        out_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            'feature_map.json')

    doc = fitz.open(args.pdf)

    ref_date = ''
    m = re.search(r'Reference Date:\s*(\S+)', doc[0].get_text())
    if m:
        ref_date = m.group(1)

    tables, desc_range = detect_ranges(doc)
    if tables is None:
        print('警告：無法自動偵測表格頁碼，改用 2024-01-08 版的預設值。')
        print('      若結果不合理，請確認 PDF 版本。')
        tables, desc_range = DEFAULT_TABLES, DEFAULT_DESC

    print('PDF 頁數       : %d' % len(doc))
    print('Reference Date : %s' % (ref_date or '(未偵測到)'))
    for cat, a, b in tables:
        print('  %-12s p.%d - p.%d' % (cat, a, b))
    print('  %-12s p.%d - p.%d' % ('descriptions', desc_range[0], desc_range[1]))
    print()

    products = {}
    for category, first, last in tables:
        current = None
        pending = None
        for pno in range(first, last + 1):
            for s in page_lines(doc, pno):
                if NUM_PAT.match(s):
                    if pending and current:
                        products[current]['increments'].append(
                            {'name': pending, 'count': int(s)})
                        pending = None
                    continue
                if INC_PAT.match(s):
                    if pending and current:
                        products[current]['increments'].append(
                            {'name': pending, 'count': 1})
                    pending = s
                    continue
                if pending and current:
                    products[current]['increments'].append({'name': pending, 'count': 1})
                    pending = None
                current = s
                if current not in products:
                    products[current] = {'category': category, 'increments': []}
        if pending and current:
            products[current]['increments'].append({'name': pending, 'count': 1})

    # Table 4：increment 說明，格式是「名稱 / 說明」兩行一組
    descs = {}
    pending = None
    for pno in range(desc_range[0], desc_range[1] + 1):
        for s in page_lines(doc, pno):
            if pending is None:
                if INC_PAT.match(s):
                    pending = s
                continue
            descs[pending] = s
            pending = None

    for k in [k for k, v in products.items() if not v['increments']]:
        del products[k]

    # 統計每個 increment 被幾個產品共用。共用越多鑑別度越低——診斷時要優先驗證
    # 只有少數產品用得到的那些，才分得出是哪個產品的問題。
    shared = {}
    for v in products.values():
        for i in v['increments']:
            shared[i['name']] = shared.get(i['name'], 0) + 1

    increments = {}
    for name in sorted(set(list(descs.keys()) + list(shared.keys()))):
        increments[name] = {'desc': descs.get(name, ''), 'sharedBy': shared.get(name, 0)}

    data = {
        'source': 'Ansys, Inc. Product to License Increment Mapping',
        'referenceDate': ref_date,
        'note': ('由使用者自行提供的 Ansys 原廠文件轉換而成，僅供本機授權診斷比對之用。'
                 '內容為 Ansys 專有資訊，請勿再散布。'),
        'products': products,
        'increments': increments,
    }

    with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(data, f, ensure_ascii=False, separators=(',', ':'), sort_keys=True)

    print('產品數         : %d' % len(products))
    for cat, _, _ in tables:
        print('  %-12s %d' % (cat, len([1 for v in products.values()
                                        if v['category'] == cat])))
    print('increment 條目 : %d' % len(increments))
    print()
    print('已輸出         : %s' % out_path)
    print('大小           : %d KB' % round(os.path.getsize(out_path) / 1024))

    if len(products) < 100:
        print()
        print('警告：解析出的產品數偏少，PDF 版面可能與預期不同，請人工確認結果。')


if __name__ == '__main__':
    main()
