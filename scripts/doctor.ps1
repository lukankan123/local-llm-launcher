#requires -Version 5.1
# =====================================================================
#  doctor.ps1 - 环境体检（只读，不改动任何东西）
#
#  由 doctor.bat 启动。中文全部在这里输出，bat 壳保持纯 ASCII。
# =====================================================================

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:OK = 0
$script:WARN = 0
$script:FAIL = 0

function Write-Ok   { param($m) Write-Host "  OK  $m" -ForegroundColor Green;  $script:OK++ }
function Write-Warn { param($m) Write-Host "  !   $m" -ForegroundColor Yellow; $script:WARN++ }
function Write-Fail { param($m) Write-Host "  X   $m" -ForegroundColor Red;    $script:FAIL++ }
function Write-Info { param($m) Write-Host "      $m" -ForegroundColor Gray }
function Write-Head { param($m) Write-Host ""; Write-Host $m -ForegroundColor Cyan }
function Write-Sep  { Write-Host ("=" * 60) -ForegroundColor DarkGray }

Write-Host ""
Write-Sep
Write-Host "  llama.cpp 启动器 - 环境体检" -ForegroundColor White
Write-Sep

# -------------------- 1. 配置 --------------------
Write-Head "[1/7] 配置文件"
$cfg = Join-Path $PSScriptRoot "config.ps1"
$MODELS_DIR = $null
$LLAMA_DIR  = $null

if (-not (Test-Path $cfg)) {
    Write-Fail "找不到 config.ps1"
    Write-Info "把 config.ps1.example 复制成 config.ps1，再按自己的路径改"
} else {
    try {
        . $cfg
        Write-Ok "已加载 config.ps1"
    } catch {
        Write-Fail "config.ps1 读不出来：$($_.Exception.Message)"
    }
    # 留空是合法的 —— 表示"自动扫描"，下面第 2、3 项会真的扫一遍
    if ([string]::IsNullOrWhiteSpace($MODELS_DIR)) {
        Write-Ok "MODELS_DIR 留空 → 自动扫描所有磁盘"
    } elseif (Test-Path $MODELS_DIR) {
        Write-Ok "模型目录存在：$MODELS_DIR"
    } else {
        Write-Warn "模型目录不存在：$MODELS_DIR（会退回自动扫描）"
    }
    if ([string]::IsNullOrWhiteSpace($LLAMA_DIR)) {
        Write-Ok "LLAMA_DIR 留空 → 自动搜索 llama-server.exe"
    } elseif (Test-Path $LLAMA_DIR) {
        Write-Ok "llama.cpp 目录存在：$LLAMA_DIR"
    } else {
        Write-Warn "llama.cpp 目录不存在：$LLAMA_DIR（会退回自动搜索）"
    }
}

# -------------------- 扫描辅助 --------------------
# 与 start.ps1 里同一套逻辑：config 留空或路径无效时，扫所有盘找文件。
$SCRIPT:SkipDirs = @('Windows', 'Program Files', 'Program Files (x86)',
                     'ProgramData', 'Recovery', '$Recycle.Bin',
                     'System Volume Information', 'PerfLogs',
                     'node_modules', '.git', '.cache', '__pycache__',
                     'proc', 'sys', 'dev', 'usr', 'var', 'lib', 'lib64',
                     'boot', 'run', 'snap', 'etc', 'bin', 'sbin', 'opt')

function Get-ScanRoots {
    $roots = @()
    try {
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if ($null -eq $d.Free) { continue }
            if ($d.Root) { $roots += $d.Root }
        }
    } catch { }
    return $roots
}

function Find-LlamaServerAuto {
    param([int]$MaxDepth = 3)
    foreach ($root in (Get-ScanRoots)) {
        try {
            $level1 = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $SCRIPT:SkipDirs -notcontains $_.Name } |
                      Select-Object -First 300
            foreach ($d1 in $level1) {
                $direct = Join-Path $d1.FullName 'llama-server.exe'
                if (Test-Path $direct) { return $d1.FullName }
                $hit = Get-ChildItem -Path $d1.FullName -Filter 'llama-server.exe' -Recurse -Depth $MaxDepth -File -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($hit) { return $hit.DirectoryName }
            }
        } catch { }
    }
    return $null
}

