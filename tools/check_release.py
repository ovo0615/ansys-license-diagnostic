# -*- coding: utf-8 -*-
"""發布前檢查：禁止入庫的檔案、殘留的客戶識別資訊、以及編碼規則。

本機執行：
    python tools/check_release.py

CI 也是跑這一支，所以本機過了 CI 就會過。

結束代碼：0 = 全部通過，1 = 有問題。

需要的套件：無（只用標準函式庫）。

為什麼不用通用的機敏字掃描規則
------------------------------
這個專案的主題就是授權伺服器，所以 license server、customer portal、
C:\\Users\\<使用者>、192.168.x.x 這些字串本來就會大量出現，通用規則會全部誤報。
規則必須錨定「真的會指認出特定的人或機器」的樣式。
"""
import os
import re
import subprocess
import sys

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

failures = []
warnings = []


def fail(msg, detail=''):
    failures.append((msg, detail))


def tracked_files():
    """只檢查 git 追蹤中的檔案——沒進版本庫的東西不會被發布。"""
    try:
        out = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT)
    except Exception as e:
        print('無法執行 git ls-files：%s' % e)
        sys.exit(2)
    return [p for p in out.decode('utf-8').split('\0') if p]


# ---------------------------------------------------------------------------
# 1. 禁止入庫的檔案
# ---------------------------------------------------------------------------
FORBIDDEN = [
    (r'(^|/)feature_map\.json$',
     'Ansys 專有的產品對照表，不得公開發布（應由使用者自行從原廠 PDF 產生）'),
    (r'(^|/)expected\.json$', '基線檔含客戶主機名稱與授權設定'),
    (r'(^|/)baseline.*\.json$', '基線檔含客戶識別資訊'),
    (r'(^|/)reports/', '診斷報告含客戶識別資訊'),
    (r'\.lic$', 'License 檔案'),
    (r'\.opt$', 'FlexNet Options File'),
    (r'\.(msg|eml)$', '郵件檔'),
    (r'(^|/)ansyslmd\.ini$', '客戶的授權設定檔'),
    (r'\.(pem|key)$|(^|/)\.env', '憑證或環境設定檔'),
    (r'(^|/)AnsysLicense_.*\.(html|txt)$', '診斷報告'),
    (r'\.findings\.json$', '機器可讀的診斷結果，含客戶識別資訊'),
]


def check_forbidden(files):
    print('[1] 禁止入庫的檔案')
    hit = False
    for f in files:
        for pat, why in FORBIDDEN:
            if re.search(pat, f, re.I):
                fail('不該入庫的檔案：%s' % f, why)
                hit = True
    if not hit:
        print('    OK')
    print()


# ---------------------------------------------------------------------------
# 2. 客戶識別資訊
# ---------------------------------------------------------------------------
ALLOWED_EMAILS = {'jeff.hong@cadmen.com', 'cae-support@cadmen.com',
                  'ansysinfo@ansys.com'}

