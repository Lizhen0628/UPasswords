-- UPasswords 云同步协调层初始 schema(见 Cloud/DESIGN.md §6)
-- 隐私红线:本库不含任何明文敏感数据——邮箱与信封均为 APP_KEK 加密/键控哈希形态,
-- 会话令牌只存 SHA-256(256bit 随机数,拖库不可逆)。

CREATE TABLE users (
  id              TEXT PRIMARY KEY,        -- 32 hex 随机
  email_hmac      TEXT NOT NULL UNIQUE,    -- HMAC(APP_KEK, 规范化邮箱):登录查询键
  email_enc       TEXT,                    -- AES-GCM(APP_KEK, 邮箱):发码时解密;注销即清空
  state           TEXT NOT NULL DEFAULT 'active',  -- active | deregistered
  plan            TEXT NOT NULL DEFAULT 'normal',  -- normal | subscription | permanent
  totp_secret     TEXT,                    -- 预留(后期经 APP_KEK 加密)
  created_at      REAL NOT NULL,
  last_login_at   REAL,
  deregistered_at REAL
);

CREATE TABLE email_codes (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  email_hmac TEXT NOT NULL,
  code_hash  TEXT NOT NULL,                -- HMAC(APP_KEK, email_hmac:code:purpose)
  purpose    TEXT NOT NULL DEFAULT 'login', -- login | sensitive
  expires_at REAL NOT NULL,
  attempts   INTEGER NOT NULL DEFAULT 0,
  used_at    REAL,
  created_at REAL NOT NULL,
  ip         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX idx_codes_lookup ON email_codes(email_hmac, purpose, created_at);
CREATE INDEX idx_codes_ip ON email_codes(ip, created_at);

CREATE TABLE sessions (
  id           TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL,
  token_hash   TEXT NOT NULL,              -- SHA-256(令牌);令牌只在签发响应出现一次
  device_name  TEXT NOT NULL DEFAULT '',
  created_at   REAL NOT NULL,
  last_seen_at REAL NOT NULL,
  expires_at   REAL NOT NULL,              -- 90 天滑动
  revoked_at   REAL
);
CREATE INDEX idx_sessions_user ON sessions(user_id);

CREATE TABLE vaults (
  vault_id            TEXT PRIMARY KEY,    -- 32 hex 随机
  user_id             TEXT NOT NULL,
  name                TEXT NOT NULL,       -- 明文(已决策);同时是网盘文件名
  password_version    INTEGER NOT NULL DEFAULT 1,
  password_changed_at REAL NOT NULL,
  envelope_enc        TEXT,                -- AES-GCM(APP_KEK, 信封) v1. 前缀
  envelope_changed_at REAL,
  cipher_sha256       TEXT,                -- 网盘 .upw 密文哈希(客户端上报)
  xml_sha256          TEXT,                -- 明文 XML 哈希(同步短路判据)
  created_at          REAL NOT NULL,
  updated_at          REAL NOT NULL
);
CREATE UNIQUE INDEX idx_vaults_user_name ON vaults(user_id, name);

CREATE TABLE audit_log (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id  TEXT,
  vault_id TEXT,
  action   TEXT NOT NULL,
  detail   TEXT,                           -- JSON:rev/尺寸/结果,无敏感数据
  ts       REAL NOT NULL
);
CREATE INDEX idx_audit_ts ON audit_log(ts);
