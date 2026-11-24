# llama.cpp 启动器

> 给不想跟命令行较劲的人用的 llama.cpp 启动脚本。

[English](README.md) | 简体中文

---

## 这东西解决什么

llama.cpp 的 `llama-server` 本身不复杂，问题是每次启动都得拼一长串参数：

```
llama-server.exe --model D:\models\Qwen3.5-9B-Q4_K_M.gguf --mmproj D:\models\Qwen3.5-9B-mmproj.gguf ^
  --port 1234 --host 127.0.0.1 --ctx-size 65536 --parallel 1 ^
  --cache-type-k q4_0 --cache-type-v q4_0 --n-gpu-layers 999 ^
  --temp 0.9 --top-p 0.95 --repeat-penalty 1.1 --repeat-last-n 256 --jinja
```

而且不同模型的参数还不一样 —— 有的必须带 `--jinja` 否则工具调用会死锁，
有的上下文开大会 OOM，有的要调高重复惩罚否则会碎嘴复读。
这些规则记不住，每次都要翻笔记。

这个脚本把选择过程变成菜单：

- 扫一遍模型目录，列出来让你选序号
- 认出模型架构，自动配好参数
- 找到配套的视觉投影文件（`mmproj`）并自动带上
- 上下文长度现场选：16K / 32K / 64K / 128K / 自定义
- 端口被占用会提示，看着像上次没退干净的 `llama-server` 可一键结束

## 快速开始

**环境要求**：Windows 10/11，PowerShell 5.1 以上（系统自带）