RULES = [
    ('Email 位址', r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'),
    ('MAC 位址 / HostID',
     r'\b[0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}[:-]'
     r'[0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}\b'),
    ('MAC 位址（無分隔）', r'\b[0-9a-f]{12}\b'),
    ('台灣市話 / 分機', r'\(?0[2-9]\)?[\s-]?\d{3,4}[\s-]?\d{4}'),
    ('台灣手機號碼', r'\b09\d{2}[\s-]?\d{3}[\s-]?\d{3}\b'),
    ('統一編號', r'統一?編號\s*[:：]?\s*\d{8}'),
    ('訂單 / 案號', r'\b(OE|SO|PO|SR)#?\s*\d{6,}'),
    ('具名主機',
     r'\b(DESKTOP-[A-Z0-9]{7}|WIN-[A-Z0-9]{11}|[A-Za-z][A-Za-z0-9]{2,}-PC)\b'),
    ('License INCREMENT 行', r'INCREMENT\s+\w+\s+ansyslmd'),
    ('License VENDOR_STRING', r'VENDOR_STRING\s*=\s*customer\s*:\s*\d+'),
    ('SERVER 行帶 HostID', r'^\s*SERVER\s+\S+\s+[0-9A-Fa-f]{12}\s'),
    ('個人使用者路徑', r'C:\\Users\\(?!<|%|~|\.\.\.)[A-Za-z][A-Za-z0-9._-]{2,}'),
    ('憑證樣式',
     r'(api[_-]?key|access[_-]?token|client[_-]?secret|private[_-]?key)\s*[=:]\s*\S+'),
    # 本公司名稱本來就會出現在報告抬頭，改用下面的 ALLOWED_COMPANIES 排除。
    # 這裡不能用 lookbehind——比對從公司名的第一個字開始，前面沒有東西可以看。
    ('公司名稱', r'[\u4e00-\u9fff]{2,12}(?:股份有限公司|有限公司|企業社)'),
]

ALLOWED_COMPANIES = {'虎門科技股份有限公司'}

TEXT_EXT = {'.md', '.txt', '.json', '.html', '.ps1', '.bat', '.py', '.yml',
            '.yaml', '.ini', '.xml', '.csv'}
TEXT_NAMES = {'LICENSE', '.gitignore', '.gitattributes'}
SELF = {'tools/check_release.py'}
MARKER = 'scan-ok'


def check_sensitive(files):
    print('[2] 客戶識別資訊')
    compiled = [(n, re.compile(p, re.M)) for n, p in RULES]
    hit = False
    for f in files:
        if f in SELF:
            continue
        ext = os.path.splitext(f)[1].lower()
        base = os.path.basename(f)
        if ext not in TEXT_EXT and base not in TEXT_NAMES:
            continue
        path = os.path.join(ROOT, f)
        try:
            with open(path, encoding='utf-8-sig') as fh:
                lines = fh.read().splitlines()
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(lines, 1):
            if MARKER in line:
                continue
            for name, rx in compiled:
                for m in rx.finditer(line):
                    v = m.group(0)
                    if name == 'Email 位址' and v.lower() in ALLOWED_EMAILS:
                        continue
                    if name == '公司名稱' and v in ALLOWED_COMPANIES:
                        continue
                    fail('%s:%d  %s -> %s' % (f, i, name, v), line.strip()[:100])
                    hit = True
    if not hit:
        print('    OK')
    print()


# ---------------------------------------------------------------------------
# 3. 編碼規則
# ---------------------------------------------------------------------------
def check_encoding(files):
    print('[3] 編碼規則')
    ok = True
    for f in files:
        path = os.path.join(ROOT, f)
        if not os.path.isfile(path):
            continue
        data = open(path, 'rb').read()

        # .ps1 含中文，必須是 UTF-8 with BOM。PowerShell 5.1 沒有 BOM 會用 cp950
        # 解讀，中文變亂碼並連帶把字串引號解析壞掉。
        if f.lower().endswith('.ps1'):
            if not data.startswith(b'\xef\xbb\xbf'):
                fail('%s 缺少 UTF-8 BOM' % f,
                     'PowerShell 5.1 會改用 cp950 解讀，中文會壞掉')
                ok = False

        # .bat 必須全 ASCII（連註解都是）。chcp 65001 下非 ASCII 會被 console
        # 吃字或重複顯示。中文檔名沒問題，是「內容」必須 ASCII。
        if f.lower().endswith('.bat'):
            bad = [b for b in data if b > 127]
            if bad:
                fail('%s 含 %d 個非 ASCII 位元組' % (f, len(bad)),
                     'chcp 65001 下 console 會吃字或重複顯示')
                ok = False

        # 控制字元：反斜線在某些 shell 的 heredoc 裡被吃掉一層之後，
        # \a \v \b 會變成真正的控制字元寫進檔案，螢幕上看不出來但路徑已經壞了。
        if f.lower().endswith(('.md', '.ps1', '.py', '.bat', '.json')):
            for n, raw in enumerate(data.split(b'\n'), 1):
                for b in raw:
                    if b < 0x20 and b not in (0x09, 0x0D):
                        fail('%s:%d 含控制字元 0x%02X' % (f, n, b),
                             '很可能是反斜線被吃掉造成的路徑損壞')
                        ok = False
                        break
    if ok:
        print('    OK')
    print()


# ---------------------------------------------------------------------------
def main():
    files = tracked_files()
    print('檢查 %d 個追蹤中的檔案' % len(files))
    print('=' * 68)
    print()
    check_forbidden(files)
    check_sensitive(files)
    check_encoding(files)

    print('=' * 68)
    if failures:
        print('發現 %d 個問題：' % len(failures))
        print()
        for msg, detail in failures:
            print('  ! %s' % msg)
            if detail:
                print('      %s' % detail)
        print()
        print('確認為誤判時，可在該行加上 scan-ok 標記並寫明理由。')
        sys.exit(1)

    print('全部通過。')
    sys.exit(0)


if __name__ == '__main__':
    main()
