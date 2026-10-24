// 附件密文的暂存、校验、发布与下载；R2 与 SQL 不共享事务。
package api

import (
	"database/sql"
	"errors"
	"io"
	"net/http"
	"strings"
)

func lower(v string) string          { return strings.ToLower(v) }
func attachPrefix(vid string) string { return "vaults/" + vid + "/attachments/" }

// attachmentPut stores a bounded encrypted upload under a temporary object key; it does not publish a database reference.
func (s *Server) attachmentPut(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	if _, e := uuid(param(r, "attachmentID")); e != nil {
		return fail(404, "not_found")
	}
	upload := r.URL.Query().Get("upload")
	if !idPattern.MatchString(upload) {
		return fail(400, "invalid_upload_id")
	}
	if r.ContentLength <= 0 {
		return fail(411, "length_required")
	}
	if r.ContentLength > s.Config.limit("ATTACHMENT_MAX_BYTES") {
		return fail(413, "quota_exceeded")
	}
	prefix := attachPrefix(vid) + "staging/"
	objects, _, e := s.Objects.List(r.Context(), prefix, "")
	if e != nil {
		return e
	}
	count := int64(0)
	for _, o := range objects {
		if now()-o.Modified.UnixMilli() > 3600000 {
			if e = s.Objects.Delete(r.Context(), o.Key); e != nil {
				return e
			}
		} else {
			count++
		}
	}
	if count >= s.Config.limit("ATTACH_STAGING_MAX_OBJECTS") {
		return fail(413, "quota_exceeded")
	}
	raw, e := io.ReadAll(http.MaxBytesReader(w, r.Body, s.Config.limit("ATTACHMENT_MAX_BYTES")))
	if e != nil {
		return fail(413, "too_large")
	}
	if int64(len(raw)) != r.ContentLength {
		return fail(400, "incomplete_upload")
	}
	if e = s.Objects.Put(r.Context(), prefix+upload, raw, "application/octet-stream"); e != nil {
		return e
	}
	s.audit(r.Context(), "attach_staged", identity(r).UserID, vid, map[string]int{"bytes": len(raw)})
	writeJSON(w, 200, map[string]any{"ok": true, "received": len(raw)})
	return nil
}

