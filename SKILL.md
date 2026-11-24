---
name: llama-cpp-launcher
description: 在 Windows 上启动 llama.cpp 本地模型服务时用。菜单式选模型、自动配参数、自动找视觉投影文件，避开 cmd 中文截断和 $Host 只读变量等坑。
category: mlops
tags: [llama.cpp, windows, powershell, local-llm, gguf, launcher]
---

# llama.cpp 启动器

给 Windows 用户跑本地 GGUF 模型的启动脚本集。三个脚本，配置外置，升级不覆盖配置。

## 什么时候用这个

- 用户要在 Windows 上跑 `llama-server`，但记不住那一长串参数
- 用户有多台/多个模型，想菜单式选择
- 用户遇到 `couldn't bind HTTP server socket`、`unknown architecture`、
  工具调用死锁、模型复读这些症状

## 结构

```
0-初始化配置-双击我.bat   → init.ps1     生成 config.ps1 并打开编辑
1-体检-双击我.bat         → doctor.ps1   七项只读检查
2-启动-双击我.bat         → start.ps1    启动服务
config.ps1.example       配置模板（用户复制成 config.ps1）
```

**bat 壳必须纯 ASCII**（三行，只负责 `powershell -File`）。
中文全部在 ps1 里。ps1 必须带 UTF-8 BOM，否则 PowerShell 5.1 按 ANSI 解码会吃掉引号。

## 关键设计

### 自动挑选 llama.cpp 构建

llama.cpp 每次发版都是新目录（`llama-b11514`）。脚本扫 `llama-b*` 取构建号最大的：

```powershell
Get-ChildItem -Path $LLAMA_DIR -Directory -Filter "llama-b*" |
    ForEach-Object { if ($_.Name -match 'llama-b(\d+)') { ... } } |
    Sort-Object Num -Descending | Select-Object -First 1
```

升级 = 解压新目录进来，配置一行不用改，旧目录留着可回退。**别让用户改配置里的路径**。

### 视觉投影文件匹配

文件名五花八门（`Huihui-Ornith-9B.mmproj-Q8_0.gguf`），不能拼字符串。两边归一化后比对：

1. 去 `.gguf`、去 `mmproj`、去量化档 token、去 `- _ . ( ) [ ] 空格`
2. 先判**完全相等**（最强证据），再判**互相包含**（加最小长度闸门）

⚠️ **量化档列表必须长的在前**：`BF16` 排在 `F16` 之前。
PowerShell 的 `-replace` 不区分大小写，`F16` 在前会把 `bf16` 削成 `b`，
归一化结果错掉、视觉文件永远匹配不上 —— 而且这个 bug 是**对称的**，
两侧都带 BF16 时两侧都多一个 `b`，照样配上，能潜伏很久才爆。

### 版本号解析

```
version 0.4.1-dev (build 10964, commit b29c606e2)
```

**取 `build` 后面那个数**，不要取第二个词 —— 那是语义版本号 `0.4.1-dev`，
掐掉非数字变成 `041`，会把达标的 b10964 误判成版本过低。

## 已踩过的坑（改代码前必看）

| 症状 | 原因 | 修法 |
|---|---|---|
| 工具调用反复循环 | 混合架构缺 `--jinja` | 加 `--jinja` |
| 输出碎嘴复读 | 重复惩罚偏低 | `--repeat-penalty` 提到 1.1 |
| `unknown architecture` | llama.cpp 版本太老 | 升到 `$MIN_BUILD` 以上 |
| 视觉文件配不上 | 归一化列表顺序错 | BF16 排在 F16 前 |
| `couldn't bind socket` | 上次没退干净的进程占着端口 | 查端口 + 可一键结束 |
| 显存爆掉 | 大上下文 + KV 未量化 | 压 ctx 或 `q4_0` |
| `Cannot overwrite variable Host` | `$HOST` 撞内置只读变量 | 改名 `$LISTEN_HOST` |

完整清单见 `docs/known-issues.md`。

## 改动的纪律

- **改了任何 `.ps1` / `.bat` 就必须重算 `SHA256SUMS` 并重新签名**，否则 CI 直接红
- 签名只能用私钥持有者本机做（`minisign -S -s minisign.key -m SHA256SUMS`），
  私钥不上服务器、不进聊天记录
- 发布前跑 `python3 scripts/check-repo-consistency.py`，退出码 0 才算完
- 中英文文档必须同步改

## 验证方式（Linux 上也能做）

`.bat` 跑不了，但 `.ps1` 能 —— 服务器上装 `pwsh` 后：

```bash
# 语法
pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('start.ps1',[ref]\$null,[ref]\$e)"

# 真跑：搭假环境（假 gguf + 假 llama-bXXXXX 目录 + 假 exe），管道喂输入模拟交互
printf '1\n3\n' | pwsh -NoProfile -File ./start.ps1
```

**这一步不能省。** 静态检查抓不到的东西真跑一遍就露出来了
（`$Host` 那个 bug 只有执行时才报）。
