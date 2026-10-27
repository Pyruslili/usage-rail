# Usage Rail

一条贴在屏幕右边的粉缝。平时收着，鼠标靠上去才展开。读的是这台 Mac 上已经登录的订阅。

A pink seam on the right edge. It stays shut until you lean in. macOS 14+.

| Ring | Account |
|---|---|
| GPT | `~/.codex/auth.json` |
| Grok | `~/.grok/auth.json` |
| Kimi | `~/.kimi/credentials/kimi-code.json` |
| Claude | `~/.claude/.credentials.json`, or a macOS keychain item named `Claude Code-credentials` |
| DeepSeek | `DEEPSEEK_API_KEY` |

GPT and Claude draw a 5-hour ring and a weekly ring. Grok is weekly. Kimi is monthly, and the card also shows the 5-hour window. DeepSeek shows the account balance.

```sh
swift build -c release --product UsageRail
./launch.sh
```

`install/com.usage-rail.plist.example` is the login item. Copy it to `~/Library/LaunchAgents/com.usage-rail.plist`, replace the paths, then:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.usage-rail.plist
```

Numbers are written to `~/.cache/usage-rail/usage.json`.

手机上的圆环是另一个仓库：[usage-rail-phone](https://github.com/Pyruslili/usage-rail-phone)。它不采集，只看这份文件，或者一个返回同样内容的地址。
