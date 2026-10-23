# Cloud — UPasswords 云同步协调服务(api.upasswords.com)

架构与安全模型详见 [DESIGN.md](DESIGN.md)(**v7 已实施**:MariaDB 行级密文
条目 + R2 附件 + Hyperdrive;测试验收见 [TESTING.md](TESTING.md))。
服务端对库内容零知识:密码项以**单条目 AES-GCM 密文行**存于自管 MariaDB,
条目标识为 UUID,编辑只改行;附件密文 blob 在 R2;`/v2/breach/range` 代理
HIBP(k-匿名,密码永不出设备)。

## 组成

云 API 的当前生产运行目标是 Go + chi，部署于香港 `service-admin` 主机，并由
Docker Compose 管理；MariaDB 继续使用内网数据库服务器，附件与站点图标继续存放在 R2。
部署文件、环境模板及隔离集成测试位于 [`Cloud/api`](api/README.md)。Cloudflare
代理负责 `api.upasswords.com` 的 TLS 与源站证书校验，Nginx 转发到仅绑定回环地址的 API。
邮件暂由现有 163 SMTP 账号发送，注册和验证邮件分别设置回复地址。

| 组件 | 说明 |
|---|---|
| Go + chi API(当前生产运行时) | `api/{cmd,internal}`；保留 `/v2` 契约，由香港服务器上的 Docker Compose 管理 |
| Cloudflare Worker(TypeScript,兼容/回退运行时) | `worker/src/{index,auth,vaults,items,rekey,attachments,sites,breach,stats,maintenance,smtp,db,util}.ts` |
| MariaDB 11.4(自管 `kvm-database`,库 `upasswords`) | users / email_codes / sessions / vaults / vault_items / item_changes / attachments / rekeys / rekey_staging / audit_log + websites / website_domains(`worker/sql/0001_init.sql`) |
| R2(桶 `upasswords`) | 附件密文 `vaults/<id>/attachments/…` + 网站目录图标 `sites/icons/<sha256>` |
| MariaDB 连接 | Go API 经私网 TLS 连接；Worker 回退时使用现有 Hyperdrive 配置 |
| SMTP(smtp.163.com:465) | Go API 经 TLS 发送验证码邮件；回复地址按邮件用途设置 |
| 每日维护 04:00 UTC | Go Compose scheduler 执行注销到期清除、变更日志保留+地板推进、rekey 过期清理、附件孤儿清扫、计数对账、审计保留；Worker 回退时恢复对应 Cron |

## 零知识要点

- 库内容(主密码、VEK、条目明文)绝不出设备;服务端只见行级密文与
  哈希/元数据;条目体 AAD 绑定 uuid(行搬运防护);
- `APP_KEK`(Worker secret)应用层加密:信封与邮箱 AES-GCM 入库、邮箱以
  键控 HMAC 作查询键——拖库既不能爆破主密码、也拿不到用户名单;
- 会话令牌 256bit 随机、只存 SHA-256;验证码键控哈希、单活跃、≤5 次、限速;
- 泄漏检测经自有端点代理 HIBP(HIBP 不见用户 IP);站点查询域名/泄漏
  查询前缀一律不进日志。

## 接口(/v2,整体取代 v1)

