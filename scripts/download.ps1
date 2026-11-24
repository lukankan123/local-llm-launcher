# =====================================================================
#  llama.cpp 自动下载
#
#  找不到 llama.cpp 时，问用户要不要下载。不静默下 —— 几百 MB 的
#  下载是有后果的动作，得让人知道。
#
#  难点在选哪个包：llama.cpp 每个 release 有多种后端，选错跑不起来。
#  判断依据是显卡和驱动支持的 CUDA 版本。
# =====================================================================

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ⚠️ 关键：PowerShell 5.1 下 Invoke-WebRequest 每收一块数据就重绘进度条，
# 下载几百 MB 的文件会慢十倍以上（几分钟变一小时）。
# 关掉进度显示是最有效的加速手段，比换下载方式还管用。
$ProgressPreference = 'SilentlyContinue'

function Get-GpuBackend {
    <#
      返回 @{ Backend; CudaVersion; CudaUsable; GpuName; ComputeCap; Note }

      ⚠️ 关键坑：nvidia-smi 报的 "CUDA Version" 是【驱动】能支持的最高版本，
      不等于【显卡架构】能用的版本。

      NVIDIA 在 CUDA 13.0 里移除了 Maxwell / Pascal / Volta 的支持
      （Pascal = GTX 10 系，compute capability 6.1）。装了最新驱动的 1060
      依然会报 CUDA 13.x，但下 cuda-13 的包给它跑必然失败
      （症状：no kernel image is available for execution）。

      所以判断顺序是：先看 compute capability，再看驱动 CUDA 版本。
        CC < 7.5  -> 只能用 12.x（Maxwell 5.x / Pascal 6.x / Volta 7.0）
        CC >= 7.5 -> 可用 13.x
    #>
    $result = [pscustomobject]@{
        Backend     = 'cpu'
        CudaVersion = $null
        CudaUsable  = $null    # 显卡真正能用的 CUDA 大版本
        GpuName     = $null
        ComputeCap  = $null
        Note        = $null
    }

    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        $result.Backend = 'vulkan'
        $result.Note = "没检测到 NVIDIA 显卡，尝试 Vulkan 版（AMD/Intel 也能用）"
        return $result
    }

    try {
        # 显卡名
        $name = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1
        $result.GpuName = if ($name) { $name.Trim() } else { 'NVIDIA GPU' }

        # 驱动支持的 CUDA 版本（从表头读）
        $driverCuda = $null
        $header = & nvidia-smi 2>$null | Select-Object -First 4
        foreach ($line in $header) {
            if ($line -match 'CUDA Version:\s*([0-9]+\.[0-9]+)') { $driverCuda = $Matches[1]; break }
        }

        # 计算能力（决定架构能不能用新 CUDA）
        $cc = $null
        $ccRaw = & nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>$null | Select-Object -First 1
        if ($ccRaw -and $ccRaw.Trim() -match '^(\d+)\.(\d+)$') {
            $cc = [double]"$($Matches[1]).$($Matches[2])"
            $result.ComputeCap = $cc
        }

        # 老版本驱动没有 compute_cap 查询项，靠显卡型号兜底
        if ($null -eq $cc) {
            $legacy = @('GTX 9', 'GTX 10', 'Tesla P', 'Tesla M', 'Quadro P', 'Quadro M',
                        'MX1', 'MX2', 'MX3', 'GT 10', 'GT 9', 'P106', 'P104', 'V100')
            foreach ($k in $legacy) {
                if ($result.GpuName -like "*$k*") { $cc = 6.1; $result.ComputeCap = 6.1; break }
            }
        }

        $result.Backend = 'cuda'
        $result.CudaVersion = $driverCuda

        # 决定能用哪个大版本
        if ($null -ne $cc -and $cc -lt 7.5) {
            # Pascal 及更老：CUDA 13 已移除支持
            $result.CudaUsable = 12
            $archName = if ($cc -lt 6.0) { 'Maxwell' } elseif ($cc -lt 7.0) { 'Pascal' } else { 'Volta' }
            $result.Note = "检测到 $archName 架构（CC $cc），CUDA 13 已不支持它 → 用 cuda-12 版"
        } elseif ($driverCuda) {
            $major = [int]($driverCuda.Split('.')[0])
            if ($major -ge 13) {
                $result.CudaUsable = 13
                $result.Note = "驱动支持 CUDA $driverCuda，架构也够新 → 用 cuda-13 版"
            } else {
                $result.CudaUsable = 12
                $result.Note = "驱动支持 CUDA $driverCuda → 用 cuda-12 版"
            }
        } else {
            $result.CudaUsable = 12
            $result.Note = "读不到 CUDA 版本，保守用 cuda-12 版"
        }

        # 老卡额外提示：Vulkan 往往更稳
        if ($null -ne $cc -and $cc -lt 7.5) {
            $result.Note += "`n    （老架构如果 CUDA 版报错，可以改试 Vulkan 版，跨厂商且对老卡友好）"
        }
        return $result
    } catch {
        $result.Backend = 'cuda'
        $result.CudaUsable = 12
        $result.Note = "检测显卡出错：$($_.Exception.Message)，保守用 cuda-12 版"
        return $result
    }
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
        # -UseBasicParsing：PS 5.1 下不加这个可能走 IE 引擎，
        # 机器上 IE 首次运行向导没点过就会莫名失败
        $releases = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'llama-launcher' } `
                                      -TimeoutSec 40 -UseBasicParsing
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
            # 优先同大版本（12.x 架构配 12.x 包）
            $same = @($candidates | Where-Object { $_.Major -eq $CudaMajor })
            $chosen = if ($same.Count -gt 0) {
                $same | Sort-Object Minor -Descending | Select-Object -First 1
            } elseif ($CudaMajor -ge 13) {
                # 新架构找不到 13.x 包时退 12.x 可以（向下兼容）
                $candidates | Sort-Object Major, Minor -Descending | Select-Object -First 1
            } else {
                # 老架构（要 12.x）找不到 12.x 时【不能】升到 13.x，那是跑不了的
                $null
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
    if (-not $main -and $Backend -eq 'cuda' -and $CudaMajor -lt 13) {
        # 老架构要 12.x 但包里没有 —— 试 Vulkan，比 CPU 快得多
        $vulkan = $assets | Where-Object { $_.name -eq "llama-$tag-bin-win-vulkan-x64.zip" } | Select-Object -First 1
        if ($vulkan) {
            $main = $vulkan
            $Backend = 'vulkan'
            $cudart = $null
            $fallbackNote = "这个构建没有 cuda-12.x 包（老显卡只能用它），改用 Vulkan 版"
        }
    }
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
        $head = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
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
            # 用 .NET 的 WebClient 而不是 Invoke-WebRequest：
            #   · IWR 在 5.1 下即使关了进度条也比 WebClient 慢
            #   · WebClient 支持超时设置和断点信息（这里先不做续传）
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'llama-launcher')
            $wc.Timeout = 600000
            try {
                $wc.DownloadFile($tryUrl, $DestPath)
            } finally {
                $wc.Dispose()
            }
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
    # 注意用 CudaUsable（架构能用的大版本），不是 CudaVersion（驱动支持的）
    # 别用 ?? 运算符，那是 PowerShell 7 才有的，5.1 会语法报错
    $cudaMajor = 12
    if ($gpu.CudaUsable) { $cudaMajor = [int]$gpu.CudaUsable }
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

    # ⚠️ 不能放 $env:TEMP —— 那是 C 盘。下载 400MB + 解压 1GB 全落在
    # C:\Users\<你>\AppData\Local\Temp，C 盘紧的机器会直接失败。
    # 改在目标盘上建临时目录，跨盘搬运也省了。
    $tmpParent = $TargetRoot
    try {
        if (-not (Test-Path $tmpParent)) { New-Item -ItemType Directory -Path $tmpParent -Force | Out-Null }
    } catch { }
    $tmp = Join-Path $tmpParent ".llama-dl-$(Get-Random)"

    # 空间检查：两个包加起来 + 解压后约 2.5 倍
    $needMB = 0
    if ($info.Main) { $needMB += [math]::Round($info.Main.size / 1MB) }
    if ($info.Cudart) { $needMB += [math]::Round($info.Cudart.size / 1MB) }
    $needMB = [math]::Round($needMB * 2.5)

    try {
        $driveLetter = (Split-Path $tmpParent -Qualifier)
        $drive = Get-PSDrive -Name $driveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($drive -and $drive.Free -ne $null) {
            $freeMB = [math]::Round($drive.Free / 1MB)
            Write-Host "    目标盘 $driveLetter 可用 $([math]::Round($drive.Free/1GB,1)) GB，本次约需 ${needMB}MB" -ForegroundColor Gray
            if ($freeMB -lt $needMB) {
                Write-Host "  X  磁盘空间不够（差约 $($needMB - $freeMB)MB）" -ForegroundColor Red
                Write-Host "     清一下再试，或者把 config.ps1 里的 `$LLAMA_DIR 指到空间大的盘" -ForegroundColor Gray
                return $null
            }
        }
    } catch { }

    try { New-Item -ItemType Directory -Path $tmp -Force | Out-Null }
    catch {
        Write-Host "  X  无法创建临时目录 $tmp：$($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

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
