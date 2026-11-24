# =====================================================================
#  llama.cpp 自动下载
#
#  找不到 llama.cpp 时，问用户要不要下载。不静默下 —— 几百 MB 的
#  下载是有后果的动作，得让人知道。
#
#  难点在选哪个包：llama.cpp 每个 release 有多种后端，选错跑不起来。
#  判断依据是显卡和驱动支持的 CUDA 版本。
# =====================================================================

function Get-GpuBackend {
    <#
      返回 @{ Backend = 'cuda'|'vulkan'|'cpu'; CudaVersion = '12.4'|...; GpuName; Note }

      判断顺序：
        1. nvidia-smi 能跑 → 读它的 CUDA Version → cuda 后端
        2. 没有 NVIDIA → 试 Vulkan（AMD/Intel 独显通常支持）
        3. 都不行 → cpu
    #>
    $result = [pscustomobject]@{
        Backend     = 'cpu'
        CudaVersion = $null
        GpuName     = $null
        Note        = $null
    }

    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($smi) {
        try {
            # 第一行表头里带 "CUDA Version: 13.4"
            $header = & nvidia-smi 2>$null | Select-Object -First 4
            $cuda = $null
            foreach ($line in $header) {
                if ($line -match 'CUDA Version:\s*([0-9]+\.[0-9]+)') { $cuda = $Matches[1]; break }
            }
            $name = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1

            $result.Backend = 'cuda'
            $result.GpuName = if ($name) { $name.Trim() } else { 'NVIDIA GPU' }
            $result.CudaVersion = $cuda

            if ($cuda) {
                $major = [int]($cuda.Split('.')[0])
                # llama.cpp 发布包按 12.4 / 13.4 这类版本切
                # 驱动报 13.x 就用 13.4 包；12.x 用 12.4 包
                if ($major -ge 13) {
                    $result.Note = "CUDA $cuda → 用 cuda-13.4 版"
                } else {
                    $result.Note = "CUDA $cuda → 用 cuda-12.4 版"
                }
            } else {
                $result.Note = "读到 NVIDIA 显卡但没读到 CUDA 版本，默认 cuda-12.4"
            }
            return $result
        } catch {
            $result.Note = "nvidia-smi 执行失败：$($_.Exception.Message)"
        }
    }

    # 没有 NVIDIA：Vulkan 是跨厂商的，AMD/Intel 独显多半能用
    $result.Backend = 'vulkan'
    $result.Note = "没检测到 NVIDIA 显卡，尝试 Vulkan 版（AMD/Intel 也能用）"
    return $result
}

function Get-LlamaReleaseInfo {
    <#
      查 llama.cpp 的最新构建并挑出要下的两个包。

      ⚠️ 不能用 /releases/latest —— 它返回的是里程碑式的 release（如 v1.0.0），
         只有一两个 asset，没有 Windows 构建。真正的构建发布在 releases 列表里，
         tag 形如 b12674，每个都带 38 个 asset。

      CUDA 版本也跟着构建号变（b12110 是 cuda-13.4，b12674 是 cuda-13.5），
      所以不能硬编码，要从实际 asset 列表里挑。
    #>
    param([string]$Backend = 'cuda', [int]$CudaMajor = 12)

    $api = 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10'
    $releases = $null
    try {
        $releases = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'llama-launcher' } -TimeoutSec 40
    } catch {
        return [pscustomobject]@{ Ok = $false; Error = "访问 GitHub API 失败：$($_.Exception.Message)" }
    }

    if (-not $releases -or $releases.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Error = "GitHub 没返回 release 列表" }
    }

    # 找第一个 tag 匹配 b<数字> 且有 Windows 包的 release
    $rel = $null
    foreach ($r in $releases) {
        if ($r.tag_name -notmatch '^b\d+$') { continue }
        $winAssets = @($r.assets | Where-Object { $_.name -like '*win*x64*.zip' })
        if ($winAssets.Count -gt 0) { $rel = $r; break }
    }
    if (-not $rel) {
        return [pscustomobject]@{ Ok = $false; Error = "最近的 release 里没找到带 Windows 包的构建" }
    }

    $tag = $rel.tag_name
    $assets = $rel.assets

    $main = $null
    $cudart = $null

    if ($Backend -eq 'cuda') {
        # 看这个构建里有哪些 CUDA 版本，挑和驱动同大版本里最新的
        $cudaVerPattern = 'llama-' + [regex]::Escape($tag) + '-bin-win-cuda-(\d+)\.(\d+)-x64\.zip'
        $candidates = @()
        foreach ($a in $assets) {
            $m = [regex]::Match($a.name, $cudaVerPattern)
            if ($m.Success) {
                $candidates += [pscustomobject]@{
                    Asset = $a
                    Major = [int]$m.Groups[1].Value
                    Minor = [int]$m.Groups[2].Value
                }
            }
        }
        if ($candidates.Count -gt 0) {
            # 优先同大版本（12.x 驱动配 12.x 包），没有再退回最新
            $same = @($candidates | Where-Object { $_.Major -eq $CudaMajor })
            $chosen = if ($same.Count -gt 0) {
                $same | Sort-Object Minor -Descending | Select-Object -First 1
            } else {
                $candidates | Sort-Object Major, Minor -Descending | Select-Object -First 1
            }
            $main = $chosen.Asset
            $verStr = "$($chosen.Major).$($chosen.Minor)"
            # 对应的 cudart
            $cudart = $assets | Where-Object {
                $_.name -eq "cudart-llama-bin-win-cuda-$verStr-x64.zip"
            } | Select-Object -First 1
        }
    } else {
        $main = $assets | Where-Object {
            $_.name -eq "llama-$tag-bin-win-$Backend-x64.zip"
        } | Select-Object -First 1
    }

    # 目标后端没包时，退回 cpu（一定能跑，只是慢）
    $fallbackNote = $null
    if (-not $main) {
        $cpuPkg = $assets | Where-Object { $_.name -eq "llama-$tag-bin-win-cpu-x64.zip" } | Select-Object -First 1
        if ($cpuPkg) {
            $main = $cpuPkg
            $fallbackNote = "没找到 $Backend 版，改用 cpu 版（能跑，但用不了显卡加速）"
            $Backend = 'cpu'
            $cudart = $null
        } else {
            $avail = ($assets | Where-Object { $_.name -like '*win*x64*.zip' } | ForEach-Object { $_.name }) -join ', '
            return [pscustomobject]@{ Ok = $false; Error = "这个构建里没有可用的 Windows 包。可选：$avail" }
        }
    }

    return [pscustomobject]@{
        Ok           = $true
        Tag          = $tag
        Main         = $main
        Cudart       = $cudart
        Backend      = $Backend
        FallbackNote = $fallbackNote
    }
}

