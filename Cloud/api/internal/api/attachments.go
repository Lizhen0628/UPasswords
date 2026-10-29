// 附件密文的暂存、版本发布、保留和下载；R2 与 SQL 不共享事务。
package api

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
)

const legacyAttachmentVersion = "00000000-0000-0000-0000-000000000000"

type attachmentReference struct {
	AttachmentID   string `json:"attachmentId"`
	ContentVersion string `json:"contentVersion"`
	RestoreDeleted bool   `json:"restoreDeleted,omitempty"`
}

func lower(v string) string          { return strings.ToLower(v) }
func attachPrefix(vid string) string { return "vaults/" + vid + "/attachments/" }

// attachmentPut stores a bounded encrypted upload under a temporary object key.
func (s *Server) attachmentPut(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	if _, e := uuid(param(r, "attachmentID")); e != nil {
		return fail(404, "not_found")
	}
	version, e := uuid(r.URL.Query().Get("version"))
	if e != nil || version == legacyAttachmentVersion {
		return fail(400, "invalid_attachment_version")
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

// attachmentCommit publishes one immutable content version using a current-version compare-and-swap.
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
	var b struct {
		UploadID, SHA256, CardUUID, ContentVersion, DekWrapped string
	}
	if e = body(w, r, smallJSON, &b); e != nil {
		return e
	}
	card, e := uuid(b.CardUUID)
	if e != nil {
		return fail(400, "bad_request")
	}
	version, e := uuid(b.ContentVersion)
	if e != nil || version == legacyAttachmentVersion {
		return fail(400, "invalid_attachment_version")
	}
	dek, e := decode64(b.DekWrapped)
	if e != nil || len(dek) < 28 || len(dek) > 256 || !idPattern.MatchString(b.UploadID) || !hashPattern.MatchString(b.SHA256) {
		return fail(400, "bad_request")
	}
	key := attachPrefix(vid) + "staging/" + b.UploadID
	stream, obj, e := s.Objects.Get(r.Context(), key)
	if e != nil {
		var apiErr *apiError
		if errors.As(e, &apiErr) && apiErr.Status == 404 {
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
	sha := digest(raw)
	final := attachPrefix(vid) + id + "/" + version + "/" + sha
	if e = s.Objects.Put(r.Context(), final, raw, "application/octet-stream"); e != nil {
		return e
	}
	var quotaBytes int64
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		if e = s.noRekey(r, t, vid); e != nil {
			return e
		}
		var storedCard, storedSHA string
		var storedDEK []byte
		var storedBytes int64
		var purgeStarted sql.NullInt64
		existingErr := t.QueryRowContext(r.Context(), "SELECT card_uuid,sha256,bytes,dek_wrapped,purge_started_ms FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=? FOR UPDATE", vid, id, version).Scan(&storedCard, &storedSHA, &storedBytes, &storedDEK, &purgeStarted)
		versionExists := existingErr == nil
		if existingErr != nil && !errors.Is(existingErr, sql.ErrNoRows) {
			return existingErr
		}
		if versionExists {
			if purgeStarted.Valid {
				return fail(409, "attachment_version_expired")
			}
			if storedCard != card || storedSHA != sha || storedBytes != int64(len(raw)) || !bytes.Equal(storedDEK, dek) {
				return fail(409, "attachment_version_reused")
			}
		} else {
			total := v.AttachBytes + int64(len(raw))
			if total > s.Config.limit("ATTACH_QUOTA_PER_VAULT") {
				return fail(413, "quota_exceeded")
			}
			if _, e = t.ExecContext(r.Context(), "INSERT INTO attachment_versions(vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms,unreferenced_ms) VALUES(?,?,?,?,?,?,?,?,?,?)", vid, id, version, card, final, dek, sha, len(raw), now(), now()); e != nil {
				return e
			}
			v.AttachBytes = total
		}
		if e = pinAttachmentVersionForOpenConflicts(r.Context(), t, vid, card, id, version); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE vaults SET attach_bytes=?,updated_ms=? WHERE vault_id=?", v.AttachBytes, now(), vid); e != nil {
			return e
		}
		quotaBytes = v.AttachBytes
		return nil
	})
	if e != nil {
		return e
	}
	if e = s.Objects.Delete(r.Context(), key); e != nil {
		s.Log.Warn("staging cleanup deferred")
	}
	s.audit(r.Context(), "attach_commit", a.UserID, vid, map[string]int{"bytes": len(raw)})
	writeJSON(w, 200, map[string]any{"ok": true, "bytes": len(raw), "quotaBytes": quotaBytes})
	return nil
}

