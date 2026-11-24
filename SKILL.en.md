---
name: llama-cpp-launcher
description: Start llama.cpp local models on Windows. Menu-driven model pick, auto-tuned parameters, auto-matched vision projectors, and the cmd/PowerShell traps to avoid.
category: mlops
tags: [llama.cpp, windows, powershell, local-llm, gguf, launcher]
---

# llama.cpp Launcher

Windows startup scripts for local GGUF models. Three scripts, externalized config,
upgrades never overwrite the user's config.

## When to use

- A Windows user wants to run `llama-server` but can't recall the flag soup
- Multiple models/machines, needs menu selection
- Symptoms: `couldn't bind HTTP server socket`, `unknown architecture`,
  tool-calling loops, output repetition

## Layout

```
0-初始化配置-双击我.bat   -> init.ps1     creates config.ps1, opens editor
1-体检-双击我.bat         -> doctor.ps1   seven read-only checks
2-启动-双击我.bat         -> start.ps1    starts the server
config.ps1.example       config template
```

**The bat shells must be pure ASCII** (three lines, only `powershell -File`).
All UI text lives in the ps1 files. The ps1 files **must carry a UTF-8 BOM**,
or PowerShell 5.1 decodes them as ANSI and eats the quotes.

## Key design points

### Auto-select the llama.cpp build

Each release is a new directory (`llama-b11514`). The script scans `llama-b*`
and takes the highest build number, so upgrading means extracting a new directory —
no config change, and the old one stays available for rollback.
**Never make the user edit a path when upgrading.**

### Vision projector matching

Filenames vary wildly (`Huihui-Ornith-9B.mmproj-Q8_0.gguf`), so string assembly fails.
Normalize both sides, then compare:

1. strip `.gguf`, strip `mmproj`, strip quant tokens, strip `- _ . ( ) [ ] spaces`
2. exact equality first (strongest evidence), then mutual containment with a length gate

**The quant-token list must be ordered longest-first**: `BF16` before `F16`.
PowerShell `-replace` is case-insensitive, so `F16` first turns `bf16` into `b`
and the projector never matches. The bug is **symmetric** — when both sides carry
BF16, both lose the `b` and still match, so it can hide for a long time.

### Version parsing

```
version 0.4.1-dev (build 10964, commit b29c606e2)
```

**Take the number after `build`**, not the second word — that's the semantic
version `0.4.1-dev`, and stripping non-digits yields `041`, wrongly flagging a
perfectly fine b10964 as too old.

## Traps already hit (read before editing)

| Symptom | Cause | Fix |
|---|---|---|
| Tool calls loop forever | hybrid arch without `--jinja` | add `--jinja` |
| Output repeats itself | repeat penalty too low | raise `--repeat-penalty` to 1.1 |
| `unknown architecture` | llama.cpp too old | upgrade past `$MIN_BUILD` |
| Vision projector never matches | wrong normalization order | BF16 before F16 |
| `couldn't bind socket` | stale process holding the port | check port, offer to kill |
| OOM on large context | big ctx + unquantized KV | shrink ctx or use `q4_0` |
| `Cannot overwrite variable Host` | `$HOST` collides with built-in | rename `$LISTEN_HOST` |

Full list in `docs/known-issues.md`.

## Change discipline

- **Any edit to a `.ps1` / `.bat` requires regenerating `SHA256SUMS` and re-signing**,
  or CI fails immediately
- Signing can only be done by the private-key holder on their own machine
  (`minisign -S -s minisign.key -m SHA256SUMS`); the key never goes on a server
  and never through a chat
- Run `python3 scripts/check-repo-consistency.py` before releasing; exit code 0 or it isn't done
- English and Chinese docs must be updated together

## Verification (doable on Linux)

The `.bat` files can't run, but the `.ps1` files can — install `pwsh` and:

```bash
# syntax
pwsh -NoProfile -Command "[System.Management.Automation.Language.Parser]::ParseFile('start.ps1',[ref]\$null,[ref]\$e)"

# actually run: build a fake environment (fake gguf + fake llama-bXXXXX dirs + fake exe),
# then pipe input to simulate interaction
printf '1\n3\n' | pwsh -NoProfile -File ./start.ps1
```

**Do not skip this.** Static checks miss things that only surface on execution —
the `$Host` collision only appeared when the script actually ran.