function Invoke-DownloadWithMirror {
    <#
      多路线下载。GitHub 直连在国内经常超时，按顺序试镜像。
      返回 @{ Ok; Path; Error; Via }
    #>
    param(
        [string]$Url,
        [string]$DestPath,
        [string]$Label = '文件'
    )

    $sizeMB = 0
    # 先问大小，好给用户一个预期
    try {
        $head = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 20 -UseBasicParsing
        if ($head.Headers['Content-Length']) {
            $sizeMB = [math]::Round([int64]$head.Headers['Content-Length'] / 1MB)
        }
    } catch { }

    # 镜像前缀。注意顺序：国内能直连的镜像排前面
    $mirrors = @(
        @{ Name = 'GitHub 直连'; Prefix = '' },
        @{ Name = 'ghfast.top';  Prefix = 'https://ghfast.top/' },
        @{ Name = 'gh-proxy';    Prefix = 'https://gh-proxy.com/' },
        @{ Name = 'moeyy';       Prefix = 'https://github.moeyy.xyz/' }
    )

    foreach ($m in $mirrors) {
        $tryUrl = if ($m.Prefix) { "$($m.Prefix)$Url" } else { $Url }
        Write-Host "    尝试 $($m.Name)..." -NoNewline -ForegroundColor DarkGray
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Invoke-WebRequest -Uri $tryUrl -OutFile $DestPath -TimeoutSec 600 -UseBasicParsing -ErrorAction Stop
            $sw.Stop()
            $actualMB = [math]::Round((Get-Item $DestPath).Length / 1MB)
            if ($actualMB -lt 10) {
                Write-Host " 文件太小（${actualMB}MB），可能下到了错误页" -ForegroundColor Yellow
                continue
            }
            Write-Host " OK（${actualMB}MB，$([math]::Round($sw.Elapsed.TotalSeconds))秒）" -ForegroundColor Green
            return [pscustomobject]@{ Ok = $true; Path = $DestPath; Via = $m.Name; Error = $null }
        } catch {
            Write-Host " 失败" -ForegroundColor DarkGray
            if (Test-Path $DestPath) { Remove-Item $DestPath -Force -ErrorAction SilentlyContinue }
        }
    }

    return [pscustomobject]@{ Ok = $false; Path = $null; Via = $null; Error = '所有下载路线都失败了' }
}

