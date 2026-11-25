# Mac 合盖限时保活

在 MacBook 拔电、连接手机热点时，让 Codex 等后台任务在合盖后继续运行一段时间。**倒计时从合盖开始。到期时如果盖子仍合着，工具会恢复睡眠权限并主动请求 macOS 立即睡眠。**

### 使用桌面 App

1. 在 MacBook 上下载或克隆仓库。用 macOS 14 或更新版本和 Xcode 命令行工具运行 `bash tools/build-app.sh`，在 `build/` 打开生成的 **合盖保活.app**。
2. 在主窗口直接输入 **1 到 120 分钟**，App 会记住上次设置。点「开启保活」，然后在 **3 分钟内合盖**。
3. 点同一个位置的「结束保活」，可提前结束。提前开盖也会结束本次保活。等待合盖时，关闭 App 窗口不会取消保活。

**可以提前授权。** 在右上角点「授权设置」并完成一次 macOS 管理员授权。之后此账号可以直接开启和结束保活。App 不存储管理员密码。随时可以在同一位置撤销授权；也可以跳过这项设置，在使用时按 macOS 提示单次授权。

App 会自动判断机盖、电量、温度和睡眠设置。如果当前无法开启，就显示原因，并在条件恢复后重新显示开启入口。

### 使用命令行

在仓库目录双击 `lid-hold.command`，输入分钟数或用下面的命令。如果下载后的文件缺少执行权限，运行 `chmod +x lid-hold.command test-codex-lid.command`。

```sh
./lid-hold.command 30      # 选 30 分钟
./lid-hold.command 60      # 选 1 小时
./lid-hold.command 5       # 五分钟档，适合桌面测试
./lid-hold.command 47      # 自定义 1 到 120 分钟
./lid-hold.command status  # 查看保活记录与当前睡眠开关，无需管理员密码
./lid-hold.command stop    # 提前结束，仍合盖时也会请求睡眠
```

保活脚本使用 macOS 自带命令，需要能读取机盖状态和电池信息。首次使用建议先试五分钟档。

### 睡眠、权限与风险

- 启动保活时，脚本通过 `sudo` 临时启动一个系统后台任务，并用 `pmset` 关闭系统睡眠。到期后，它先恢复系统睡眠，再按机盖状态决定是否调用 `pmset sleepnow`。看到「已请求立即睡眠」表示命令已发出。是否实际入睡，以 macOS 的睡眠日志为准。
- 状态保存在 `/private/var/run/local.mac-lid-keep-awake/`，后台任务由 `launchd` 管理，异常退出时会尝试恢复睡眠设置。App 与命令行共用同一次保活。保活和睡眠开关影响整台 Mac，请一次只使用一种保活工具。
- 只有在选择「提前授权」时，App 才会安装该账号专用的特权辅助脚本及一条 `sudoers` 规则。规则校验脚本摘要，只允许传入 1 到 120 分钟或 `stop`，同账号的程序也可调用这一受限入口。「撤销授权」会移除这两项配置。
- 电量降到 **20% 或以下**，或 macOS 报告严重热压力时，脚本会提前结束保活。合盖运行仍会耗电和发热。请在通风的桌面测试，装包前先结束保活。
- 到期睡眠会暂停 Mac 上仍在运行的本地任务。需要不中断的工作请留足时间。

### 验证 Codex 与到点睡眠

**真机测试**需要 Python 3、可运行且已登录的 Codex，以及手机热点。测试优先选择 ChatGPT 桌面应用随附的 Codex，否则从 `PATH` 查找，也可用 `CODEX_BIN` 指定 Codex 可执行文件的绝对路径。

1. 在通风的桌面上保持开盖，拔掉电源，连接手机热点。
2. 双击 `test-codex-lid.command`。脚本先做开盖基准请求，成功后在终端按提示授权五分钟保活。
3. 看到「现在可以合盖」后合盖，等待约 **6 分钟**再开盖。
4. 在 `reports/` 查看自动生成的 Markdown 报告。它分别判断合盖期间 Codex 是否收到真实回复、睡眠权限是否恢复，以及系统日志能否确认实际入睡。

测试发送一次开盖请求和最多四次合盖请求，可能计入 Codex 用量。请求在独立、只读的临时会话中运行，验证的是本机 Codex 后台与联网响应。脚本不会测试桌面界面、已有会话或某项业务任务能否持续运行。报告留在本机，默认由 Git 忽略。

**模拟回归测试**在 macOS 上运行，使用模拟的 `pmset`、机盖传感器和 `launchctl`，覆盖倒计时从合盖开始、到期睡眠请求、提前开盖、保护条件及异常退出后的恢复。它无需管理员权限或 Codex 账号。

```sh
/usr/bin/python3 tests/test_lid_hold.py
/usr/bin/python3 tests/test_authorization.py
```

**界面回归测试**使用真实原生控件和隔离的测试状态，覆盖自定义时长、取消授权、开启、结束、撤销授权以及条件恢复。无需修改系统授权或真的让 Mac 睡眠。先构建 App，再运行：

```sh
xcrun swiftc -swift-version 5 app/HoldState.swift app/HoldView.swift app/AuthorizationView.swift tests/UseApp.swift -o build/use-app
build/use-app 'build/合盖保活.app' build/review
```

实现时参考了 [LidAwake 的公开睡眠管理机制](https://github.com/Vladimir-Podgornyi/LidAwake#how-it-works)。本仓库的脚本可独立运行。
