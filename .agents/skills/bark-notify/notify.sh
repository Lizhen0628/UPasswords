#!/bin/bash
# Bark 推送:notify.sh "标题" "正文" [分组]
# 凭证优先取环境变量,缺失时从 ~/.zshrc 提取(非交互 shell 不加载 .zshrc)。
set -euo pipefail

ZSHRC="$HOME/.zshrc"
from_zshrc() { grep -m1 -E "^export $1=" "$ZSHRC" 2>/dev/null | sed -E 's/^[^"]*"([^"]*)".*/\1/'; }

BARK_KEY=${BARK_KEY:-$(from_zshrc BARK_KEY)}
BARK_BASE_URL=${BARK_BASE_URL:-$(from_zshrc BARK_BASE_URL)}
MACHINE_NAME=${MACHINE_NAME:-$(from_zshrc MACHINE_NAME)}
BARK_BASE_URL=${BARK_BASE_URL:-https://api.day.app}
MACHINE_NAME=${MACHINE_NAME:-$(hostname -s)}

if [ -z "$BARK_KEY" ]; then
  echo "notify.sh: BARK_KEY not found (env or ~/.zshrc)" >&2
  exit 1
fi

TITLE=${1:?"usage: notify.sh <title> [body] [group]"}
BODY=${2:-}
GROUP=${3:-UPasswords}

# JSON 组装交给 python3,避免特殊字符破坏 payload
PAYLOAD=$(TITLE="[$MACHINE_NAME] $TITLE" BODY="$BODY" GROUP="$GROUP" KEY="$BARK_KEY" python3 -c '
import json, os
print(json.dumps({
    "device_key": os.environ["KEY"],
    "title": os.environ["TITLE"],
    "body": os.environ["BODY"],
    "group": os.environ["GROUP"],
}))')

curl -s -o /dev/null -w "%{http_code}\n" -X POST "$BARK_BASE_URL/push" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD"