function Find-AllGgufDirs {
    param([int]$MaxDepth = 3)
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($root in (Get-ScanRoots)) {
        try {
            $level1 = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $SCRIPT:SkipDirs -notcontains $_.Name } |
                      Select-Object -First 300
            foreach ($d1 in $level1) {
                $g = Get-ChildItem -Path $d1.FullName -Filter '*.gguf' -Recurse -Depth $MaxDepth -File -ErrorAction SilentlyContinue |
                     Select-Object -First 1
                if ($g -and -not $hits.Contains($g.DirectoryName)) { $hits.Add($g.DirectoryName) }
            }
        } catch { }
    }
    return $hits
}

# -------------------- 2. 模型文件 --------------------
Write-Head "[2/7] 模型文件"
$MODELS_DIR_EFFECTIVE = $MODELS_DIR
if (-not $MODELS_DIR -or -not (Test-Path $MODELS_DIR)) {
    Write-Info "config 里没指定模型目录（或路径无效），自动扫描"
    $foundDirs = @(Find-AllGgufDirs)
    if ($foundDirs.Count -gt 0) {
        $MODELS_DIR_EFFECTIVE = $foundDirs[0]
        Write-Ok "扫到 $($foundDirs.Count) 个含模型的目录"
        foreach ($d in $foundDirs) { Write-Info "  $d" }
        if ($foundDirs.Count -gt 1) {
            Write-Info "启动时会把所有这些目录的模型都列出来"
        }
    } else {
        Write-Fail "扫遍所有盘也没找到 .gguf"
        Write-Info "确认模型已经下载到本地，或直接在 config.ps1 里写明路径"
    }
}
if ($MODELS_DIR_EFFECTIVE -and (Test-Path $MODELS_DIR_EFFECTIVE)) {
    $MODELS_DIR = $MODELS_DIR_EFFECTIVE
    $all = @(Get-ChildItem -Path $MODELS_DIR -Filter *.gguf -Recurse -File -ErrorAction SilentlyContinue)
    $mmproj = @($all | Where-Object { $_.Name -match 'mmproj' })
    $models = @($all | Where-Object { $_.Name -notmatch 'mmproj' })
    Write-Info "模型文件 $($models.Count) 个，视觉投影文件 $($mmproj.Count) 个"
    if ($models.Count -eq 0) {
        Write-Fail "一个 .gguf 都没有，先从 HuggingFace 下几个放进来"
    } else {
        Write-Ok "找到模型"
        $models | Select-Object -First 5 | ForEach-Object {
            $gb = [math]::Round($_.Length / 1GB, 2)
            Write-Info "$($_.Name)  ($gb GB)"
        }
        if ($models.Count -gt 5) { Write-Info "...还有 $($models.Count - 5) 个" }
    }
} else {
    Write-Info "跳过（配置未就绪）"
}