**第一步**：下载 [llama.cpp 的 Windows 版](https://github.com/ggml-org/llama.cpp/releases)

需要两个包，都在同一个 release 的 Assets 里：

- `llama-bXXXXX-bin-win-cuda-XX.X-x64.zip` — 主程序
- `cudart-llama-bin-win-cuda-XX.X-x64.zip` — CUDA 运行库（**漏了会报找不到 cudart64_XX.dll**）

解压成这种结构：

```
D:\models\
    llama-b11514\
        llama-server.exe
        llama-cli.exe
        ...（那一堆 dll）
    llama-b11537\          ← 以后升级就再解压一个新目录进来
        llama-server.exe
```

**第二步**：把模型（`.gguf`）放进同一个父目录下的任意位置

**第三步**：双击 `0-初始化配置-双击我.bat`，会生成 `config.ps1` 并打开记事本

**第四步**：在记事本里改两个路径，保存

```powershell
$MODELS_DIR = "D:\models"     # 模型在哪
$LLAMA_DIR  = "D:\models"     # llama.cpp 在哪
```

**第五步**：双击 `1-体检-双击我.bat` 确认环境没问题

**第六步**：双击 `2-启动-双击我.bat`，选模型、选上下文，服务就起来了

客户端地址是 `http://127.0.0.1:1234/v1`，任何 OpenAI 兼容客户端都能连
（SillyTavern、Cherry Studio、Open WebUI、Continue……）。

## 目录里都是什么

```
0-初始化配置-双击我.bat   生成 config.ps1（只需跑一次）
1-体检-双击我.bat         环境体检，只读不改
2-启动-双击我.bat         启动服务
config.ps1.example        配置模板
init.ps1                  初始化的本体
doctor.ps1                体检的本体
start.ps1                 启动器的本体
```

`.bat` 只有三行，纯英文，只负责叫起对应的 `.ps1`。
中文全在 `.ps1` 里 —— 这是被迫的，见下面「为什么不用纯 bat 实现」。

## 配置说明

全部在 `config.ps1` 里，每一项在文件内都有详细注释。常用的几个：

| 字段 | 作用 | 默认 |
|---|---|---|
| `$MODELS_DIR` | 模型目录，递归扫描 | 必填 |
| `$LLAMA_DIR` | llama.cpp 目录，找 `llama-bXXXXX` | 必填 |
| `$LISTEN_HOST` | 监听地址 | `127.0.0.1` |
| `$PORT` | 端口 | `1234` |
| `$CTX_OVERRIDE` | 强制上下文长度，留空=启动时选 | 空 |
| `$KV_CACHE_TYPE` | KV 量化，留空=自动 | 空 |
| `$API_KEY` | 设了就要带 Authorization | 空 |

⚠️ 改成 `0.0.0.0` 等于对局域网/全网开放，除非你有防火墙挡着。

## 支持哪些模型

脚本按模型文件名里的关键字分流。目前内置这些规则：

| 关键字 | 上下文 | 特殊处理 |
|---|---|---|
| `spark` / `x2.5` | 128K（Q8 权重降到 64K） | 带 `--jinja`，开思考，启动前自检构建号 |
| `minicpm5` | 128K | 带 `--min-p 0.0 --jinja`，temp 1.0 |
| `qwen3.5` | 16K | — |
| `ornith` | 16K | 带 `--jinja`（缺了工具调用会死锁），重复惩罚 1.1 |
| `e4b` | 16K | — |
| 其他 | 8K | 用默认采样参数 |

不在这张表里的模型也能跑，只是参数用默认值。上下文菜单永远可以手动选。

## 默认参数

不管什么模型，启动时都会带上：

```
--parallel 1              单并发（个人使用够，省显存）
--n-gpu-layers 999        全部层放显卡
--repeat-last-n 256       重复惩罚回看窗口
--temp 0.9 --top-p 0.95
```

## 显存参考

脚本不预设显存限制，只提示。实际能跑多大看量化档和上下文：

| 显存 | 大致能跑 | 建议上下文 |
|---|---|---|
| 8 GB | ≤12B 的 Q4 量化 | 16K～64K（KV 用 q4_0） |
| 12 GB | ≤14B Q4 / 9B Q8 | 32K～64K |
| 16 GB | ≤24B Q4 | 32K～128K |
| 24 GB+ | 30B 级 Q4 | 64K～128K |

显存不够时脚本会报 `failed to allocate`，把上下文压小、或把 `$KV_CACHE_TYPE` 设成 `q4_0`。

## 常见问题

**问：双击 bat 窗口闪一下就没了**

右键那个 bat → 编辑，把 `powershell ... -File` 那行末尾临时加个 `-NoExit`，再双击就能看到报错。

**问：报「找不到 llama-server.exe」**

`$LLAMA_DIR` 下面要是 `llama-bXXXXX` 这种带构建号的目录。如果你的解压出来多套了一层（`llama-b11514\llama-b11514\`），把里层挪上来。

**问：客户端连不上**

看启动窗口里打印的端口。1234 被占用时脚本会自动 +1，变成 1235 之类，客户端地址要跟着改。

**问：中文显示成方框**

`bat` 里已经切了 UTF-8。如果还有问题，在 PowerShell 里手动跑一次：
`chcp 65001` 然后 `powershell -File start.ps1`。

**问：能跑在 macOS / Linux 上吗**

不能。脚本用了 Windows 的 `Get-NetTCPConnection`、`nvidia-smi` 调用等。
Linux 用户直接用 `llama-server` 就好，那边的 shell 比 cmd 友好得多。

## 为什么不用纯 bat 实现

一开始就是纯 `.bat` 写的，实测两次都出问题：

**第一次**：UTF-8 编码的 bat 在 `cmd` 里，中文提示被半路截断，
剩下的半截被当成命令执行，报 `'某某某' is not recognized as an internal or external command`。
这不是编码选错了，是 `cmd` 处理多字节字符的固有限制 —— 文案一多就会踩。

**第二次**：换了 PowerShell 之后又撞上一个 —— 配置里我把监听地址
命名为 `$HOST`，而 `$Host` 是 PowerShell 的内置只读变量（变量名不区分大小写），
加载配置直接报 `Cannot overwrite variable Host`。改名 `$LISTEN_HOST` 解决。

现在的结构是「ASCII 壳 + PowerShell 本体」：
壳里一个中文字都没有，中文全部由 ps1 输出，两边各管一段，都不越界。

## 目录结构

```
├── 0-初始化配置-双击我.bat
├── 1-体检-双击我.bat
├── 2-启动-双击我.bat
├── config.ps1.example
├── init.ps1
├── doctor.ps1
├── start.ps1
├── minisign.pub            签名公钥
├── SHA256SUMS              各文件校验值
├── SHA256SUMS.minisig      校验值的签名
├── CHANGELOG.md
├── RELEASING.md            发布流程（改脚本必须重签）
├── LICENSE                 MIT
├── docs/
│   ├── known-issues.md     踩过的坑，改参数前先看
│   └── remote-mode.md      远程模式（进阶，尚未实现）
└── scripts/
    └── check-repo-consistency.py
```

## 校验下载内容

每次发布都签名。下载后可以自己验：

```bash
# 需要装 minisign
minisign -Vm SHA256SUMS -p minisign.pub
sha256sum -c SHA256SUMS
```

Windows 上：

```powershell
minisign.exe -Vm SHA256SUMS -p minisign.pub
Get-FileHash start.ps1 -Algorithm SHA256
```

公钥指纹：`B77452EF0FED6854`

## 许可证

MIT
