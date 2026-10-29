ALTER TABLE attachment_versions
  ADD COLUMN IF NOT EXISTS purge_started_ms BIGINT NULL AFTER unreferenced_ms;
