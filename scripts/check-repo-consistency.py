#!/usr/bin/env python3
"""
仓库一致性自查 —— 发布前必须跑，退出码 0 才算完。

检查项：
  ① 文件齐全
  ② 脚本编码（bat 纯 ASCII，ps1 带 BOM）
  ③ 换行符（.bat/.ps1 必须 CRLF）
  ④ PowerShell 语法（需要 pwsh，没有则跳过）
  ⑤ SHA256SUMS 登记值与实际文件一致
  ⑥ 签名自洽（存在则必须验得过；缺失只警告）
  ⑦ 敏感信息扫描（个人路径、密钥形态）
  ⑧ 危险模式扫描

用法：python3 scripts/check-repo-consistency.py [--verbose]
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys

# Windows 上 Python 默认用 cp1252 输出，打印中文会抛 UnicodeEncodeError。
# 这个脚本要能在 GitHub Actions 的 windows-latest 上跑，所以主动切 UTF-8。
# （Linux/macOS 默认就是 UTF-8，这段是幂等的）
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REQUIRED = [
    "README.md", "README_cn.md", "CHANGELOG.md", "RELEASING.md", "LICENSE",
    "SKILL.md", "SKILL.en.md",
    "SHA256SUMS",
    "scripts/config.ps1.example",
    "scripts/0-初始化-双击我.bat", "scripts/init.ps1",
    "scripts/1-体检-双击我.bat", "scripts/doctor.ps1",
    "scripts/2-启动-双击我.bat", "scripts/start.ps1",
    "docs/known-issues.md",
]

# 需要登记进 SHA256SUMS 的文件（用户实际下载/执行的东西）
CHECKSUMMED = [
    "scripts/config.ps1.example",
    "scripts/0-初始化-双击我.bat", "scripts/init.ps1",
    "scripts/1-体检-双击我.bat", "scripts/doctor.ps1",
    "scripts/2-启动-双击我.bat", "scripts/start.ps1",
]

failures = []
warnings = []


def fail(msg):
    failures.append(msg)
    print(f"  \u274c {msg}")


def warn(msg):
    warnings.append(msg)
    print(f"  \u26a0\ufe0f  {msg}")


def ok(msg):
    print(f"  \u2705 {msg}")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


print("=" * 62)
print("  仓库一致性自查")
print("=" * 62)

# ---------- ① 文件齐全 ----------
print("\n① 文件齐全")
for rel in REQUIRED:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        fail(f"缺少 {rel}")
if not failures:
    ok(f"全部 {len(REQUIRED)} 个必需文件都在")

# ---------- ② 编码 ----------
print("\n② 编码")
for rel in CHECKSUMMED:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        continue
    raw = open(p, "rb").read()
    if rel.endswith(".bat"):
        try:
            raw.decode("ascii")
            ok(f"{rel} 纯 ASCII")
        except UnicodeDecodeError:
            fail(f"{rel} 壳里含非 ASCII 字符（cmd 会截断中文，中文必须放 ps1）")
    elif rel.endswith(".ps1") or rel.endswith(".example"):
        if raw[:3] != b"\xef\xbb\xbf":
            fail(f"{rel} 缺 UTF-8 BOM（PowerShell 5.1 会按 ANSI 解码，中文被吃掉）")
        else:
            ok(f"{rel} 带 BOM")

# ---------- ③ 换行符 ----------
print("\n③ 换行符")
for rel in CHECKSUMMED:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        continue
    raw = open(p, "rb").read()
    lone_lf = len(re.findall(rb"(?<!\r)\n", raw))
    if lone_lf:
        fail(f"{rel} 有 {lone_lf} 个裸 LF（Windows 脚本必须 CRLF）")
    else:
        ok(f"{rel} 全 CRLF")

# ---------- ④ PowerShell 语法 ----------
print("\n④ PowerShell 语法")
pwsh = shutil.which("pwsh")
if not pwsh:
    warn("没装 pwsh，跳过语法检查（CI 上会跑）")
else:
    for rel in CHECKSUMMED:
        if not rel.endswith(".ps1") and not rel.endswith(".example"):
            continue
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            continue
        cmd = (
            "$e=$null;$t=$null;"
            f"[System.Management.Automation.Language.Parser]::ParseFile('{p}',[ref]$t,[ref]$e)|Out-Null;"
            "if($e.Count -gt 0){$e|%{$_.Message};exit 1}else{exit 0}"
        )
        r = subprocess.run([pwsh, "-NoProfile", "-Command", cmd],
                           capture_output=True, text=True)
        if r.returncode == 0:
            ok(f"{rel} 语法通过")
        else:
            fail(f"{rel} 语法错误：{(r.stdout + r.stderr).strip()[:200]}")

# ---------- ⑤ 校验值 ----------
print("\n⑤ 校验值一致")
sums_path = os.path.join(ROOT, "SHA256SUMS")
recorded = {}
if os.path.exists(sums_path):
    for line in open(sums_path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([0-9a-f]{64})\s+\*?(.+)$", line)
        if m:
            recorded[m.group(2).strip()] = m.group(1)

if not recorded:
    fail("SHA256SUMS 是空的或格式不对")
else:
    for rel in CHECKSUMMED:
        p = os.path.join(ROOT, rel)
        if not os.path.exists(p):
            continue
        actual = sha256(p)
        if rel not in recorded:
            fail(f"SHA256SUMS 里没登记 {rel}")
        elif recorded[rel] != actual:
            fail(f"{rel} 哈希不匹配（登记 {recorded[rel][:12]}… 实际 {actual[:12]}…）—— 改了脚本就要重签")
        else:
            ok(f"{rel} 哈希一致")

# ---------- ⑥ 签名 ----------
print("\n⑥ 签名自洽")
sig = os.path.join(ROOT, "SHA256SUMS.minisig")
pub = os.path.join(ROOT, "minisign.pub")
if not os.path.exists(sig):
    warn("没有 SHA256SUMS.minisig —— 签名缺失（可用，但不推荐发布）")
elif not os.path.exists(pub):
    fail("有签名但没有 minisign.pub")
elif not shutil.which("minisign"):
    warn("没装 minisign，无法验证签名（CI 上会验）")
else:
    r = subprocess.run(["minisign", "-Vm", "SHA256SUMS", "-p", "minisign.pub"],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode == 0:
        ok("SHA256SUMS 签名验证通过")
    else:
        fail(f"签名验证失败：{(r.stdout + r.stderr).strip()[:200]}")

# ---------- ⑦ 敏感信息 ----------
print("\n⑦ 敏感信息扫描")
PERSONAL = [r"lukankan", r"C:\\Users\\[A-Za-z]", r"/root/", r"/home/[a-z]"]
SECRETS = [r"sk-[A-Za-z0-9]{20,}", r"ghp_[A-Za-z0-9]{20,}", r"nvapi-[A-Za-z0-9]"]
found_any = False
for rel in CHECKSUMMED + ["README_cn.md", "README.md", "docs/known-issues.md"]:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        continue
    text = open(p, encoding="utf-8", errors="ignore").read()
    for pat in PERSONAL + SECRETS:
        for m in re.finditer(pat, text):
            # config 模板里的 D:\models 是示例，允许
            snippet = text[max(0, m.start() - 20):m.end() + 20].replace("\n", " ")
            fail(f"{rel} 疑似敏感信息 /{pat}/ → …{snippet}…")
            found_any = True
if not found_any:
    ok("未发现个人路径或密钥形态的字符串")

# ---------- ⑧ 危险模式 ----------
print("\n⑧ 危险模式扫描")
DANGEROUS = [
    (r"iex\s*\(", "Invoke-Expression（动态执行字符串）"),
    (r"Invoke-Expression", "Invoke-Expression"),
    (r"curl[^|]*\|\s*(ba)?sh", "下载即执行"),
    (r"Remove-Item\s+-Recurse\s+-Force\s+[A-Z]:\\", "递归强删盘符根目录"),
]
danger_found = False
for rel in CHECKSUMMED:
    p = os.path.join(ROOT, rel)
    if not os.path.exists(p):
        continue
    text = open(p, encoding="utf-8", errors="ignore").read()
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#") or s.startswith("rem ") or s.lower().startswith("rem"):
            continue
        for pat, desc in DANGEROUS:
            if re.search(pat, line, re.I):
                fail(f"{rel} 含危险模式：{desc}")
                danger_found = True
if not danger_found:
    ok("未发现危险模式")

# ---------- 汇总 ----------
print("\n" + "=" * 62)
if failures:
    print(f"  \u274c 失败 {len(failures)} 项 / 警告 {len(warnings)} 项")
    print("=" * 62)
    sys.exit(1)
elif warnings:
    print(f"  \u26a0\ufe0f  通过，但有 {len(warnings)} 项警告")
    print("=" * 62)
    sys.exit(0)
else:
    print("  \u2705 全部通过")
    print("=" * 62)
    sys.exit(0)
