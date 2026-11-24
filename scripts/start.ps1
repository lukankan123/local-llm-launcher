#requires -Version 5.1
# =====================================================================
#  start.ps1 - llama.cpp 启动器
#
#  流程：加载配置 → 找 llama-server → 选模型 → 配视觉文件
#        → 按架构配参数 → 选上下文 → 查端口 → 启动服务
#
#  配置全在 config.ps1，本脚本不含任何路径假设。
# =====================================================================

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Write-Sep  { Write-Host ("=" * 60) -ForegroundColor DarkGray }
function Write-Dash { Write-Host ("-" * 40) -ForegroundColor DarkGray }

function Pause-Exit {
    param([int]$Code = 0)
    Write-Host ""
    try {
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
            Write-Host "按任意键继续..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
    } catch { }
    exit $Code
}

# =====================================================================
#  加载配置
# =====================================================================
Write-Host ""
Write-Sep
Write-Host "  llama.cpp 启动器" -ForegroundColor White
Write-Sep

$cfg = Join-Path $PSScriptRoot "config.ps1"
if (-not (Test-Path $cfg)) {
    Write-Host ""
    Write-Host "  X  找不到 config.ps1" -ForegroundColor Red
    Write-Host "     把 config.ps1.example 复制成 config.ps1，再改路径。" -ForegroundColor Gray
    Write-Host "     想先看环境有没有问题，可以跑 doctor.bat。" -ForegroundColor Gray
    Pause-Exit 1
}
try {
    . $cfg
} catch {
    Write-Host "  X  config.ps1 读不出来：$($_.Exception.Message)" -ForegroundColor Red
    Pause-Exit 1
}

if ([string]::IsNullOrWhiteSpace($MODELS_DIR) -or [string]::IsNullOrWhiteSpace($LLAMA_DIR)) {
    Write-Host "  X  config.ps1 里 MODELS_DIR 或 LLAMA_DIR 是空的" -ForegroundColor Red
    Pause-Exit 1
}
if ([string]::IsNullOrWhiteSpace($LISTEN_HOST)) { $LISTEN_HOST = "127.0.0.1" }
if (-not $PORT) { $PORT = 1234 }
if (-not $MIN_BUILD) { $MIN_BUILD = 10828 }

# =====================================================================
#  找 llama-server —— 自动挑构建号最大的
# =====================================================================
$LLAMAEXE = $null
if ($LLAMA_EXE -and (Test-Path $LLAMA_EXE)) {
    $LLAMAEXE = $LLAMA_EXE
    Write-Host "  使用：$LLAMAEXE（config 指定）" -ForegroundColor DarkGray
} else {
    $dirs = @(Get-ChildItem -Path $LLAMA_DIR -Directory -Filter "llama-b*" -ErrorAction SilentlyContinue)
    $parsed = @()
    foreach ($d in $dirs) {
        if ($d.Name -match 'llama-b(\d+)') {
            $cand = Join-Path $d.FullName "llama-server.exe"
            if (Test-Path $cand) {
                $parsed += [pscustomobject]@{ Num = [int]$Matches[1]; Exe = $cand; Name = $d.Name }
            }
        }
    }
    if ($parsed.Count -gt 0) {
        $latest = $parsed | Sort-Object Num -Descending | Select-Object -First 1
        $LLAMAEXE = $latest.Exe
        Write-Host "  使用构建：b$($latest.Num)  ($LLAMAEXE)" -ForegroundColor DarkGray
    } else {
        $direct = Join-Path $LLAMA_DIR "llama-server.exe"
        if (Test-Path $direct) {
            $LLAMAEXE = $direct
            Write-Host "  使用：$direct" -ForegroundColor DarkGray
            Write-Host "        （没有 llama-bXXXXX 子目录，无法判断新旧）" -ForegroundColor Yellow
        }
    }
}
if (-not $LLAMAEXE) {
    Write-Host ""
    Write-Host "  X  在 $LLAMA_DIR 下找不到 llama-server.exe" -ForegroundColor Red
    Write-Host "     从 github.com/ggml-org/llama.cpp/releases 下 Windows 包，" -ForegroundColor Gray
    Write-Host "     解压成 $LLAMA_DIR\llama-bXXXXX\ 的形式" -ForegroundColor Gray
    Pause-Exit 1
}

