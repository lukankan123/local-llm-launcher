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
#  按架构给默认参数
#  这些值是从实际跑崩/跑呆的案例里调出来的，改之前先看 docs/known-issues.md
# =====================================================================
$CTX = 8192
$TEMPC = 0.9
$TOPP = 0.95
$REPPEN = 1.05
$EXTRA = @()
$SPARK = $false
$RFLAGS = @()

$low = $MNAME.ToLower()

if ($low -match 'minicpm5') {
    $CTX = 131072
    $TEMPC = 1.0
    $EXTRA = @('--min-p','0.0','--jinja')
}
if ($low -match 'spark' -or $low -match 'x2\.5') { $SPARK = $true }
if ($low -match 'e4b')     { $CTX = 16384 }
if ($low -match 'qwen3\.5'){ $CTX = 16384 }
if ($low -match 'ornith') {
    $CTX = 16384
    # 混合架构（attention + SSM）的工具调用必须走 chat template，
    # 缺 --jinja 会和客户端死锁成「反复调同一个工具」的循环
    $EXTRA = @('--jinja')
    # 这类架构容易退化复读，惩罚提高一档
    $REPPEN = 1.1
}
if ($SPARK) {
    $CTX = 131072
    $EXTRA = @('--jinja')
    if ($low -match 'q8_0') { $CTX = 65536 }   # Q8 权重显存吃紧，降一档
}

# =====================================================================
#  选上下文长度
# =====================================================================
if ($CTX_OVERRIDE) {
    $CTX = [int]$CTX_OVERRIDE
    Write-Host "  [配置预设] 上下文 $CTX tokens（跳过选择）" -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "  == 这次用多长的上下文？ ==========================" -ForegroundColor Cyan
    Write-Host "    [1] 16K    最省显存、最快"
    Write-Host "    [2] 32K    日常聊天 / 角色扮演"
    Write-Host "    [3] 64K    长剧情 / 长文档"
    Write-Host "    [4] 128K   最长，速度明显下降"
    Write-Host "    [5] 自定义"
    Write-Host "    直接回车 = 64K（模型建议值 $CTX）"
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
            else { Write-Host "   输入无效，用默认 64K" -ForegroundColor Yellow; $CTX = 65536 }
        }
        default { $CTX = 65536 }
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
if ($MMPROJ) {
    Write-Host "Vision : $(Split-Path $MMPROJ -Leaf)"
    Write-Host "         （依据：$MMHOW）" -ForegroundColor DarkGray
} else {
    Write-Host "Vision : 无（纯文本）"
}
Write-Host "Ctx    : $CTX  (KV $KVTYPE)"
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
