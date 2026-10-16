# Cloud — UPasswords 云同步协调服务（api.upasswords.com）

架构与安全模型详见 [DESIGN.md](DESIGN.md)（v6）。服务端对库内容零知识：
账户（邮箱验证码）、库注册表（版本元数据/哈希/信封）与 R2 加密库体副本
（库密钥密文，原网盘通道已移除——客户端仅存 relay 单通道，见仓库根
FEATURES.md §6 与 `cloud-drive-legacy` 分支的历史实现）。

## 组成

| 组件 | 说明 |
|---|---|
| Cloudflare Worker（TypeScript，零依赖） | `worker/src/{index,auth,vaults,stats,smtp,db,util}.ts` |
| D1（upasswords-sync） | users / email_codes / sessions / vaults / audit_log |
| R2（桶 VAULTS） | 加密库体副本：`vaults/<id>` 生效件 + `vaults/staging/…` 暂存（commit 原子换入） |
| SMTP（smtp.163.com:465） | 验证码邮件（`cloudflare:sockets` 直连，无第三方依赖） |
| 每日 cron 04:00 UTC | 注销账户 30 天保留期到期的物理清除 |

## 零知识要点

- 库内容（主密码、库密钥、明文）绝不出设备；服务端只见密文与哈希；
- `APP_KEK`（Worker secret）应用层加密：信封与邮箱 AES-GCM 入库、
  邮箱以键控 HMAC 作查询键——D1 被拖库既不能爆破主密码、也拿不到用户名单；
- 会话令牌 256bit 随机、只存 SHA-256；验证码键控哈希、单活跃、≤5 次、限速；
- 管理面只读统计（注销/普通/订阅/永久计数），无任何写操作与解密能力。

## 接口（/v1）

```
GET  /v1/                                     能力协商
POST /v1/auth/code        {email, purpose?}   发验证码(login|sensitive) 202 恒定
POST /v1/auth/verify      {email, code, deviceName?} → {token, expiresAt, userId}
GET  /v1/auth/sessions    Bearer              设备列表
DELETE /v1/auth/sessions/{id}                 撤销设备
PATCH /v1/auth/session     {deviceName}        会话自命名(设备型号展示)
DELETE /v1/account        {code=sensitive 码}  注销(立即清敏感列+撤全部会话)
POST /v1/vaults           {name}              登记 → {vaultId}
GET  /v1/vaults                               库列表(元数据)
GET  /v1/vaults/{id}                          单库(含信封 b64)
PUT  /v1/vaults/{id}/envelope  {envelope, changedAt}  改密信封(changedAt 决胜+±300s 钳制)
PUT  /v1/vaults/{id}/hashes    {cipherSha256, xmlSha256}  库体提交成功后上报
PUT  /v1/vaults/{id}/body?upload=UID           库体暂存(octet-stream,≤50MB,暂存≤4)
POST /v1/vaults/{id}/body/commit {uploadId, sha256}  校验后原子换入生效副本
GET  /v1/vaults/{id}/body                      拉取生效库体(无副本 404)
PATCH /v1/vaults/{id}     {name}              改名
POST /v1/vaults/{id}/transfer {email,code,currentCode}  换绑邮箱(注册表迁移,双敏感码门槛)
DELETE /v1/vaults/{id}    {code=sensitive 码}  解绑注册(清 R2 副本;本地库与备份不动)
GET  /v1/admin/stats      X-Admin-Token       只读统计
```

## 本地测试

```bash
cd Cloud/worker
npm install && npm install-scripts approve esbuild && npm install-scripts approve workerd
npm run typecheck
npm test        # vitest + @cloudflare/vitest-plugin(miniflare 本地 D1,SMTP mock)
```

## 部署

凭据与环境（**绝不入库**）：

- `CLOUDFLARE_API_TOKEN`：最小权限 Token（Workers Editor / D1 Write / KV Write /
  Account Settings Read）；
- Secrets（`npx wrangler secret put <NAME>`）：`APP_KEK`（64 hex，丢失则 API 信封
  不可解、客户端回退本地信封）、`ADMIN_TOKEN`、`SMTP_USER`、`SMTP_PASSWORD`；
- 本机凭据备份：`~/.upasswords-cloud-secrets.txt`（chmod 600，勿提交）。

```bash
cd Cloud/worker
npx wrangler d1 migrations apply upasswords-sync --remote
./scripts/deploy-cloud.sh   # 或 npx wrangler deploy(自定义域 api.upasswords.com)
```

D1：`database_id` 已回填在 `wrangler.toml`；新迁移放入 `worker/migrations/` 后
执行 `migrations apply`。

## 已知事实（2026-10 部署验证）

- SMTP 全链路验证：验证码邮件经 163 SMTP 真实送达，中英双语模板；
- 信封 changedAt 决胜/偏斜钳制、敏感码删库、限速、跨用户隔离均有
  vitest 覆盖（34 用例）并经线上 curl 验证；
- 发到 `*@upasswords.com` 地址的邮件经 Cloudflare Email Routing 转发回 163 收件箱。
