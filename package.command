#!/bin/zsh
set -eu
cd "$(dirname "$0")"
PACKAGE_ROOT="dist"
PACKAGE="$PACKAGE_ROOT/axbro-安装包"
if [[ -d "$PACKAGE" ]]; then rm -rf "$PACKAGE"; fi
mkdir -p "$PACKAGE/Runtime"
ditto --norsrc --noextattr "axbro.app" "$PACKAGE/axbro.app"
cp Runtime/CodexMiniLifecycle "$PACKAGE/Runtime/CodexMiniLifecycle"
cp 设置随Codex启动.command "$PACKAGE/安装.command"
cp 取消随Codex启动.command "$PACKAGE/取消自动关联.command"
cat > "$PACKAGE/安装说明.txt" <<'TXT'
axbro 1.18.1 — 仅支持 Codex，macOS 13+，Intel 与 Apple 芯片通用版

双击“安装.command”，安装到当前用户 Applications，启用随 Codex 启动与退出。
读取额度需要本机已登录的 Codex，以及 Python 3（Homebrew 或 Command Line Tools）。
采用独立的 axbro“a＋余量环”应用标志。
菜单栏使用 a 形品牌余量标志＋剩余百分比，颜色由 100% 的绿色经过黄色平滑变为 0% 的红色。
用量与本机任务每 5 秒刷新。未知数据显示 —，失败显示旧数据时间，不伪造零用量。
支持菜单栏悬停/点击、固定桌面并记住位置、系统提示音、天气与透明度设置。
主面板采用对齐的双环余量仪表，保留时间日期、任务状态、城市温度和重置信息。
ChatGPT 标志旁的菜单可打开或退出 Codex；各页面共享背景。
工具状态与数据说明见设置 → 关于。只监测 Codex，无其他工具识别、计费或切换。

安装包不含制作者账号、凭据、用量、聊天、偏好、日志或定位缓存。
首次运行读取安装者当前系统用户的数据，不发起模型任务或兑换重置。
天气需由安装者独立授权定位，声音、透明度、固定位置在本机保存。
本应用为临时签名，尚未 Apple 公证；Apple 芯片版交叉编译，未在实体机器验证。
双击“取消自动关联.command”关闭启动联动，应用和本机设置仍保留。
TXT
chmod +x "$PACKAGE/安装.command" "$PACKAGE/取消自动关联.command"
python3 - "$PACKAGE" <<'PY'
import sys
from pathlib import Path
root=Path(sys.argv[1]); allowed={'安装.command','取消自动关联.command','安装说明.txt',
'Runtime/CodexMiniLifecycle','axbro.app/Contents/Info.plist',
'axbro.app/Contents/MacOS/axbro','axbro.app/Contents/Resources/monitor.py',
'axbro.app/Contents/Resources/WeatherReference.png','axbro.app/Contents/Resources/AppIcon.icns',
'axbro.app/Contents/_CodeSignature/CodeResources',
'axbro.app/Contents/Resources/ChatGPTMark.png','axbro.app/Contents/Resources/ChatGPTMark@2x.png'}
files={str(p.relative_to(root)) for p in root.rglob('*') if p.is_file()}
assert files==allowed, f'Unexpected package files: {files ^ allowed}'
for path in root.rglob('*'):
    if path.is_file() and path.suffix in {'.py','.plist','.command','.txt'}:
        data=path.read_bytes()
        assert b'/Users/dean/' not in data
        assert b'sk-' not in data and b'access_token' not in data
print('Package whitelist and personal-path checks passed (12 files).')
PY
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$PACKAGE" axbro-安装包.zip
echo "已生成：$PWD/axbro-安装包.zip"
