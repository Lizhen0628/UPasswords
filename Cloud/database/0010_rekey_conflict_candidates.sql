-- Add a fixed candidate inventory and encrypted candidate staging to atomic key rotation.
CREATE TABLE IF NOT EXISTS rekey_conflict_manifests (
  rekey_id         VARCHAR(32) NOT NULL,
  vault_id         VARCHAR(32) NOT NULL,
  candidate_total  INT UNSIGNED NOT NULL,
  candidate_staged INT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (rekey_id),
  KEY idx_rekey_conflict_manifest_vault (vault_id, rekey_id),
  CONSTRAINT fk_rekey_conflict_manifest_rekey FOREIGN KEY (rekey_id)
    REFERENCES rekeys (rekey_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
CREATE TABLE IF NOT EXISTS rekey_conflict_staging (
  rekey_id              VARCHAR(32) NOT NULL,
  vault_id              VARCHAR(32) NOT NULL,
  conflict_id           VARCHAR(32) NOT NULL,
  old_candidate_id      VARCHAR(32) NOT NULL,
  new_candidate_id      VARCHAR(32) NOT NULL,
  candidate_fingerprint CHAR(64) NOT NULL,
  body                  MEDIUMBLOB NULL,
  body_sha256           CHAR(64) NULL,
  PRIMARY KEY (rekey_id, conflict_id, old_candidate_id),
  KEY idx_rekey_conflict_new_id (rekey_id, conflict_id, new_candidate_id),
  KEY idx_rekey_conflict_vault (vault_id, rekey_id),
  CONSTRAINT fk_rekey_conflict_stage_rekey FOREIGN KEY (rekey_id)
    REFERENCES rekeys (rekey_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
