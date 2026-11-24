# 踩过的坑

改 `start.ps1` 里的参数分流逻辑之前，先看这份。每条都是实际跑崩或跑出毛病之后总结的。

## 工具调用死锁成循环

**症状**：客户端（SillyTavern / Cherry Studio 这类）反复调用同一个工具，停不下来。

**原因**：混合架构模型（attention + SSM，例如 Ornith 系列）的工具调用要靠 chat template
序列化，`llama-server` 不加载模板就会把工具定义当普通文本，模型只能反复吐同一段。

**修法**：启动参数必须带 `--jinja`。脚本里 `ornith` 和 `spark` 关键词分支已经自动加上了。

## 模型碎嘴复读

**症状**：输出一段话之后开始重复，越重复越快，不撞到 token 上限不罢休。

**原因**：重复惩罚偏低。混合架构模型比纯 transformer 更容易进这个状态。

**修法**：`--repeat-penalty` 提到 1.1（默认 1.05），配合 `--repeat-last-n 256`。
Ornith 分支已经这么设了。如果还复读，可以再提到 1.15，但太高会让用词僵硬。

## Spark-X2.5 报 unknown architecture

**症状**：启动直接失败，日志里 `unknown model architecture: spark2_5`。

**原因**：`spark2_5` 是较新的架构，旧版 llama.cpp 不认识。最低构建号约 b10828。

**修法**：升级 llama.cpp。脚本会在启动前跑 `llama-server --version` 自检，
低于 `$MIN_BUILD` 会提前警告，不用等启动失败。

⚠️ 解析版本号有个坑：新版输出是 `version 0.4.1-dev (build 10964, commit ...)`，
**要取 `build` 后面那个数字**，不能取第二个词 —— 那拿到的是 `0.4.1-dev`，
掐掉非数字变成 `041`，会把达标的 b10964 误判成版本过低。

## 视觉投影文件匹配不上

**症状**：带视觉的模型启动后，`Vision: 无（纯文本）`，图片喂不进去。

**原因**：视觉投影文件命名五花八门（`Huihui-Ornith-9B.mmproj-Q8_0.gguf`），
不能靠拼字符串。而且批处理的字符串替换**不区分大小写** ——
如果量化档列表里 `F16` 排在 `BF16` 前面，`bf16` 会先被削成 `b`，
归一化结果错掉，永远匹配不上。

**修法**：两边都归一化（去扩展名、去 `mmproj`、去量化档 token、去分隔符），
再比对。**量化档列表必须长的在前**：`BF16 FP16 FP8` 排在 `F16` 之前，
万一加了新的量化档，按字符串长度降序排就对了。

## 端口占用导致 couldn't bind HTTP server socket

**症状**：`llama-server` 启动即退出，报 `couldn't bind HTTP server socket`。

**原因**：上次的 `llama-server` 没退干净（关窗口不一定杀进程）。

**修法**：脚本启动前查端口。如果占用者进程名含 `llama`，可以直接选择结束它；
如果占用者是别的程序，自动改用 1235、1236…… 最多试到 1240。

## 渲染大上下文后显存爆掉

**症状**：`failed to allocate`，或跑着跑着被系统杀掉。

**原因**：KV cache 占用随上下文线性增长。128K 上下文 + 视觉 + 不量化 KV，8 GB 卡扛不住。

**修法**：上下文压到 64K，或把 `$KV_CACHE_TYPE` 设成 `q4_0`（脚本默认在 ctx ≥ 64K 时自动用 q4_0）。

## 显存被别的程序占着

**症状**：`nvidia-smi` 显示空闲显存比预期少 GB。

**原因**：浏览器硬件加速、壁纸软件（Wallpaper Engine 之类）、NVIDIA 覆盖层都会吃显存。

**修法**：跑模型前关掉这些。开独显直连（MUX）的机器，桌面合成器本身也会占几百 MB。

## 配置加载报 Cannot overwrite variable Host

**症状**：跑 `doctor.bat` 报 `Cannot overwrite variable Host because it is read-only or constant`。

**原因**：配置里变量名叫 `$HOST`，而 PowerShell 的 `$Host` 是内置只读变量，
**变量名不区分大小写**，等于要覆盖系统变量。

**修法**：已改名 `$LISTEN_HOST`。写 PowerShell 脚本时避开这些保留名：
`Host` `PID` `HOME` `PWD` `Error` `Args` `Input` `PSVersionTable` 等。