# =====================================================================
#  扫模型
# =====================================================================
if (-not (Test-Path $MODELS_DIR)) {
    Write-Host ""
    Write-Host "  X  模型目录不存在：$MODELS_DIR" -ForegroundColor Red
    Pause-Exit 1
}

Write-Host ""
Write-Host "正在扫描模型文件..." -ForegroundColor DarkGray
$allGguf = @(Get-ChildItem -Path $MODELS_DIR -Filter *.gguf -Recurse -File -ErrorAction SilentlyContinue)
$models  = @($allGguf | Where-Object { $_.Name -notmatch 'mmproj' })

if ($models.Count -eq 0) {
    Write-Host "  X  $MODELS_DIR 里没有 .gguf 文件" -ForegroundColor Red
    Pause-Exit 1
}

for ($i = 0; $i -lt $models.Count; $i++) {
    $gb = [math]::Round($models[$i].Length / 1GB, 2)
    Write-Host ("  [{0}] {1}  ({2} GB)" -f ($i + 1), $models[$i].Name, $gb)
}
Write-Host ""
$choiceRaw = Read-Host "请输入序号后回车"
$choice = 0
if (-not [int]::TryParse($choiceRaw, [ref]$choice) -or $choice -lt 1 -or $choice -gt $models.Count) {
    Write-Host "  X  序号无效" -ForegroundColor Red
    Pause-Exit 1
}
$modelFile = $models[$choice - 1]
$MODEL = $modelFile.FullName
$MNAME = $modelFile.Name
Write-Host ""

# =====================================================================
#  匹配视觉投影文件
#
#  命名五花八门（Huihui-Ornith-9B.mmproj-Q8_0.gguf），不能靠拼字符串。
#  做法：两边归一化后比对 —— 先试完全一致，再试互相包含。
#
#  归一化的量化档列表必须长的在前：PowerShell 的 -replace 不区分大小写，
#  'F16' 排 'BF16' 前面会把 bf16 削成 'b'，视觉文件就永远匹配不上。
# =====================================================================
# =====================================================================
#  读 GGUF 元数据
#
#  模型文件头部有明文元数据，能直接读出架构名、原生上下文、有没有 chat
#  template。比按文件名猜可靠得多 —— 文件名是用户随便起的，元数据是
#  导出时写进去的。
#
#  GGUF 格式（v2/v3）：
#      magic "GGUF" | version u32 | tensor_count u64 | kv_count u64
#      然后 kv_count 组：key_len u64 | key | value_type u32 | value
#
#  只读元数据段就够，不碰 tensor 数据。但 tokenizer 词表数组可能有
#  十几万项，必须整段跳过而不是逐项解析。
# =====================================================================
function Format-CtxLabel {
    param([int]$n)
    if ($n -ge 1024) {
        $k = $n / 1024
        if ($k -eq [Math]::Floor($k)) { return "$([int]$k)K" }
        return "$([Math]::Round($k,1))K"
    }
    return "$n"
}

