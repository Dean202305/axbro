# axbro

仅支持 Codex 的 macOS 菜单栏实时用量看板。

- 菜单栏采用环形进度＋剩余百分比，固定占位、适配深浅色和高亮；悬停或点击展开，每 5 秒刷新。
- 低于 5% 环形变红；未知显示 —%，过期数据使用灰色环形与点标记。
- 270 × 227 pt 双环主面板，等大的仪表显示短期与每周剩余用量，标签与重置日期对齐，保留实时时间和日期。
- 波形数字胶囊显示本机任务数；空闲显示“空闲”，未知状态单独呈现，悬停查看说明。
- 固定到桌面，记住固定状态与窗口位置。
- 低用量和重置声音提醒，可选择系统提示音，点击即播放。
- 定位城市与温度，天气图标及下方中文说明随天气与昼夜变化，独立于背景通透度。
- 白天保留原始比例天气素材，夜间晴天显示月亮；所有页面共享天气底色与毛玻璃。
- 设置旁的 ChatGPT 标志菜单可打开或退出 Codex。
- 随 Codex 启动和退出；仅使用安装者自己的本机数据。

## 安装

从 [Releases](https://github.com/Dean202305/axbro/releases) 下载安装包 ZIP，解压后双击 `安装.command`。

要求 macOS 13+、已登录的 Codex，以及 Python 3（Homebrew 或 Command Line Tools）。安装包支持 Intel 和 Apple 芯片。当前为临时签名，尚未 Apple 公证；Apple 芯片版交叉编译，未在实体机器验证。

## 从源码构建

需要 macOS 与 Xcode Command Line Tools。运行：

```sh
./build.command
./启动.command
```

生成通用 `axbro.app` 和启动监听组件。运行 `./package.command` 生成安装包；`dist/`、构建产物及安装包不进入 Git。

## 验证

```sh
python3 Source/test_monitor.py
python3 Source/test-local-isolation.py
xcrun swiftc -parse-as-library Source/Weather.swift Source/test_weather.swift -o /tmp/axbro-weather-tests -framework AppKit -framework SwiftUI -framework CoreLocation
/tmp/axbro-weather-tests
xcrun swiftc -parse-as-library Source/StatusQuotaIndicator.swift Source/test_status_icon.swift -o /tmp/axbro-status-tests -framework AppKit
/tmp/axbro-status-tests
```

## 数据说明

通过 Codex app-server 的只读 `account/rateLimits/read` 读取额度。任务数来自当前用户本机日志，等待输入也可能计入，不涵盖云端、其他设备及内部子代理。运行任务不代表持续消耗额度；未知数据不会伪造为零。

源码和安装包不含个人登录信息、聊天、用量、定位缓存或偏好。应用不调用模型、不兑换重置、不修改聊天。天气由 Open-Meteo 提供，需独立授权定位。

详见 [使用说明](使用说明.md)。个人工具，非 OpenAI 官方产品。