func pinAttachmentVersionForOpenConflicts(
	ctx context.Context, t *sql.Tx, vid, card, id, version string,
) error {
	rows, e := t.QueryContext(ctx, "SELECT conflict_id FROM item_conflicts WHERE vault_id=? AND item_uuid=? AND status='open'", vid, card)
	if e != nil {
		return e
	}
	conflicts := []string{}
	for rows.Next() {
		var conflictID string
		if e = rows.Scan(&conflictID); e != nil {
			rows.Close()
			return e
		}
		conflicts = append(conflicts, conflictID)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, conflictID := range conflicts {
		if _, e = t.ExecContext(ctx, "INSERT IGNORE INTO attachment_version_conflicts(vault_id,conflict_id,attach_uuid,content_version) VALUES(?,?,?,?)", vid, conflictID, id, version); e != nil {
			return e
		}
		if _, e = t.ExecContext(ctx, "UPDATE attachment_versions SET unreferenced_ms=NULL WHERE vault_id=? AND attach_uuid=? AND content_version=?", vid, id, version); e != nil {
			return e
		}
	}
	return nil
}

// attachmentManifest returns the current, lightweight attachment metadata for one card.
func (s *Server) attachmentManifest(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	card, e := uuid(r.URL.Query().Get("cardUuid"))
	if e != nil {
		return fail(400, "bad_request")
	}
	rows, e := s.DB.QueryContext(r.Context(), "SELECT attach_uuid,content_version,dek_wrapped,sha256,bytes,created_ms FROM attachments WHERE vault_id=? AND card_uuid=? ORDER BY attach_uuid", vid, card)
	if e != nil {
		return e
	}
	defer rows.Close()
	attachments := []map[string]any{}
	for rows.Next() {
		var id string
		var version sql.NullString
		var dek []byte
		var sha string
		var size, created int64
		if e = rows.Scan(&id, &version, &dek, &sha, &size, &created); e != nil {
			return e
		}
		entry := map[string]any{"attachmentId": id, "dekWrapped": b64(dek), "sha256": sha, "bytes": size, "createdMs": created}
		if version.Valid {
			entry["contentVersion"] = version.String
		}
		attachments = append(attachments, entry)
	}
	if e = rows.Err(); e != nil {
		return e
	}
	writeJSON(w, 200, map[string]any{"attachments": attachments})
	return nil
}

// attachmentVersions lists current and retained wrappers for rekey and conflict recovery.
func (s *Server) attachmentVersions(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	limit := 200
	offset := 0
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, e := strconv.Atoi(raw)
		if e != nil || parsed < 1 || parsed > 500 {
			return fail(400, "bad_request")
		}
		limit = parsed
	}
	if raw := r.URL.Query().Get("offset"); raw != "" {
		parsed, e := strconv.Atoi(raw)
		if e != nil || parsed < 0 || parsed > 50000 {
			return fail(400, "bad_request")
		}
		offset = parsed
	}
	query := "SELECT av.attach_uuid,av.content_version,av.card_uuid,av.dek_wrapped,av.sha256,av.bytes,av.created_ms,av.retired_ms,EXISTS(SELECT 1 FROM attachments a WHERE a.vault_id=av.vault_id AND a.attach_uuid=av.attach_uuid AND a.content_version=av.content_version) FROM attachment_versions av WHERE av.vault_id=? AND av.purge_started_ms IS NULL"
	args := []any{vid}
	if cardID := r.URL.Query().Get("cardUuid"); cardID != "" {
		validatedCardID, err := uuid(cardID)
		if err != nil {
			return fail(400, "bad_request")
		}
		query += " AND av.card_uuid=?"
		args = append(args, validatedCardID)
	}
	if attachmentID := r.URL.Query().Get("attachmentId"); attachmentID != "" {
		validatedAttachmentID, err := uuid(attachmentID)
		if err != nil {
			return fail(400, "bad_request")
		}
		query += " AND av.attach_uuid=?"
		args = append(args, validatedAttachmentID)
	}
	query += " ORDER BY av.attach_uuid,av.content_version LIMIT ? OFFSET ?"
	args = append(args, limit+1, offset)
	rows, e := s.DB.QueryContext(r.Context(), query, args...)
	if e != nil {
		return e
	}
	defer rows.Close()
	versions := []map[string]any{}
	hasMore := false
	for rows.Next() {
		var id, version, card, sha string
		var dek []byte
		var size, created int64
		var retired sql.NullInt64
		var isCurrent bool
		if e = rows.Scan(&id, &version, &card, &dek, &sha, &size, &created, &retired, &isCurrent); e != nil {
			return e
		}
		if len(versions) == limit {
			hasMore = true
			break
		}
		entry := map[string]any{"attachmentId": id, "cardUuid": card, "dekWrapped": b64(dek), "sha256": sha, "bytes": size, "createdMs": created, "isCurrent": isCurrent}
		if version != legacyAttachmentVersion {
			entry["contentVersion"] = version
		}
		if retired.Valid {
			entry["retiredMs"] = retired.Int64
		}
		versions = append(versions, entry)
	}
	if e = rows.Err(); e != nil {
		return e
	}
	writeJSON(w, 200, map[string]any{"versions": versions, "nextOffset": offset + len(versions), "hasMore": hasMore})
	return nil
}

