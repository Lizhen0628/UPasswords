ALTER TABLE item_conflict_candidates
  ADD COLUMN IF NOT EXISTS candidate_fingerprint CHAR(64) NULL AFTER body_sha256;
