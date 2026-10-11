-- 库体密文存储元数据(standalone Safari 扩展数据通路):
-- 密文本体存 R2 对象存储(单对象上限 5TB,任意大小免分块),D1 只记元数据。
-- 内容是 VEK 加密密文,服务端零知识;总大小受 VAULT_BODY_MAX_BYTES 配额约束。
ALTER TABLE vaults ADD COLUMN body_sha256 TEXT;     -- 整库体 SHA-256(客户端上报)
ALTER TABLE vaults ADD COLUMN body_bytes INTEGER;   -- 库体字节数
ALTER TABLE vaults ADD COLUMN body_updated_at REAL;