// attachmentGet authorizes the vault owner and streams one immutable ciphertext version.
func (s *Server) attachmentGet(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	id, e := uuid(param(r, "attachmentID"))
	if e != nil {
		return fail(404, "not_found")
	}
	version := r.URL.Query().Get("version")
	var key, sha, card string
	var size int64
	var dek []byte
	if version == "" {
		e = s.DB.QueryRowContext(r.Context(), "SELECT object_key,sha256,bytes,dek_wrapped,card_uuid FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&key, &sha, &size, &dek, &card)
	} else {
		version, e = uuid(version)
		if e != nil || version == legacyAttachmentVersion {
			return fail(400, "invalid_attachment_version")
		}
		e = s.DB.QueryRowContext(r.Context(), "SELECT object_key,sha256,bytes,dek_wrapped,card_uuid FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=? AND purge_started_ms IS NULL", vid, id, version).Scan(&key, &sha, &size, &dek, &card)
	}
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
	w.Header().Set("X-Card-UUID", card)
	w.Header().Set("X-Dek-Wrapped", b64(dek))
	if version != "" {
		w.Header().Set("X-Content-Version", version)
	}
	w.Header().Set("Content-Length", intString(size))
	_, e = io.Copy(w, stream)
	return e
}

// attachmentDelete tombstones a logical attachment and retains its bytes through the grace period.
func (s *Server) attachmentDelete(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	vid := param(r, "vaultID")
	id, e := uuid(param(r, "attachmentID"))
	if e != nil {
		return fail(404, "not_found")
	}
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := loadVault(r.Context(), t, a.UserID, vid, true); e != nil {
			return e
		}
		if e := s.noRekey(r, t, vid); e != nil {
			return e
		}
		var card string
		var version sql.NullString
		e := t.QueryRowContext(r.Context(), "SELECT card_uuid,content_version FROM attachments WHERE vault_id=? AND attach_uuid=? FOR UPDATE", vid, id).Scan(&card, &version)
		if errors.Is(e, sql.ErrNoRows) {
			return fail(404, "not_found")
		}
		if e != nil {
			return e
		}
		if e = retireAttachmentVersion(r.Context(), t, vid, id, card, version, now()); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "DELETE FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id); e != nil {
			return e
		}
		_, e = t.ExecContext(r.Context(), "UPDATE vaults SET updated_ms=? WHERE vault_id=?", now(), vid)
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "attach_delete", a.UserID, vid, nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}