# -------------------- 3. llama.cpp 构建 --------------------
Write-Head "[3/7] llama.cpp 构建"
if (-not $LLAMA_DIR -or -not (Test-Path $LLAMA_DIR)) {
    Write-Info "config 里没指定 llama.cpp 目录（或路径无效），自动扫描"
    $autoDir = Find-LlamaServerAuto
    if ($autoDir) {
        $LLAMA_DIR = $autoDir
        Write-Ok "找到 llama.cpp：$autoDir"
    } else {
        Write-Fail "没找到 llama-server.exe"
        Write-Info "从 github.com/ggml-org/llama.cpp/releases 下载 Windows 包"
        Write-Info "需要两个：llama-bXXXX-bin-win-cuda-XX.X-x64.zip 和 cudart-llama-...zip"
    }
}
if ($LLAMA_DIR -and (Test-Path $LLAMA_DIR)) {
    $dirs = @(Get-ChildItem -Path $LLAMA_DIR -Directory -Filter "llama-b*" -ErrorAction SilentlyContinue)
    $parsed = @()
    foreach ($d in $dirs) {
        if ($d.Name -match 'llama-b(\d+)') {
            $parsed += [pscustomobject]@{ Num = [int]$Matches[1]; Path = $d.FullName; Name = $d.Name }
        }
    }
    if ($parsed.Count -eq 0) {
        $direct = Join-Path $LLAMA_DIR "llama-server.exe"
        if (Test-Path $direct) {
            $ownName = Split-Path $LLAMA_DIR -Leaf
            if ($ownName -match 'llama-b(\d+)') {
                Write-Ok "llama.cpp 就在 $LLAMA_DIR（构建 b$($Matches[1])）"
                Write-Info "exe 直接摆在这一层，这是发行包原样解压的结构，正常"
            } else {
                Write-Ok "llama-server.exe 存在：$direct"
                Write-Info "目录名不带构建号，无法判断新旧"
            }
            $exeSize = [math]::Round((Get-Item $direct).Length / 1MB, 1)
            Write-Info "文件大小：$exeSize MB"
        } else {
            Write-Fail "没找到 llama-bXXXXX 目录，也没有 llama-server.exe"
            Write-Info "从 github.com/ggml-org/llama.cpp/releases 下 Windows 包"
            Write-Info "解压成 $LLAMA_DIR\llama-bXXXXX\ 的形式"
        }
    } else {
        $latest = $parsed | Sort-Object Num -Descending | Select-Object -First 1
        Write-Ok "找到 $($parsed.Count) 个构建，最新 b$($latest.Num)"
        Write-Info $latest.Path
        $exe = Join-Path $latest.Path "llama-server.exe"
        if (Test-Path $exe) {
            $sz = (Get-Item $exe).Length
            Write-Ok "llama-server.exe 存在（$([math]::Round($sz/1MB,1)) MB）"
        } else {
            Write-Fail "那个目录里没有 llama-server.exe"
        }
        if ($parsed.Count -gt 1) {
            $others = ($parsed | Sort-Object Num -Descending | Select-Object -Skip 1 | ForEach-Object { "b$($_.Num)" }) -join ", "
            Write-Info "其他可用（可回退）：$others"
        }
    }
} else {
    Write-Info "跳过（配置未就绪）"
}

# -------------------- 4. 显卡 --------------------
Write-Head "[4/7] 显卡与显存"
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $smi) {
    Write-Warn "没找到 nvidia-smi（非 Windows 或驱动未装都会这样）"
    Write-Info "不是 NVIDIA 显卡，或驱动没装好。没有 GPU 也能跑，但很慢"
    Write-Info "用 CPU 推理时把 --n-gpu-layers 设成 0"
} else {
    try {
        $raw = & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv,noheader,nounits 2>$null
        if ($raw) {
            foreach ($line in @($raw)) {
                $p = ($line -split ',') | ForEach-Object { $_.Trim() }
                if ($p.Count -ge 4) {
                    Write-Ok "显卡：$($p[0])"
                    Write-Info "显存：总 $($p[1]) MiB / 已用 $($p[2]) MiB / 空闲 $($p[3]) MiB"
                    $ratio = if ([double]$p[1] -gt 0) { [math]::Round([double]$p[3] / [double]$p[1] * 100, 1) } else { 0 }
                    Write-Info "空闲占比：$ratio%"
                    if ($ratio -lt 15) {
                        Write-Warn "空闲显存偏少，可能是别的程序占着（浏览器硬件加速、壁纸软件等）"
                    }
                }
            }
        } else {
            Write-Warn "nvidia-smi 没有返回数据"
        }
    } catch {
        Write-Warn "读取显卡信息失败：$($_.Exception.Message)"
    }
}