function Get-GgufInfo {
    param([string]$Path)

    $result = [pscustomobject]@{
        Ok             = $false
        Error          = $null
        Architecture   = $null
        Name           = $null
        ContextLength  = $null
        BlockCount     = $null
        HasChatTemplate = $false
        HasVision      = $false
    }

    $fs = $null
    $br = $null
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $br = New-Object System.IO.BinaryReader($fs)

        $magic = [System.Text.Encoding]::ASCII.GetString($br.ReadBytes(4))
        if ($magic -ne 'GGUF') {
            $result.Error = "不是 GGUF 文件（magic=$magic）"
            return $result
        }

        $version = $br.ReadUInt32()
        if ($version -lt 2 -or $version -gt 3) {
            $result.Error = "GGUF 版本 $version 暂不支持（支持 v2/v3）"
            return $result
        }
        $null = $br.ReadUInt64()          # tensor_count，用不到
        $kvCount = $br.ReadUInt64()

        # 防御：损坏文件可能报出天文数字
        if ($kvCount -gt 100000) {
            $result.Error = "元数据条数异常（$kvCount），文件可能损坏"
            return $result
        }

        $meta = @{}

        # 辅助：读字符串
        $readStr = {
            $len = $br.ReadUInt64()
            if ($len -gt 100MB) { throw "字符串长度异常：$len" }
            $bytes = $br.ReadBytes([int]$len)
            [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        # 辅助：跳过某个类型的一个值
        $skip = $null
        $skip = {
            param([uint32]$vt)
            switch ($vt) {
                0 { $null = $br.ReadByte() }              # uint8
                1 { $null = $br.ReadSByte() }             # int8
                2 { $null = $br.ReadUInt16() }            # uint16
                3 { $null = $br.ReadInt16() }             # int16
                4 { $null = $br.ReadUInt32() }            # uint32
                5 { $null = $br.ReadInt32() }             # int32
                6 { $null = $br.ReadSingle() }            # float32
                7 { $null = $br.ReadByte() }              # bool
                8 { $null = & $readStr }                  # string
                10 { $null = $br.ReadUInt64() }           # uint64
                11 { $null = $br.ReadInt64() }            # int64
                12 { $null = $br.ReadDouble() }           # float64
                9 {                                       # array
                    $et = $br.ReadUInt32()
                    $cnt = $br.ReadUInt64()
                    for ($i = 0; $i -lt $cnt; $i++) { & $skip $et }
                }
                default { throw "未知的值类型 $vt" }
            }
        }

        for ($i = 0; $i -lt $kvCount; $i++) {
            $key = & $readStr
            $vtype = $br.ReadUInt32()

            # 词表数组整段跳过 —— 这是唯一可能很大的字段
            if ($vtype -eq 9 -and $key -like 'tokenizer.ggml.*') {
                $et = $br.ReadUInt32()
                $cnt = $br.ReadUInt64()
                if ($et -eq 8) {
                    # 字符串数组：逐条读长度并跳过
                    for ($j = 0; $j -lt $cnt; $j++) {
                        $len = $br.ReadUInt64()
                        $null = $fs.Seek([long]$len, 'Current')
                    }
                } else {
                    for ($j = 0; $j -lt $cnt; $j++) { & $skip $et }
                }
                $meta[$key] = "<array of $cnt>"
                continue
            }

            switch ($vtype) {
                8 { $meta[$key] = & $readStr }
                4 { $meta[$key] = $br.ReadUInt32() }
                10 { $meta[$key] = $br.ReadUInt64() }
                5 { $meta[$key] = $br.ReadInt32() }
                7 { $meta[$key] = ($br.ReadByte() -ne 0) }
                9 {
                    $et = $br.ReadUInt32()
                    $cnt = $br.ReadUInt64()
                    for ($j = 0; $j -lt $cnt; $j++) { & $skip $et }
                    $meta[$key] = "<array of $cnt>"
                }
                default {
                    & $skip $vtype
                }
            }
        }

        $arch = $meta['general.architecture']
        $result.Ok = $true
        $result.Architecture = $arch
        $result.Name = $meta['general.name']

        if ($arch) {
            # 上下文长度因架构而异，键名带架构前缀
            $ctxKey = "$arch.context_length"
            if ($meta.ContainsKey($ctxKey)) {
                $v = $meta[$ctxKey]
                if ($v -is [uint32] -or $v -is [uint64] -or $v -is [int32]) {
                    # 有些模型导出的训练长度小得离谱（比如 512），低于 4K 就别当真
                    if ([int64]$v -ge 4096) { $result.ContextLength = [int64]$v }
                }
            }
            $bcKey = "$arch.block_count"
            if ($meta.ContainsKey($bcKey)) { $result.BlockCount = [int64]$meta[$bcKey] }

            # 视觉能力：不同架构的键名不统一，都试一遍
            foreach ($k in @("$arch.vision.block_count", 'clip.has_vision_encoder',
                             'clip.has_vision_tower', "$arch.vision.patch_size")) {
                if ($meta.ContainsKey($k)) { $result.HasVision = $true; break }
            }
        }

        # 有没有 chat template —— 这才是要不要 --jinja 的真实依据
        if ($meta.ContainsKey('tokenizer.chat_template')) {
            $tplVal = $meta['tokenizer.chat_template']
            if ($tplVal -is [string] -and -not $tplVal.StartsWith('<array')) {
                $result.HasChatTemplate = ($tplVal.Length -gt 10)
            }
        }

        return $result
    } catch {
        $result.Error = $_.Exception.Message
        return $result
    } finally {
        if ($br) { $br.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

function Get-NormName {
    param([string]$Name)
    $s = $Name
    $s = $s -replace '\.gguf', ''
    $s = $s -replace 'mmproj', ''
    $tokens = @('IQ4_XS','IQ4_NL','IQ3_XS','IQ3_M','IQ2_M','IQ1_S',
                'Q5_K_XL','Q5_K_S','Q4_K_XL','Q4_K_S','Q3_K_S','Q2_K',
                'Q3_K_M','Q3_K_L','Q4_K_M','Q4_0','Q4_1','Q5_0','Q5_1',
                'Q5_K_M','Q6_K_L','Q6_K','Q8_0',
                'BF16','FP16','FP8','F16')
    foreach ($t in $tokens) { $s = $s -replace [regex]::Escape($t), '' }
    $s = $s -replace '[-_. ()]', ''
    $s = $s -replace '\[|\]', ''
    return $s
}

$MKEY = Get-NormName $MNAME
$mmprojFiles = @($allGguf | Where-Object { $_.Name -match 'mmproj' })
$MMEXACT = $null
$MMLOOSE = $null

foreach ($cand in $mmprojFiles) {
    $ns = Get-NormName $cand.Name
    if ([string]::IsNullOrWhiteSpace($ns) -or $ns.Length -lt 5) { continue }
    if ($ns -eq $MKEY) {
        if (-not $MMEXACT) { $MMEXACT = $cand.FullName }
        continue
    }
    if ($MMEXACT) { continue }
    if (-not $MMLOOSE) {
        if ($MKEY -like "*$ns*" -or $ns -like "*$MKEY*") { $MMLOOSE = $cand.FullName }
    }
}

$MMPROJ = $null
$MMHOW = $null
if ($MMEXACT) { $MMPROJ = $MMEXACT; $MMHOW = "基名完全一致" }
elseif ($MMLOOSE) { $MMPROJ = $MMLOOSE; $MMHOW = "基名互相包含，建议确认一下" }

# =====================================================================
#  参数决策
#
#  优先用模型文件自己声明的元数据（架构名、原生上下文、有无 chat template），
#  拿不到时才退回按文件名猜。文件名是用户随便起的，元数据是导出时写进去的，
#  后者可靠得多。
#
#  这些阈值是从实际跑崩/跑呆的案例里调出来的，改之前先看 docs/known-issues.md
# =====================================================================
$CTX = 8192
$TEMPC = 0.9
$TOPP = 0.95
$REPPEN = 1.05
$EXTRA = @()
$SPARK = $false
$RFLAGS = @()
$DECIDE = "文件名"
$NATIVE_CTX = $null      # 模型自己声明的最大上下文，用来约束菜单

$low = $MNAME.ToLower()
$g = Get-GgufInfo $MODEL

if ($g.Ok -and $g.Architecture) {
    $arch = $g.Architecture.ToLower()
    $DECIDE = "元数据（$arch）"

    # --- 原生上下文：模型自己声明的最大长度 ---
    if ($g.ContextLength) {
        $CTX = [int]$g.ContextLength
        $NATIVE_CTX = [int]$g.ContextLength
    }

    # --- 有 chat template 才需要 --jinja ---
    # 缺 --jinja 时工具调用会退化成「反复调同一个工具」的循环
    if ($g.HasChatTemplate) { $EXTRA = @('--jinja') }

    # --- 混合架构（attention + SSM）容易退化复读，惩罚提高一档 ---
    if ($arch -match 'next|mamba|jamba|hybrid|falcon-h1') { $REPPEN = 1.1 }

    # --- 视觉模型但没配到 vision projector，明确提示 ---
    if ($g.HasVision -and -not $MMPROJ) {
        Write-Host "  [注意] 这个模型声明了视觉能力，但没找到对应的 mmproj 文件" -ForegroundColor Yellow
        Write-Host "         图片将无法输入。确认一下模型目录里有没有配套的 mmproj-*.gguf" -ForegroundColor Gray
        Write-Host ""
    }
    # --- 声明了视觉能力但文件不在，或者反过来 ---
    if (-not $g.HasVision -and $MMPROJ) {
        Write-Host "  [注意] 配到了 mmproj 但模型本身没声明视觉能力，可能配错了" -ForegroundColor Yellow
    }

    # 特定架构仍需要个别参数（元数据里没有这些信息）
    if ($arch -match 'minicpm') {
        $TEMPC = 1.0
        $EXTRA = @('--min-p','0.0') + $EXTRA     # 防复读
    }
} else {
    # --- 读不到元数据：退回文件名规则 ---
    if ($g.Error) {
        Write-Host "  [提示] 读不到模型元数据（$($g.Error)），改按文件名判断" -ForegroundColor Yellow
    }

    if ($low -match 'minicpm5') {
        $CTX = 131072
        $TEMPC = 1.0
        $EXTRA = @('--min-p','0.0','--jinja')
    }
    if ($low -match 'e4b')      { $CTX = 16384 }
    if ($low -match 'qwen3\.5') { $CTX = 16384 }
    if ($low -match 'ornith') {
        $CTX = 16384
        $EXTRA = @('--jinja')
        $REPPEN = 1.1
    }
}

# --- Spark 无论元数据读没读到都要做版本自检（它需要特定构建）---
if ($low -match 'spark' -or $low -match 'x2\.5' -or ($g.Ok -and $g.Architecture -match 'spark')) {
    $SPARK = $true
    $EXTRA = @('--jinja')
    if (-not $g.Ok) { $CTX = 131072 }
    if ($low -match 'q8_0') { $CTX = 65536 }   # Q8 权重显存吃紧，降一档
}

# =====================================================================
#  选上下文长度
# =====================================================================
if ($CTX_OVERRIDE) {
    $CTX = [int]$CTX_OVERRIDE
    Write-Host "  [配置预设] 上下文 $CTX tokens（跳过选择）" -ForegroundColor DarkGray
} else {
    # 默认值和上限都跟着模型的原生上下文走 ——
    # 模型只支持 8K 却硬塞 64K，要么起不来，要么输出退化
    if ($NATIVE_CTX) {
        $cap = [Math]::Min([int]$NATIVE_CTX, 131072)      # 实用上限 128K
        $defCtx = $cap
        $nativeNote = "模型原生支持 $NATIVE_CTX"
    } else {
        $cap = 131072
        $defCtx = 65536
        $nativeNote = "未读到原生上下文，按通用值处理"
    }

    Write-Host ""
    Write-Host "  == 这次用多长的上下文？ ==========================" -ForegroundColor Cyan
    Write-Host "     $nativeNote" -ForegroundColor DarkGray
    Write-Host "    [1] 16K    最省显存、最快"
    Write-Host "    [2] 32K    日常聊天 / 角色扮演"
    Write-Host "    [3] 64K    长剧情 / 长文档"
    Write-Host "    [4] 128K   最长，速度明显下降"
    Write-Host "    [5] 自定义"
    if ($defCtx -lt 65536) {
        Write-Host "    直接回车 = $(Format-CtxLabel $defCtx)（模型上限，别再往上加了）" -ForegroundColor Yellow
    } else {
        Write-Host "    直接回车 = $(Format-CtxLabel $defCtx)"
    }
    Write-Host "  ==================================================" -ForegroundColor Cyan
    $sel = Read-Host "   输入 1-5 回车"
    switch ($sel) {
        "1" { $CTX = 16384 }
        "2" { $CTX = 32768 }
        "3" { $CTX = 65536 }
        "4" { $CTX = 131072 }
        "5" {
            $cust = Read-Host "   自定义 token 数（例 49152）"
            $n = 0
            if ([int]::TryParse($cust, [ref]$n) -and $n -gt 0) { $CTX = $n }
            else { Write-Host "   输入无效，用默认值" -ForegroundColor Yellow; $CTX = $defCtx }
        }
        default { $CTX = $defCtx }
    }

    # 超过模型原生上限时明确警告，但不强行改回去（有些模型能外推）
    if ($NATIVE_CTX -and $CTX -gt $NATIVE_CTX) {
        Write-Host "  [警告] 你选的 $CTX 超过模型原生上限 $NATIVE_CTX" -ForegroundColor Yellow
        Write-Host "         超出部分没有训练数据支撑，输出质量会明显下降" -ForegroundColor Gray
        Write-Host "         真要用就确认一下模型是否支持外推（YaRN 之类）" -ForegroundColor Gray
    }
}

if ($CTX -eq 131072 -and $MMPROJ) {
    Write-Host "  [提醒] 128K 带视觉显存可能不够，OOM 就退回 64K" -ForegroundColor Yellow
}

# KV 量化
if ($KV_CACHE_TYPE) {
    $KVTYPE = $KV_CACHE_TYPE
} elseif ($CTX -ge 65536) {
    $KVTYPE = "q4_0"
} else {
    $KVTYPE = "q8_0"
}
Write-Host "  上下文 $CTX tokens    KV 量化 $KVTYPE" -ForegroundColor Gray
Write-Host ""

if ($REASONING_OVERRIDE) {
    $RFLAGS = @('--reasoning', $REASONING_OVERRIDE, '--reasoning-budget', '0')
}

# =====================================================================
#  Spark 版本自检
#
#  spark2_5 是较新架构，老版本 llama.cpp 不认，会报 unknown architecture。
#  --version 输出格式：version 0.4.1-dev (build 10964, commit b29c606e2)
#  要取 build 后面那个数，不能取语义版本号（0.4.1-dev 会被掐成 041）。
# =====================================================================
if ($SPARK) {
    Write-Host "[版本自检] Spark-X2.5 需要 b$MIN_BUILD 或更新" -ForegroundColor Cyan
    $verOut = $null
    try {
        $verOut = & $LLAMAEXE --version 2>&1 | Out-String
        Write-Host "  ---- 原始输出 ----" -ForegroundColor DarkGray
        Write-Host $verOut.Trim() -ForegroundColor DarkGray
        Write-Host "  ------------------" -ForegroundColor DarkGray
    } catch {
        Write-Host "  读不到版本：$($_.Exception.Message)" -ForegroundColor Yellow
    }
    $buildNum = $null
    if ($verOut -and ($verOut -match 'build\s+(\d+)')) { $buildNum = [int]$Matches[1] }
    if (-not $buildNum) {
        Write-Host "  [警告] 认不出构建号，如果启动报 unknown architecture 就是版本不够" -ForegroundColor Yellow
    } elseif ($buildNum -ge $MIN_BUILD) {
        Write-Host "  [OK] 检测到 b$buildNum" -ForegroundColor Green
    } else {
        Write-Host "  [警告] 当前 b$buildNum，低于 b$MIN_BUILD" -ForegroundColor Yellow
        Write-Host "         低版本不认 spark2_5，会报 unknown architecture" -ForegroundColor Gray
        Write-Host "         下载：https://github.com/ggml-org/llama.cpp/releases" -ForegroundColor Gray
    }
    Write-Host ""
}

# =====================================================================
#  端口检查
#  上次没退干净的 llama-server 会占着端口，报 "couldn't bind HTTP server socket"
# =====================================================================
$tries = 0
while ($true) {
    $busy = $null
    try {
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $busy = Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue
        } else {
            $line = netstat -ano 2>$null | Select-String -Pattern ":$PORT\s" | Select-String -Pattern "LISTENING" | Select-Object -First 1
            if ($line) { $busy = [pscustomobject]@{ OwningProcess = ($line -split '\s+')[-1] } }
        }
    } catch {}
    if (-not $busy) { break }
    $proc = try { Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue } catch { $null }
    $pname = if ($proc) { $proc.ProcessName } else { "?" }
    Write-Host ""
    Write-Host "[注意] 端口 $PORT 被占用：PID $($busy.OwningProcess)  进程 $pname" -ForegroundColor Yellow
    if ($pname -like "*llama*") {
        Write-Host "       看着像上次没退干净的 llama-server" -ForegroundColor Gray
        $ans = Read-Host "       关掉它再启动？[Y/N]"
        if ($ans -match '^[Yy]') {
            try { Stop-Process -Id $busy.OwningProcess -Force -ErrorAction Stop; Write-Host "       已结束" -ForegroundColor Green }
            catch { Write-Host "       结束失败：$($_.Exception.Message)" -ForegroundColor Red }
            Start-Sleep -Milliseconds 800
            continue
        }
    }
    $PORT++
    $tries++
    if ($tries -gt 6) {
        Write-Host "  X  端口 1234-1240 都被占用，先关掉占用的程序" -ForegroundColor Red
        Pause-Exit 1
    }
    Write-Host "       改用端口 $PORT —— 客户端记得一起改" -ForegroundColor Yellow
}

# =====================================================================
#  参数一览
# =====================================================================
Write-Host ""
Write-Dash
Write-Host "Model  : $MNAME"
Write-Host "依据   : $DECIDE" -ForegroundColor DarkGray
if ($MMPROJ) {
    Write-Host "Vision : $(Split-Path $MMPROJ -Leaf)"
    Write-Host "         （依据：$MMHOW）" -ForegroundColor DarkGray
} else {
    Write-Host "Vision : 无（纯文本）"
}
if ($NATIVE_CTX) {
    Write-Host "Ctx    : $CTX  (KV $KVTYPE，模型上限 $NATIVE_CTX)"
} else {
    Write-Host "Ctx    : $CTX  (KV $KVTYPE)"
}
Write-Host "采样   : temp $TEMPC , top-p $TOPP $($EXTRA -join ' ')"
if ($RFLAGS.Count -gt 0) { Write-Host "推理   : $($RFLAGS -join ' ')" }
Write-Host "端口   : $PORT   （客户端地址 http://$LISTEN_HOST`:$PORT/v1）"
if ($SPARK) { Write-Host "说明   : Spark-X2.5 混合注意力" }
Write-Dash
Write-Host ""
Write-Host "[提示] 显存不够就压小 CTX，或把 config.ps1 里 KV_CACHE_TYPE 设成 q4_0" -ForegroundColor DarkGray
Write-Host ""

# =====================================================================
#  拼参数并启动
# =====================================================================
$argList = @(
    '--model', $MODEL,
    '--port', "$PORT",
    '--host', $LISTEN_HOST,
    '--ctx-size', "$CTX",
    '--parallel', '1',
    '--cache-type-k', $KVTYPE,
    '--cache-type-v', $KVTYPE,
    '--n-gpu-layers', '999',
    '--temp', "$TEMPC",
    '--top-p', "$TOPP",
    '--repeat-penalty', "$REPPEN",
    '--repeat-last-n', '256'
)
if ($MMPROJ) { $argList += @('--mmproj', $MMPROJ) }
if ($EXTRA.Count -gt 0) { $argList += $EXTRA }
if ($RFLAGS.Count -gt 0) { $argList += $RFLAGS }
if ($API_KEY) { $argList += @('--api-key', $API_KEY) }

if (-not $MMPROJ -and $mmprojFiles.Count -gt 0) {
    Write-Host "[信息] 没匹配到视觉文件，按纯文本启动" -ForegroundColor Yellow
    Write-Host "       候选：$(($mmprojFiles | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor DarkGray
    Write-Host ""
}

Write-Host "启动命令：" -ForegroundColor DarkGray
Write-Host "  $LLAMAEXE $($argList -join ' ')" -ForegroundColor DarkGray
Write-Host ""
Write-Host "服务启动后，客户端地址：http://$LISTEN_HOST`:$PORT/v1" -ForegroundColor Green
Write-Host "按 Ctrl+C 停止服务" -ForegroundColor DarkGray
Write-Host ""

try {
    & $LLAMAEXE @argList
    $code = $LASTEXITCODE
} catch {
    Write-Host ""
    Write-Host "  X  启动失败：$($_.Exception.Message)" -ForegroundColor Red
    Pause-Exit 1
}

Write-Host ""
Write-Host "服务已退出（退出码 $code）" -ForegroundColor Gray
Pause-Exit 0
