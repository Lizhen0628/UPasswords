# Cloud — upasswords.com 信封同步服务

零知识信封同步通道(Cloudflare Workers + KV),配合 v2 信封加密容器:

- 本体(`<名>.upw`)继续走 iCloud / WebDAV(大文件,弱一致可接受);
- 信封(`<名>.upwkey`,~100B)改密后经本通道毫秒级传播到所有设备。

## 零知识设计

| 概念 | 派生/存储 |
|---|---|
| vaultID | `hex(HKDF-SHA256(库密钥, salt="upw-cloud-v1", info="vault-id"))` |
| accessToken | 同上,`info="access-token"`;服务端只存其 SHA-256 |
| 信封 | 主密码 PBKDF2 包裹库密钥的密文,服务端无法解密 |

持有库密钥(=解锁)的设备自动算出同一身份与令牌:新设备零配置加入,
无需账号、无需登录。主密码与库密钥绝不出设备。

## 接口

```
GET  /v1/vaults/{vaultID}/envelope           → { rev, changedAt, envelope(b64) }
PUT  /v1/vaults/{vaultID}/envelope           Authorization: Bearer <accessToken>
                                             { envelope(b64), changedAt(epoch 秒) }
```

- 首次 PUT 认领库(登记 tokenHash);之后令牌不符 → 403。
- `changedAt` 决胜:过期写返回 `stale:true` 不覆盖。

## 部署

```bash
export CLOUDFLARE_API_TOKEN=<受限 Token>
./scripts/deploy-cloud.sh
```

首次运行自动创建 KV 命名空间并回填 `worker/wrangler.toml`,
随后 deploy 并绑定自定义域 `api.upasswords.com`(域名需托管在 Cloudflare)。

客户端实现:`SwiftPackages/Networking/.../CloudEnvelopeService.swift`;
开关:双端同步设置「同步加速(upasswords.com)」,默认开。
