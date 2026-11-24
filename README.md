# llama.cpp Launcher

> Startup scripts for llama.cpp, for people who don't want to fight the command line.

English | [简体中文](README_cn.md)

---

## What this solves

`llama-server` itself is not complicated. The problem is that every launch needs a long train of flags:

```
llama-server.exe --model D:\models\Qwen3.5-9B-Q4_K_M.gguf --mmproj D:\models\Qwen3.5-9B-mmproj.gguf ^
  --port 1234 --host 127.0.0.1 --ctx-size 65536 --parallel 1 ^
  --cache-type-k q4_0 --cache-type-v q4_0 --n-gpu-layers 999 ^
  --temp 0.9 --top-p 0.95 --repeat-penalty 1.1 --repeat-last-n 256 --jinja
```

And the flags differ per model: some require `--jinja` or tool calling deadlocks
into a loop, some OOM at large contexts, some need a higher repeat penalty or
they start babbling in circles. Nobody remembers all of that.

These scripts turn it into a menu:

- Scan the model directory, list them, pick by number
- Detect the model family and set the parameters accordingly
- Find the matching vision projector (`mmproj`) and pass it automatically
- Choose the context length at launch: 16K / 32K / 64K / 128K / custom
- Detect port conflicts; kill a stale `llama-server` with one keypress, or shift ports

## Quick start

**Requirements**: Windows 10/11, PowerShell 5.1+ (ships with the OS)

**1.** Download [llama.cpp for Windows](https://github.com/ggml-org/llama.cpp/releases)

You need two archives from the same release:

- `llama-bXXXXX-bin-win-cuda-XX.X-x64.zip` — the binaries
- `cudart-llama-bin-win-cuda-XX.X-x64.zip` — CUDA runtime (**missing this gives
  "cannot find cudart64_XX.dll" at startup**)

Extract so each build gets its own directory:

```
D:\models\
    llama-b11514\
        llama-server.exe
        ...
    llama-b11537\      <- later upgrades just extract a new directory, no config change
        llama-server.exe
```

**2.** Put your `.gguf` models anywhere under the same parent directory

**3.** Double-click `0-初始化配置-双击我.bat` — it creates `config.ps1` and opens Notepad

**4.** Edit two paths, save

```powershell
$MODELS_DIR = "D:\models"     # where your models are
$LLAMA_DIR  = "D:\models"     # where llama.cpp lives
```

**5.** Double-click `1-体检-双击我.bat` to verify the environment

**6.** Double-click `2-启动-双击我.bat`, pick a model and context size

The server listens on `http://127.0.0.1:1234/v1` — any OpenAI-compatible client works
(SillyTavern, Cherry Studio, Open WebUI, Continue, etc.).

## Files

```
0-初始化配置-双击我.bat   creates config.ps1 (run once)
1-体检-双击我.bat         read-only environment check
2-启动-双击我.bat         starts the server
config.ps1.example        config template
init.ps1 / doctor.ps1 / start.ps1   the actual implementations
```

The `.bat` files are three lines each, pure ASCII, and only launch the matching `.ps1`.
All Chinese UI text lives in the `.ps1` files — see "Why not pure batch" below.

## Configuration

Everything is in `config.ps1`, documented inline. The ones you'll touch:

| Field | Purpose | Default |
|---|---|---|
| `$MODELS_DIR` | model directory, scanned recursively | required |
| `$LLAMA_DIR` | llama.cpp directory, looks for `llama-bXXXXX` | required |
| `$LISTEN_HOST` | bind address | `127.0.0.1` |
| `$PORT` | port | `1234` |
| `$CTX_OVERRIDE` | force a context size, empty = ask at launch | empty |
| `$KV_CACHE_TYPE` | KV quantization, empty = auto | empty |
| `$API_KEY` | if set, clients must send Authorization | empty |

Setting `$LISTEN_HOST` to `0.0.0.0` exposes the server to the network.
`llama-server` has no authentication unless you set `--api-key`.

## Supported models

**No filename guessing — it reads the model's own metadata.**

GGUF headers carry plain-text metadata. The launcher reads what it actually needs:

| Reads | Decides |
|---|---|
| `general.architecture` | architecture (`qwen3next` / `llama` / `qwen3` …) |
| `{arch}.context_length` | the model's real native context length |
| `tokenizer.chat_template` | is there a chat template → pass `--jinja` or not |
| `{arch}.vision.*` / `clip.has_vision_encoder` | does this model accept images |

So **there is no model-name list to maintain** — new models just work:

- **Context default = what the model declares** (capped at 128K).
  A model with an 8K native context will not be handed 64K; picking above
  the native limit prints an explicit warning.
- **`--jinja` only when a chat template exists** — that's the real determinant
  of whether tool calling works, far better than guessing from the filename.
- **Architecture containing `next` / `mamba` / `jamba` / `hybrid`** → hybrid
  attention, prone to repetition loops, repeat penalty raised to 1.1.
- **Vision-capable but no mmproj found** → warns that images won't work.
  The reverse (mmproj matched but model declares no vision) also warns.

If metadata can't be read (corrupt file, non-standard export), it falls back to
filename heuristics and says which route it took — the parameter block prints
`依据 : 元数据（qwen3next）` or `依据 : 文件名`.

Architectures that need extra flags the metadata doesn't carry keep special
handling: MiniCPM's `--min-p 0.0`, Spark's build-number self-check.

## Why not pure batch

It started as a pure `.bat` script. Both attempts failed in the field:

**First**: a UTF-8 `.bat` under `cmd` truncates multi-byte Chinese mid-character and
executes the remainder as a command — `'...' is not recognized as an internal or
external command`. This is not an encoding choice problem; it's a limitation of
how `cmd` handles multibyte text. The more UI text, the more reliably it breaks.

**Second**: after moving to PowerShell, the config used a variable named `$HOST` —
and `$Host` is a built-in read-only PowerShell variable (variable names are
case-insensitive), so loading the config failed with
`Cannot overwrite variable Host`. Renamed to `$LISTEN_HOST`.

The current structure is "ASCII shell + PowerShell body": the shell contains zero
non-ASCII characters, all UI text is emitted by the ps1. Each side stays in its lane.

## Known issues

See [docs/known-issues.md](docs/known-issues.md) — every entry there is a bug that
was actually hit, with the fix. Read it before changing the parameter-routing logic.

## Verifying downloads

Every release is signed:

```bash
minisign -Vm SHA256SUMS -p minisign.pub
sha256sum -c SHA256SUMS
```

On Windows:

```powershell
minisign.exe -Vm SHA256SUMS -p minisign.pub
Get-FileHash start.ps1 -Algorithm SHA256
```

Public key ID: `B77452EF0FED6854`

## License

MIT
