# 发布流程

## 改了什么就做什么

| 改动了 | 要做的事 |
|---|---|
| 只改 `.md` 文档 | 直接提交，不用重签 |
| 改了任何 `.ps1` / `.bat` | **必须重算 SHA256SUMS 并重新签名** |
| 新增脚本 | 同上，且要加进 `SHA256SUMS` 的登记列表 |

CI 会拦住不一致：脚本哈希对不上、有 `.minisig` 但验不过，都会让 CI 失败。

## 一次完整发布

```bash
# 1. 改脚本
# 2. 更新 CHANGELOG.md
# 3. 重算校验值
bash scripts/sign-release.sh

# 4. 自查
python3 scripts/check-repo-consistency.py
# 退出码 0 才算完

# 5. 提交推送
git add -A && git commit -m "..." && git push
```

## 签名为什么必须在本机做

`SHA256SUMS` 里登记的是脚本的哈希。用私钥给它签名，等于对外声明
「这个哈希是我本人确认过的」。别人下载后先验签名、再验哈希，
中间任何一环被改都会失败。

私钥**不上服务器、不进聊天记录、不进 git**。所以这一步只能由私钥持有人
在自己机器上执行，每次发布都要重来一遍 —— 这是离线私钥的固有代价，
也正是签名之所以有价值的原因。

签名用法（Windows）：

```
minisign.exe -S -s minisign.key -m SHA256SUMS
```

会问一次密码，生成的 `SHA256SUMS.minisig` 一起提交。

## 当前密钥

```
Key ID    B77452EF0FED6854
公钥      minisign.pub（仓库根目录）
```

换密钥时：生成新密钥对 → 替换 `minisign.pub` → 重签 `SHA256SUMS` →
在 CHANGELOG 里记一笔，说明旧密钥作废、现役是哪把。
