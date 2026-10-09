#!/bin/bash
# 部署 upasswords.com 信封同步 Worker。
# 凭证二选一(环境变量,绝不写入仓库):
#   CLOUDFLARE_API_TOKEN=<受限 Token>(推荐:Workers Scripts:Edit + Workers KV Storage:Edit)
#   或 CLOUDFLARE_EMAIL + CLOUDFLARE_API_KEY(Global Key)
set -euo pipefail
cd "$(dirname "$0")/../Cloud/worker"

if ! command -v npx >/dev/null; then echo "need node/npx"; exit 1; fi

# 首次部署:创建 KV 命名空间并回填 wrangler.toml
if grep -q "REPLACE_AFTER_KV_CREATE" wrangler.toml; then
  KV_ID=$(npx wrangler kv namespace create VAULTS 2>/dev/null | grep -o '"id": "[^"]*"' | head -1 | cut -d'"' -f4)
  [ -z "$KV_ID" ] && KV_ID=$(npx wrangler kv namespace create VAULTS | grep -oE 'id = "[^"]*"' | head -1 | cut -d'"' -f2)
  [ -z "$KV_ID" ] && { echo "KV namespace create failed"; exit 1; }
  sed -i '' "s/REPLACE_AFTER_KV_CREATE/$KV_ID/" wrangler.toml
  echo "KV namespace: $KV_ID"
fi

npx wrangler deploy
echo "deployed: https://api.upasswords.com"