```
GET  /v2/                                      能力协商 {version:2, rowSync:true,…}
POST /v2/auth/code        {email, purpose?}    发验证码(login|sensitive) 202 恒定
POST /v2/auth/verify      {email, code, deviceName?, platform?} → {token, expiresAt, userId}
GET  /v2/auth/sessions    Bearer               设备列表(含 platform;发起方会话标 current)
DELETE /v2/auth/sessions/{id}                  撤销设备
PATCH /v2/auth/session    {deviceName}         会话自命名
DELETE /v2/auth/session   Bearer               自撤销(登出/重登收尾)
DELETE /v2/account        {code=sensitive 码}  注销(级联清行+R2+撤会话)
POST /v2/vaults           {name, envelope}     登记(创建即携带初始信封) → {vaultId}
GET  /v2/vaults                                库列表(元数据)
GET  /v2/vaults/{id}                           单库(含信封 b64)
GET  /v2/vaults/{id}/seq                       {headSeq, passwordVersion}(便宜轮询)
PATCH /v2/vaults/{id}     {name}               改名
POST /v2/vaults/{id}/transfer {email,code,currentCode,deviceName?}  换绑邮箱
DELETE /v2/vaults/{id}    {code}               解绑(清行+R2 前缀)
POST /v2/vaults/{id}/items    {items:[{uuid,kind,op,baseRevision,bodyB64?,sha256?,modifiedMs}]}
                                               批量 CAS 上行 → 逐条 ok|conflict|not_found
GET  /v2/vaults/{id}/changes?since=&limit=     游标增量下行(410 cursor_expired)
GET  /v2/vaults/{id}/items?cursorMs=&cursorUuid=&limit=   全量重建 keyset 分页
PUT  /v2/vaults/{id}/attachments/{uuid}?upload=UID        附件密文暂存(octet-stream)
POST /v2/vaults/{id}/attachments/{uuid}/commit {uploadId,sha256,cardUuid,dekWrapped}
GET  /v2/vaults/{id}/attachments/{uuid}                    拉取密文流
DELETE /v2/vaults/{id}/attachments/{uuid}                  删行+删 blob
POST /v2/vaults/{id}/rekey/begin → /rekey/{rekeyId}/chunk → /commit(DELETE 放弃)
                                               改密 VEK 轮换(全部行 revision+1)
GET  /v2/sites/lookup?domain=                   网站目录(名称+图标 b64)
GET  /v2/sites/icon/{sha256}                    图标字节流(ETag 强缓存)
POST /v2/admin/sites        X-Admin-Token       目录批量 upsert
GET  /v2/breach/range/{5位hex前缀}              泄漏检测代理(与 HIBP 同形)
GET  /v2/admin/stats        X-Admin-Token       只读统计
```

## 本地测试(直连真实 MariaDB)

```bash
cd Cloud/worker
npm install && npm install-scripts approve esbuild && npm install-scripts approve workerd
npm run typecheck
# 本地:开 ssh 隧道后直连服务器测试库(口令在 ~/.upasswords-cloud-secrets.txt)
ssh -f -N -L 16033:127.0.0.1:6033 database-server
UPW_TEST_DB_URL="mysql://upw_app:<口令>@127.0.0.1:16033/upasswords_test" \
UPW_TEST_DB_SSL=1 npm test     # 19 用例:登录/限速/CAS/游标/rekey/附件/隔离/目录/代理
# CI:ubuntu + mariadb:11.4 service 容器(UPW_TEST_DB_ADMIN_URL 现场建库建号,
# 见 .github/workflows/ci.yml 与 test/apply-schema.ts)
```

## Go API 部署

生产入口与服务器操作说明见 [`api/README.md`](api/README.md)。Cloudflare Worker
代码和绑定保留用于回退；其 Cron 已在 Go 服务开始维护后停用。Worker 部署不再是
当前 API 发布流程。

## Worker 回退部署

```bash
cd Cloud/worker
# 1) Hyperdrive 已创建(id 已回填 wrangler.toml),origin 已内网化:
#    host=dbt.upasswords.com(Cloudflare Tunnel `upasswords-db` 经
#    ipv6bridge 网桥直达容器 3306,Access Service Token 保护——凭据在
#    ~/.upasswords-cloud-secrets.txt 的 ACCESS_CLIENT_* 条目)。
#    **缓存必须保持关闭**(已设 caching.disabled=true;重新创建配置时
#    须重申,否则 /seq 等同文本 SELECT 返回旧快照,见 DESIGN §8.4)。
#    本地测试:ssh -L 16034:127.0.0.1:6033 database-server(mariadb compose
#    的 127.0.0.1:6033 回环发布,docker-proxy 自动跟随容器,IP 漂移免疫)
npx wrangler hyperdrive create upasswords-db \
  --connection-string="mysql://upw_app:<口令>@24.233.2.194:6033/upasswords"
#    → 把返回的 id 回填 wrangler.toml 的 [[hyperdrive.configs]]
# 2) Secrets(沿用既有值,见 ~/.upasswords-cloud-secrets.txt)
npx wrangler secret put APP_KEK && npx wrangler secret put ADMIN_TOKEN \
  && npx wrangler secret put SMTP_USER && npx wrangler secret put SMTP_PASSWORD
# 3) schema 已在服务器应用过(upasswords / upasswords_test 两库);
#    变更 DDL 时:cat sql/0001_init.sql | ssh database-server '(经 docker exec 导入)'
# 4) 部署
npx wrangler deploy     # 自定义域 api.upasswords.com;旧 v6 端点随本次部署下线
```

D1 `upasswords-sync` 与 v6 库体端点(body/envelope/hashes)已随 v7 退役;
R2 旧 `vaults/<id>` 单对象由每日 cron 清扫。
