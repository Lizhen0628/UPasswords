ALTER TABLE attachments
  ADD COLUMN IF NOT EXISTS content_version CHAR(36) NULL AFTER attach_uuid;

ALTER TABLE attachments
  MODIFY COLUMN object_key VARCHAR(255) NOT NULL;

CREATE TABLE IF NOT EXISTS attachment_versions (
  vault_id       VARCHAR(32) NOT NULL,
  attach_uuid    CHAR(36) NOT NULL,
  content_version CHAR(36) NOT NULL,
  card_uuid      CHAR(36) NOT NULL,
  object_key     VARCHAR(255) NOT NULL,
  dek_wrapped    VARBINARY(256) NOT NULL,
  sha256         CHAR(64) NOT NULL,
  bytes          BIGINT UNSIGNED NOT NULL,
  created_ms     BIGINT NOT NULL,
  retired_ms     BIGINT NULL,
  unreferenced_ms BIGINT NULL,
  PRIMARY KEY (vault_id, attach_uuid, content_version),
  KEY idx_attachment_versions_card (vault_id, card_uuid, retired_ms),
  CONSTRAINT fk_attachment_versions_vault FOREIGN KEY (vault_id)
    REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

ALTER TABLE attachment_versions
  MODIFY COLUMN object_key VARCHAR(255) NOT NULL;

CREATE TABLE IF NOT EXISTS rekey_attachment_staging (
  rekey_id        VARCHAR(32) NOT NULL,
  vault_id        VARCHAR(32) NOT NULL,
  attach_uuid     CHAR(36) NOT NULL,
  content_version CHAR(36) NOT NULL,
  dek_wrapped     VARBINARY(256) NOT NULL,
  PRIMARY KEY (rekey_id, attach_uuid, content_version),
  KEY idx_rekey_attachment_staging_vault (vault_id, rekey_id),
  CONSTRAINT fk_rekey_attachment_staging_rekey FOREIGN KEY (rekey_id)
    REFERENCES rekeys (rekey_id) ON DELETE CASCADE,
  CONSTRAINT fk_rekey_attachment_staging_version FOREIGN KEY (vault_id, attach_uuid, content_version)
    REFERENCES attachment_versions (vault_id, attach_uuid, content_version) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

INSERT INTO attachment_versions(
  vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms
)
SELECT vault_id,attach_uuid,'00000000-0000-0000-0000-000000000000',card_uuid,
       object_key,dek_wrapped,sha256,bytes,created_ms
FROM attachments
ON DUPLICATE KEY UPDATE attach_uuid=VALUES(attach_uuid);

CREATE TABLE IF NOT EXISTS attachment_version_conflicts (
  vault_id        VARCHAR(32) NOT NULL,
  conflict_id     VARCHAR(32) NOT NULL,
  attach_uuid     CHAR(36) NOT NULL,
  content_version CHAR(36) NOT NULL,
  release_after_ms BIGINT NULL,
  PRIMARY KEY (vault_id, conflict_id, attach_uuid, content_version),
  KEY idx_attachment_conflict_release (vault_id, release_after_ms),
  CONSTRAINT fk_attachment_conflict FOREIGN KEY (conflict_id)
    REFERENCES item_conflicts (conflict_id) ON DELETE CASCADE,
  CONSTRAINT fk_attachment_conflict_version FOREIGN KEY (vault_id,attach_uuid,content_version)
    REFERENCES attachment_versions (vault_id,attach_uuid,content_version) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS attachment_tombstones (
  vault_id     VARCHAR(32) NOT NULL,
  attach_uuid  CHAR(36) NOT NULL,
  card_uuid    CHAR(36) NOT NULL,
  deleted_ms   BIGINT NOT NULL,
  PRIMARY KEY (vault_id, attach_uuid),
  KEY idx_attachment_tombstones_card (vault_id, card_uuid),
  CONSTRAINT fk_attachment_tombstones_vault FOREIGN KEY (vault_id)
    REFERENCES vaults (vault_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

UPDATE vaults v
SET attach_bytes=(SELECT COALESCE(SUM(bytes),0) FROM attachment_versions a WHERE a.vault_id=v.vault_id);