func retireAttachmentVersion(ctx context.Context, t *sql.Tx,
	vid, id, card string, version sql.NullString, timestamp int64) error {
	versionID := legacyAttachmentVersion
	if version.Valid {
		versionID = version.String
	}
	if e := retireAttachmentContentVersion(ctx, t, vid, id, versionID, timestamp); e != nil {
		return e
	}
	_, e := t.ExecContext(ctx, "INSERT INTO attachment_tombstones(vault_id,attach_uuid,card_uuid,deleted_ms) VALUES(?,?,?,?) ON DUPLICATE KEY UPDATE card_uuid=VALUES(card_uuid),deleted_ms=VALUES(deleted_ms)", vid, id, card, timestamp)
	return e
}

func retireAttachmentContentVersion(ctx context.Context, t *sql.Tx,
	vid, id, version string, timestamp int64) error {
	_, e := t.ExecContext(ctx, "UPDATE attachment_versions SET retired_ms=COALESCE(retired_ms,?),unreferenced_ms=IF(EXISTS(SELECT 1 FROM attachment_version_conflicts WHERE vault_id=? AND attach_uuid=? AND content_version=?),NULL,COALESCE(unreferenced_ms,?)) WHERE vault_id=? AND attach_uuid=? AND content_version=?", timestamp, vid, id, version, timestamp, vid, id, version)
	return e
}

func activateConflictAttachmentReferences(
	ctx context.Context,
	t *sql.Tx,
	vid string,
	conflictID string,
	sourceCard string,
	targetCard string,
	references []attachmentReference,
) error {
	if len(references) > 500 {
		return fail(400, "bad_attachment_reference")
	}
	selected := make([]attachmentReference, 0, len(references))
	for _, reference := range references {
		id, err := uuid(reference.AttachmentID)
		if err != nil {
			return fail(400, "bad_attachment_reference")
		}
		version, err := uuid(reference.ContentVersion)
		if err != nil || version == legacyAttachmentVersion {
			return fail(400, "bad_attachment_reference")
		}
		var pinned int
		if err = t.QueryRowContext(ctx, "SELECT COUNT(*) FROM attachment_version_conflicts WHERE vault_id=? AND conflict_id=? AND attach_uuid=? AND content_version=?", vid, conflictID, id, version).Scan(&pinned); err != nil {
			return err
		}
		if pinned != 1 {
			return fail(409, "conflict_attachment_unavailable")
		}
		if sourceCard != targetCard {
			var owner string
			var purgeStarted sql.NullInt64
			err = t.QueryRowContext(ctx, "SELECT card_uuid,purge_started_ms FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=? FOR UPDATE", vid, id, version).Scan(&owner, &purgeStarted)
			if errors.Is(err, sql.ErrNoRows) {
				return fail(409, "attachment_version_missing")
			}
			if err != nil {
				return err
			}
			if owner != sourceCard || purgeStarted.Valid {
				return fail(409, "conflict_attachment_unavailable")
			}
			var active int
			if err = t.QueryRowContext(ctx, "SELECT COUNT(*) FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&active); err != nil {
				return err
			}
			if active != 0 {
				return fail(409, "conflict_attachment_unavailable")
			}
			if _, err = t.ExecContext(ctx, "UPDATE attachment_versions SET card_uuid=?,retired_ms=NULL,unreferenced_ms=NULL WHERE vault_id=? AND attach_uuid=? AND content_version=?", targetCard, vid, id, version); err != nil {
				return err
			}
		}
		reference.AttachmentID = id
		reference.ContentVersion = version
		reference.RestoreDeleted = true
		selected = append(selected, reference)
	}
	return activateAttachmentReferences(ctx, t, vid, targetCard, selected)
}