// attachmentCommit verifies staged size and digest, writes an immutable object, then transactionally publishes its reference.
// Object storage is outside the SQL transaction; interrupted or replaced objects are reclaimed by maintenance.
func (s *Server) attachmentCommit(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	vid := param(r, "vaultID")
	id, e := uuid(param(r, "attachmentID"))
	if e != nil {
		return fail(404, "not_found")
	}
	if _, e = loadVault(r.Context(), s.DB, a.UserID, vid, false); e != nil {
		return e
	}
	var b struct{ UploadID, SHA256, CardUUID, DekWrapped string }
	if e = body(w, r, smallJSON, &b); e != nil {
		return e
	}
	card, e := uuid(b.CardUUID)
	if e != nil {
		return e
	}
	dek, e := decode64(b.DekWrapped)
	if e != nil || len(dek) < 28 || len(dek) > 256 || !idPattern.MatchString(b.UploadID) || !hashPattern.MatchString(b.SHA256) {
		return fail(400, "bad_request")
	}
	key := attachPrefix(vid) + "staging/" + b.UploadID
	stream, obj, e := s.Objects.Get(r.Context(), key)
	if e != nil {
		var a *apiError
		if errors.As(e, &a) && a.Status == 404 {
			return fail(400, "incomplete_upload")
		}
		return e
	}
	defer stream.Close()
	max := s.Config.limit("ATTACHMENT_MAX_BYTES")
	if obj.Size < 1 || obj.Size > max {
		return fail(413, "quota_exceeded")
	}
	raw, e := io.ReadAll(io.LimitReader(stream, max+1))
	if e != nil {
		return e
	}
	if int64(len(raw)) != obj.Size || digest(raw) != lower(b.SHA256) {
		return fail(400, "hash_mismatch")
	}
	// Immutable content-addressed suffix prevents a replacement from overwriting a blob referenced by an older DB row.
	final := attachPrefix(vid) + id + "/" + digest(raw)
	if e = s.Objects.Put(r.Context(), final, raw, "application/octet-stream"); e != nil {
		return e
	}
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		if e = s.noRekey(r, t, vid); e != nil {
			return e
		}
		var prev int64
		e = t.QueryRowContext(r.Context(), "SELECT bytes FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&prev)
		if e != nil && !errors.Is(e, sql.ErrNoRows) {
			return e
		}
		total := v.AttachBytes - prev + int64(len(raw))
		if total > s.Config.limit("ATTACH_QUOTA_PER_VAULT") {
			return fail(413, "quota_exceeded")
		}
		if _, e = t.ExecContext(r.Context(), "INSERT INTO attachments(vault_id,attach_uuid,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms) VALUES(?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE card_uuid=VALUES(card_uuid),object_key=VALUES(object_key),dek_wrapped=VALUES(dek_wrapped),sha256=VALUES(sha256),bytes=VALUES(bytes)", vid, id, card, final, dek, digest(raw), len(raw), now()); e != nil {
			return e
		}
		_, e = t.ExecContext(r.Context(), "UPDATE vaults SET attach_bytes=?,updated_ms=? WHERE vault_id=?", total, now(), vid)
		return e
	})
	if e != nil {
		return e
	}
	if e = s.Objects.Delete(r.Context(), key); e != nil {
		s.Log.Warn("staging cleanup deferred")
	}
	s.audit(r.Context(), "attach_commit", a.UserID, vid, map[string]int{"bytes": len(raw)})
	writeJSON(w, 200, map[string]any{"ok": true, "bytes": len(raw)})
	return nil
}

// attachmentGet authorizes the vault owner and streams ciphertext from the referenced immutable object.
func (s *Server) attachmentGet(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	id, e := uuid(param(r, "attachmentID"))
	if e != nil {
		return fail(404, "not_found")
	}
	var key, sha string
	var size int64
	e = s.DB.QueryRowContext(r.Context(), "SELECT object_key,sha256,bytes FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&key, &sha, &size)
	if errors.Is(e, sql.ErrNoRows) {
		return fail(404, "not_found")
	}
	if e != nil {
		return e
	}
	stream, obj, e := s.Objects.Get(r.Context(), key)
	if e != nil {
		return e
	}
	defer stream.Close()
	if obj.Size != size {
		return errors.New("attachment size mismatch")
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Sha256", sha)
	w.Header().Set("X-Bytes", intString(size))
	w.Header().Set("Content-Length", intString(size))
	_, e = io.Copy(w, stream)
	return e
}

// attachmentDelete removes the database reference and adjusts quota before deleting the encrypted object.
func (s *Server) attachmentDelete(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	vid := param(r, "vaultID")
	id, e := uuid(param(r, "attachmentID"))
	if e != nil {
		return fail(404, "not_found")
	}
	var key string
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := loadVault(r.Context(), t, a.UserID, vid, true); e != nil {
			return e
		}
		if e := s.noRekey(r, t, vid); e != nil {
			return e
		}
		var size int64
		e := t.QueryRowContext(r.Context(), "SELECT object_key,bytes FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&key, &size)
		if errors.Is(e, sql.ErrNoRows) {
			return fail(404, "not_found")
		}
		if e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "DELETE FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id); e != nil {
			return e
		}
		_, e = t.ExecContext(r.Context(), "UPDATE vaults SET attach_bytes=attach_bytes-?,updated_ms=? WHERE vault_id=?", size, now(), vid)
		return e
	})
	if e != nil {
		return e
	}
	if e = s.Objects.Delete(r.Context(), key); e != nil {
		s.Log.Warn("attachment blob deletion deferred")
	}
	s.audit(r.Context(), "attach_delete", a.UserID, vid, nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}
