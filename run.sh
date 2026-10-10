#!/bin/bash
# 构建并启动「耳录」
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# key 只认 ~/.config/ear_shot/config.json 里那一个来源（刻意不从环境变量兜底，
# 免得把别的工具的 key 悄悄借走）；没配的话界面会直接提示，不静默

pkill -f EarShot 2>/dev/null || true
sleep 0.6
"$ROOT/build.sh"
open "$ROOT/dist/EarShot.app"
echo "已启动。点屏幕右边缘靠上的把手展开；点面板里的「开始监听」开始记录待办"