# -------------------- 5. 端口 --------------------
Write-Head "[5/7] 端口占用"
$port = if ($PORT) { $PORT } else { 1234 }
$busy = $null
try {
    if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
        $busy = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    } else {
        # 极少数精简系统没有这个 cmdlet，退回 netstat 解析
        $line = netstat -ano 2>$null | Select-String -Pattern ":$port\s" | Select-String -Pattern "LISTENING" | Select-Object -First 1
        if ($line) { $busy = [pscustomobject]@{ OwningProcess = ($line -split '\s+')[-1] } }
    }
} catch {
    $busy = $null
}
if (-not $busy) {
    Write-Ok "端口 $port 空闲"
} else {
    $proc = try { Get-Process -Id $busy.OwningProcess -ErrorAction SilentlyContinue } catch { $null }
    $pname = if ($proc) { $proc.ProcessName } else { "?" }
    Write-Fail "端口 $port 被占用：PID $($busy.OwningProcess) 进程 $pname"
    if ($pname -like "*llama*") {
        Write-Info "这多半是上次没退干净的 llama-server"
        Write-Info "关掉它：taskkill /PID $($busy.OwningProcess) /F"
    } else {
        Write-Info "是别的程序占着，换个端口或关掉它"
    }
}

# -------------------- 6. 编码 --------------------
Write-Head "[6/7] 控制台编码"
$cp = "?"
try {
    # $IsWindows 是 PowerShell 6+ 才有的变量，5.1 里是 $null。
    # 用 $env:OS 判断最稳，两个版本都有这个环境变量。
    if ($env:OS -eq 'Windows_NT') {
        $cpOut = (chcp) 2>$null
        if ($cpOut -match '(\d+)') { $cp = $Matches[1] }
    } else {
        $cp = "非 Windows，跳过"
    }
} catch { $cp = "读不到" }
Write-Info "当前代码页：$cp"
if ($cp -eq "65001") {
    Write-Ok "UTF-8，中文显示正常"
} elseif ($cp -match '^\d+$') {
    Write-Warn "不是 65001，中文可能乱码"
    Write-Info "bat 壳已经切过 65001，如果你是在别处跑出现方框，先执行 chcp 65001"
} else {
    Write-Info "（非 Windows 环境，代码页检查不适用）"
}
$psv = $PSVersionTable.PSVersion
Write-Info "PowerShell 版本：$psv"

# -------------------- 7. 磁盘 --------------------
Write-Head "[7/7] 磁盘空间"
$target = if ($MODELS_DIR -and (Test-Path $MODELS_DIR)) { $MODELS_DIR } else { $PSScriptRoot }
try {
    $drive = (Get-Item $target).PSDrive
    $free = [math]::Round($drive.Free / 1GB, 1)
    $total = [math]::Round(($drive.Free + $drive.Used) / 1GB, 1)
    Write-Ok "所在盘 $($drive.Name): 空闲 $free GB / 总 $total GB"
    if ($free -lt 10) {
        Write-Warn "空闲不足 10 GB，GGUF 模型普遍 5-20 GB，建议先清点空间"
    }
} catch {
    Write-Info "读不到磁盘信息：$($_.Exception.Message)"
}

# -------------------- 汇总 --------------------
Write-Host ""
Write-Sep
Write-Host "  体检结果：通过 $script:OK 项 / 警告 $script:WARN 项 / 失败 $script:FAIL 项" -ForegroundColor White
Write-Sep
if ($script:FAIL -gt 0) {
    Write-Host ""
    Write-Host "  有 $script:FAIL 项失败，先按上面提示修好再启动。" -ForegroundColor Yellow
    Write-Host "  最常见三条：config.ps1 没建、模型目录填错、上次没退干净占着端口。"
} elseif ($script:WARN -gt 0) {
    Write-Host ""
    Write-Host "  没有硬失败，警告项多半能跑。" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host "  全部通过，可以跑了：start.bat" -ForegroundColor Green
}
Write-Host ""

try {
    if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
        Write-Host "按任意键继续..."
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
} catch {
    # 无控制台环境（重定向/管道/自动化）直接跳过，不要因为等按键而崩
}