function Install-LlamaCpp {
    <#
      完整流程：选后端 → 查最新版 → 下载 → 解压 → 校验 → 返回可用的目录
    #>
    param([string]$TargetRoot)

    Write-Host ""
    Write-Host "  正在检测显卡..." -ForegroundColor Cyan
    $gpu = Get-GpuBackend
    if ($gpu.GpuName) { Write-Host "    显卡：$($gpu.GpuName)" -ForegroundColor Gray }
    Write-Host "    $($gpu.Note)" -ForegroundColor Gray

    Write-Host ""
    Write-Host "  正在查询 llama.cpp 最新版本..." -ForegroundColor Cyan
    # 传大版本号就够，具体小版本从实际 asset 列表里挑
    # （别用 ?? 运算符，那是 PowerShell 7 才有的，5.1 会语法报错）
    $cudaMajor = 12
    if ($gpu.CudaVersion) {
        $cudaMajor = [int]($gpu.CudaVersion.Split('.')[0])
    }
    $info = Get-LlamaReleaseInfo -Backend $gpu.Backend -CudaMajor $cudaMajor
    if (-not $info.Ok) {
        Write-Host "  X  $($info.Error)" -ForegroundColor Red
        return $null
    }

    if ($info.FallbackNote) {
        Write-Host "    !  $($info.FallbackNote)" -ForegroundColor Yellow
    }
    Write-Host "    版本：$($info.Tag)" -ForegroundColor Gray
    Write-Host "    主程序：$($info.Main.name)  ($([math]::Round($info.Main.size/1MB))MB)" -ForegroundColor Gray
    if ($info.Cudart) {
        Write-Host "    运行库：$($info.Cudart.name)  ($([math]::Round($info.Cudart.size/1MB))MB)" -ForegroundColor Gray
    }

    $totalMB = [math]::Round($info.Main.size / 1MB) + $(if ($info.Cudart) { [math]::Round($info.Cudart.size / 1MB) } else { 0 })
    Write-Host ""
    Write-Host "  总共要下载约 ${totalMB}MB" -ForegroundColor Yellow

    if (-not (Test-Path $TargetRoot)) {
        try { New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null }
        catch {
            Write-Host "  X  无法创建目录 $TargetRoot：$($_.Exception.Message)" -ForegroundColor Red
            return $null
        }
    }

    $tmp = Join-Path $env:TEMP "llama-dl-$(Get-Random)"
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        # --- 下主程序 ---
        Write-Host ""
        Write-Host "  [1/2] 下载主程序" -ForegroundColor Cyan
        $dl = Invoke-DownloadWithMirror -Url $info.Main.browser_download_url `
                                        -DestPath (Join-Path $tmp $info.Main.name) -Label '主程序'
        if (-not $dl.Ok) {
            Write-Host "  X  主程序下载失败：$($dl.Error)" -ForegroundColor Red
            return $null
        }
        $mainZip = $dl.Path

        # --- 下运行库 ---
        $cudartZip = $null
        if ($info.Cudart) {
            Write-Host ""
            Write-Host "  [2/2] 下载运行库（CUDA 需要，缺了会报找不到 cudart64_*.dll）" -ForegroundColor Cyan
            $dl2 = Invoke-DownloadWithMirror -Url $info.Cudart.browser_download_url `
                                             -DestPath (Join-Path $tmp $info.Cudart.name) -Label '运行库'
            if ($dl2.Ok) { $cudartZip = $dl2.Path }
            else { Write-Host "  !  运行库下载失败，稍后可以手动补" -ForegroundColor Yellow }
        }

        # --- 解压 ---
        Write-Host ""
        Write-Host "  正在解压..." -ForegroundColor Cyan
        $extractDir = Join-Path $tmp 'x'
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        try {
            Expand-Archive -Path $mainZip -DestinationPath $extractDir -Force
            if ($cudartZip) {
                Expand-Archive -Path $cudartZip -DestinationPath $extractDir -Force
            }
        } catch {
            Write-Host "  X  解压失败：$($_.Exception.Message)" -ForegroundColor Red
            return $null
        }

        # --- 校验：真的解出了 llama-server.exe 吗 ---
        $exe = Get-ChildItem -Path $extractDir -Filter 'llama-server.exe' -Recurse -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if (-not $exe) {
            Write-Host "  X  解压后没找到 llama-server.exe，包可能不完整" -ForegroundColor Red
            return $null
        }

        # --- 搬到目标目录，保留构建号命名 ---
        $buildMatch = [regex]::Match($info.Main.name, 'llama-b(\d+)')
        $buildNum = if ($buildMatch.Success) { $buildMatch.Groups[1].Value } else { 'unknown' }
        $finalDir = Join-Path $TargetRoot "llama-b$buildNum-bin-win-$($info.Backend)-x64"

        if (Test-Path $finalDir) {
            Write-Host "  目标目录已存在，写入里面" -ForegroundColor Yellow
        } else {
            New-Item -ItemType Directory -Path $finalDir -Force | Out-Null
        }

        # exe 可能在子目录里（包内常带一层目录），把那一层的内容搬出来
        $srcRoot = $exe.DirectoryName
        Get-ChildItem -Path $srcRoot -Force | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $finalDir -Force -ErrorAction SilentlyContinue
        }
        # 运行库可能解到别处，也一起搬
        if ($cudartZip) {
            Get-ChildItem -Path $extractDir -Filter '*.dll' -Recurse -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $target = Join-Path $finalDir $_.Name
                    if (-not (Test-Path $target)) { Copy-Item $_.FullName $target -Force -ErrorAction SilentlyContinue }
                }
        }

        if (-not (Test-Path (Join-Path $finalDir 'llama-server.exe'))) {
            Write-Host "  X  整理后仍然没有 llama-server.exe" -ForegroundColor Red
            return $null
        }

        Write-Host ""
        Write-Host "  ✔ 安装完成：$finalDir" -ForegroundColor Green
        return $finalDir
    } finally {
        # 清临时文件，失败也不留垃圾
        if (Test-Path $tmp) {
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