func activateAttachmentReferences(ctx context.Context, t *sql.Tx,
	vid, card string, references []attachmentReference) error {
	requested := make(map[string]string, len(references))
	restore := make(map[string]bool, len(references))
	for _, reference := range references {
		id, e := uuid(reference.AttachmentID)
		if e != nil {
			return fail(400, "bad_attachment_reference")
		}
		version, e := uuid(reference.ContentVersion)
		if e != nil || version == legacyAttachmentVersion {
			return fail(400, "bad_attachment_reference")
		}
		if _, exists := requested[id]; exists {
			return fail(400, "duplicate_attachment_reference")
		}
		requested[id] = version
		restore[id] = reference.RestoreDeleted
	}

	rows, e := t.QueryContext(ctx, "SELECT attach_uuid,content_version FROM attachments WHERE vault_id=? AND card_uuid=? FOR UPDATE", vid, card)
	if e != nil {
		return e
	}
	type currentReference struct {
		id      string
		version sql.NullString
	}
	current := []currentReference{}
	for rows.Next() {
		var item currentReference
		if e = rows.Scan(&item.id, &item.version); e != nil {
			rows.Close()
			return e
		}
		current = append(current, item)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	timestamp := now()
	for _, item := range current {
		requestedVersion, remains := requested[item.id]
		if remains && item.version.Valid && item.version.String == requestedVersion {
			continue
		}
		version := legacyAttachmentVersion
		if item.version.Valid {
			version = item.version.String
		}
		if e = retireAttachmentContentVersion(ctx, t, vid, item.id, version, timestamp); e != nil {
			return e
		}
		if !remains {
			if _, e = t.ExecContext(ctx, "INSERT INTO attachment_tombstones(vault_id,attach_uuid,card_uuid,deleted_ms) VALUES(?,?,?,?) ON DUPLICATE KEY UPDATE card_uuid=VALUES(card_uuid),deleted_ms=VALUES(deleted_ms)", vid, item.id, card, timestamp); e != nil {
				return e
			}
			if _, e = t.ExecContext(ctx, "DELETE FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, item.id); e != nil {
				return e
			}
		}
	}
	for id, version := range requested {
		var tombstone int
		if e = t.QueryRowContext(ctx, "SELECT COUNT(*) FROM attachment_tombstones WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&tombstone); e != nil {
			return e
		}
		if tombstone > 0 && !restore[id] {
			return fail(409, "attachment_deleted")
		}
		if tombstone > 0 {
			if _, e = t.ExecContext(ctx, "DELETE FROM attachment_tombstones WHERE vault_id=? AND attach_uuid=?", vid, id); e != nil {
				return e
			}
		}
		var owner, objectKey, sha string
		var dek []byte
		var size int64
		var purgeStarted sql.NullInt64
		e = t.QueryRowContext(ctx, "SELECT card_uuid,object_key,dek_wrapped,sha256,bytes,purge_started_ms FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=? FOR UPDATE", vid, id, version).Scan(&owner, &objectKey, &dek, &sha, &size, &purgeStarted)
		if errors.Is(e, sql.ErrNoRows) {
			return fail(409, "attachment_version_missing")
		}
		if e != nil {
			return e
		}
		if purgeStarted.Valid {
			return fail(409, "attachment_version_expired")
		}
		if owner != card {
			return fail(409, "attachment_owner_mismatch")
		}
		if _, e = t.ExecContext(ctx, "UPDATE attachment_versions SET retired_ms=NULL,unreferenced_ms=NULL WHERE vault_id=? AND attach_uuid=? AND content_version=?", vid, id, version); e != nil {
			return e
		}
		if _, e = t.ExecContext(ctx, "INSERT INTO attachments(vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms) VALUES(?,?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE content_version=VALUES(content_version),card_uuid=VALUES(card_uuid),object_key=VALUES(object_key),dek_wrapped=VALUES(dek_wrapped),sha256=VALUES(sha256),bytes=VALUES(bytes)", vid, id, version, card, objectKey, dek, sha, size, timestamp); e != nil {
			return e
		}
	}
	return nil
}
