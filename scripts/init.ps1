#requires -Version 5.1
# =====================================================================
#  init.ps1 - 生成 config.ps1 并打开编辑
#
#  为什么需要这一步：Windows 默认隐藏已知扩展名，让用户手动把
#  config.ps1.example 改名成 config.ps1，很容易得到 config.ps1.txt，
#  脚本反而认不出来。所以由脚本代劳。
# =====================================================================

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

function Pause-Any {
    Write-Host ""
    try {
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
            Write-Host "按任意键继续..."
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }
    } catch { }
}

Write-Host ""
Write-Host ("=" * 60)
Write-Host "  初始化配置" -ForegroundColor White
Write-Host ("=" * 60)
Write-Host ""

$src = Join-Path $PSScriptRoot "config.ps1.example"
$dst = Join-Path $PSScriptRoot "config.ps1"

if (-not (Test-Path $src)) {
    Write-Host "  X  找不到 config.ps1.example" -ForegroundColor Red
    Write-Host "     压缩包可能没解压完整，重新解压一次。" -ForegroundColor Gray
    Pause-Any
    exit 1
}

if (Test-Path $dst) {
    Write-Host "  已经存在 config.ps1" -ForegroundColor Yellow
    Write-Host "  路径：$dst" -ForegroundColor Gray
    Write-Host ""
    $ans = Read-Host "  要重新生成一份覆盖它吗 [Y/N]"
    if ($ans -match '^[Yy]') {
        Copy-Item $src $dst -Force
        Write-Host "  已重新生成。" -ForegroundColor Green
    } else {
        Write-Host "  保留现有配置，直接打开编辑。" -ForegroundColor Gray
    }
} else {
    Copy-Item $src $dst
    Write-Host "  已生成 config.ps1" -ForegroundColor Green
}

if (-not (Test-Path $dst)) {
    Write-Host ""
    Write-Host "  X  生成失败，config.ps1 不存在" -ForegroundColor Red
    Pause-Any
    exit 1
}

Write-Host ""
Write-Host "  先看看你的机器上 llama.cpp 装在哪 —— 正在搜索..." -ForegroundColor Cyan

# 顺手探测一下，省得用户自己找路径
$guessExe = $null
foreach ($d in @('D:\', 'C:\', 'E:\', 'F:\')) {
    if (-not (Test-Path $d)) { continue }
    try {
        $level1 = Get-ChildItem -Path $d -Directory -ErrorAction SilentlyContinue | Select-Object -First 200
        foreach ($d1 in $level1) {
            $hit = Get-ChildItem -Path $d1.FullName -Filter 'llama-server.exe' -Recurse -Depth 2 -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $guessExe = $hit; break }
        }
    } catch { }
    if ($guessExe) { break }
}

if ($guessExe) {
    $llamaRoot = $guessExe.DirectoryName
    Write-Host ""
    Write-Host "  ✔ 找到 llama.cpp：$llamaRoot" -ForegroundColor Green

    # 模型目录：优先 llama.cpp 同级的 models
    $modelsCand = $null
    foreach ($c in @((Join-Path $llamaRoot 'models'), (Join-Path (Split-Path $llamaRoot -Parent) 'models'))) {
        if (Test-Path $c) {
            $g = Get-ChildItem -Path $c -Filter '*.gguf' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($g) { $modelsCand = $c; break }
        }
    }

    if ($modelsCand) {
        Write-Host "  ✔ 找到模型目录：$modelsCand" -ForegroundColor Green
    }

    Write-Host ""
    $ans2 = Read-Host "  要自动帮你填进 config.ps1 吗？[Y/N]"
    if ($ans2 -match '^[Yy]') {
        $content = Get-Content $dst -Raw -Encoding UTF8
        $content = $content -replace '\$LLAMA_DIR\s*=\s*"[^"]*"', "`$LLAMA_DIR = `"$llamaRoot`""
        if ($modelsCand) {
            $content = $content -replace '\$MODELS_DIR\s*=\s*"[^"]*"', "`$MODELS_DIR = `"$modelsCand`""
        }
        [System.IO.File]::WriteAllText($dst, $content, [System.Text.UTF8Encoding]::new($true))
        Write-Host "  已写入 config.ps1" -ForegroundColor Green
    } else {
        Write-Host "  保留模板默认值，你可以手动改。" -ForegroundColor Gray
    }
} else {
    Write-Host ""
    Write-Host "  没搜到 llama-server.exe —— 你可能还没下载 llama.cpp。" -ForegroundColor Yellow
    Write-Host "  下载地址：https://github.com/ggml-org/llama.cpp/releases" -ForegroundColor Gray
    Write-Host "  需要两个包：llama-bXXXX-bin-win-cuda-XX.X-x64.zip 和 cudart-llama-bin-win-cuda-XX.X-x64.zip" -ForegroundColor Gray
}

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  接下来会打开记事本，确认这两个路径对不对：" -ForegroundColor Cyan
Write-Host ""
Write-Host '      $MODELS_DIR = "..."    <- 你的 .gguf 放在哪' -ForegroundColor White
Write-Host '      $LLAMA_DIR  = "..."    <- llama.cpp 解压在哪' -ForegroundColor White
Write-Host ""
Write-Host "  反斜杠写两个，或者用正斜杠也行" -ForegroundColor Yellow
Write-Host "  改完 Ctrl+S 保存，关掉记事本，然后双击 1-体检" -ForegroundColor Gray
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""
Write-Host "按任意键打开记事本..."
try {
    if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    }
} catch { }

try {
    Start-Process notepad.exe -ArgumentList "`"$dst`""
    Write-Host "  记事本已打开。" -ForegroundColor Green
} catch {
    Write-Host "  打开记事本失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  手动打开：$dst" -ForegroundColor Gray
    Pause-Any
}

exit 0
