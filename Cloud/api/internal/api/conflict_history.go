package api

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"strings"
)

const (
	conflictHistoryDefaultLimit = int64(50)
	conflictHistoryMaximumLimit = int64(100)
	conflictHistoryMaximumBytes = 6 << 20
	conflictHistoryCursorTTLMS  = int64(60 * 60 * 1000)
)

type conflictHistoryCursor struct {
	SnapshotMS  int64  `json:"snapshotMs"`
	Total       int64  `json:"total"`
	Offset      int64  `json:"offset"`
	ResolvedMS  int64  `json:"resolvedMs"`
	ConflictID  string `json:"conflictId"`
	CommittedMS int64  `json:"committedMs"`
	CandidateID string `json:"candidateId"`
}

type conflictHistoryEntry struct {
	ConflictID          string
	ItemUUID            string
	BaseRevision        int64
	CurrentRevision     int64
	CurrentDeletedSeq   int64
	Generation          int64
	CreatedMS           int64
	UpdatedMS           int64
	ResolvedMS          int64
	ExpiresMS           int64
	SelectedCandidateID sql.NullString
	Candidate           conflictCandidateRow
}

func (e conflictHistoryEntry) wire() map[string]any {
	conflict := map[string]any{
		"conflictId":        e.ConflictID,
		"itemUuid":          e.ItemUUID,
		"baseRevision":      e.BaseRevision,
		"currentRevision":   e.CurrentRevision,
		"currentDeletedSeq": e.CurrentDeletedSeq,
		"generation":        e.Generation,
		"createdMs":         e.CreatedMS,
		"updatedMs":         e.UpdatedMS,
		"resolvedMs":        e.ResolvedMS,
		"expiresMs":         e.ExpiresMS,
		"candidate":         e.Candidate.wire(),
	}
	if e.SelectedCandidateID.Valid {
		conflict["selectedCandidateId"] = e.SelectedCandidateID.String
	}
	return conflict
}

// conflictHistoryList pages retained encrypted candidates from resolved conflicts.
func (s *Server) conflictHistoryList(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	limit, err := uintQuery(r, "limit", conflictHistoryDefaultLimit)
	if err != nil || limit == 0 {
		return fail(400, "bad_request")
	}
	if limit > conflictHistoryMaximumLimit {
		limit = conflictHistoryMaximumLimit
	}

	var cursor *conflictHistoryCursor
	if token := r.URL.Query().Get("cursor"); token != "" {
		parsed, err := s.parseConflictHistoryCursor(vid, token)
		if err != nil {
			return err
		}
		cursor = &parsed
	}

	tx, err := s.DB.BeginTx(r.Context(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err = loadVault(r.Context(), tx, identity(r).UserID, vid, false); err != nil {
		return err
	}

	snapshotMS := now()
	var total int64
	var offset int64
	if cursor == nil {
		snapshotMS = now()
		if err = tx.QueryRowContext(r.Context(), `
			SELECT COUNT(*)
			FROM item_conflicts c
			JOIN item_conflict_candidates cc ON cc.conflict_id=c.conflict_id
			WHERE c.vault_id=? AND c.status='resolved' AND c.resolved_ms IS NOT NULL
			  AND c.resolved_ms<=? AND c.expires_ms>?
			  AND cc.disposition='retained' AND cc.expires_ms>?`,
			vid, snapshotMS, snapshotMS, snapshotMS).Scan(&total); err != nil {
			return err
		}
	} else {
		snapshotMS = cursor.SnapshotMS
		total = cursor.Total
		offset = cursor.Offset
	}

	query := `
		SELECT c.conflict_id,c.item_uuid,c.base_revision,c.current_revision,c.current_deleted_seq,
		       c.generation,c.created_ms,c.updated_ms,c.resolved_ms,c.expires_ms,c.selected_candidate_id,
		       cc.candidate_id,COALESCE(cc.source_session_id,''),cc.source_device_name,cc.source_platform,
		       cc.kind,cc.op,cc.revision,cc.modified_ms,cc.committed_ms,cc.body,cc.body_sha256
		FROM item_conflicts c
		JOIN item_conflict_candidates cc ON cc.conflict_id=c.conflict_id
		WHERE c.vault_id=? AND c.status='resolved' AND c.resolved_ms IS NOT NULL
		  AND c.resolved_ms<=? AND c.expires_ms>?
		  AND cc.disposition='retained' AND cc.expires_ms>?`
	args := []any{vid, snapshotMS, snapshotMS, snapshotMS}
	if cursor != nil {
		query += ` AND (
			c.resolved_ms>? OR (c.resolved_ms=? AND (
				c.conflict_id>? OR (c.conflict_id=? AND (
					cc.committed_ms>? OR (cc.committed_ms=? AND cc.candidate_id>?)
				))
			))
		)`
		args = append(args,
			cursor.ResolvedMS,
			cursor.ResolvedMS,
			cursor.ConflictID,
			cursor.ConflictID,
			cursor.CommittedMS,
			cursor.CommittedMS,
			cursor.CandidateID)
	}
	query += ` ORDER BY c.resolved_ms,c.conflict_id,cc.committed_ms,cc.candidate_id LIMIT ?`
	args = append(args, limit+1)
	rows, err := tx.QueryContext(r.Context(), query, args...)
	if err != nil {
		return err
	}
	entries := make([]conflictHistoryEntry, 0, limit)
	var bodyBytes int
	var last conflictHistoryCursor
	more := false
	for rows.Next() {
		if int64(len(entries)) >= limit {
			more = true
			break
		}
		var entry conflictHistoryEntry
		candidate := &entry.Candidate
		if err = rows.Scan(
			&entry.ConflictID, &entry.ItemUUID, &entry.BaseRevision, &entry.CurrentRevision,
			&entry.CurrentDeletedSeq, &entry.Generation, &entry.CreatedMS, &entry.UpdatedMS,
			&entry.ResolvedMS, &entry.ExpiresMS, &entry.SelectedCandidateID,
			&candidate.ID, &candidate.SourceSession, &candidate.DeviceName, &candidate.Platform,
			&candidate.Kind, &candidate.Op, &candidate.Revision, &candidate.Modified,
			&candidate.Committed, &candidate.Body, &candidate.SHA); err != nil {
			rows.Close()
			return err
		}
		if bodyBytes+len(candidate.Body) > conflictHistoryMaximumBytes && len(entries) > 0 {
			more = true
			break
		}
		bodyBytes += len(candidate.Body)
		entries = append(entries, entry)
		last = conflictHistoryCursor{
			SnapshotMS:  snapshotMS,
			Total:       total,
			Offset:      offset + int64(len(entries)),
			ResolvedMS:  entry.ResolvedMS,
			ConflictID:  entry.ConflictID,
			CommittedMS: candidate.Committed,
			CandidateID: candidate.ID,
		}
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		return err
	}
	if err = rows.Close(); err != nil {
		return err
	}
	if int64(len(entries)) == 0 && offset < total {
		return fail(409, "conflict_history_changed")
	}
	nextOffset := offset + int64(len(entries))
	if (more && nextOffset >= total) || nextOffset > total {
		return fail(409, "conflict_history_changed")
	}
	var nextCursor any
	if nextOffset < total {
		encoded, err := s.makeConflictHistoryCursor(vid, last)
		if err != nil {
			return err
		}
		nextCursor = encoded
	}
	if err = tx.Commit(); err != nil {
		return err
	}
	items := make([]map[string]any, 0, len(entries))
	for _, entry := range entries {
		items = append(items, entry.wire())
	}
	s.audit(r.Context(), "conflict_history_list", identity(r).UserID, vid, map[string]int64{"candidates": int64(len(items))})
	writeJSON(w, 200, map[string]any{
		"snapshotMs":      snapshotMS,
		"totalCandidates": total,
		"candidates":      items,
		"nextCursor":      nextCursor,
	})
	return nil
}

func (s *Server) makeConflictHistoryCursor(vaultID string, cursor conflictHistoryCursor) (string, error) {
	payload, err := json.Marshal(cursor)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(payload)
	signature := s.mac("conflict-history:" + vaultID + ":" + encoded)
	return encoded + "." + signature, nil
}

func (s *Server) parseConflictHistoryCursor(vaultID, token string) (conflictHistoryCursor, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 2 || !equal(s.mac("conflict-history:"+vaultID+":"+parts[0]), parts[1]) {
		return conflictHistoryCursor{}, fail(400, "bad_request")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return conflictHistoryCursor{}, fail(400, "bad_request")
	}
	var cursor conflictHistoryCursor
	if err = json.Unmarshal(payload, &cursor); err != nil {
		return conflictHistoryCursor{}, fail(400, "bad_request")
	}
	currentMS := now()
	if cursor.SnapshotMS <= 0 || cursor.Total <= 0 || cursor.Offset <= 0 || cursor.Offset >= cursor.Total ||
		cursor.ResolvedMS <= 0 || cursor.ResolvedMS > cursor.SnapshotMS ||
		!idPattern.MatchString(cursor.ConflictID) || cursor.CommittedMS < 0 ||
		!idPattern.MatchString(cursor.CandidateID) {
		return conflictHistoryCursor{}, fail(400, "bad_request")
	}
	if cursor.SnapshotMS > currentMS || currentMS-cursor.SnapshotMS > conflictHistoryCursorTTLMS {
		return conflictHistoryCursor{}, fail(http.StatusGone, "cursor_expired")
	}
	return cursor, nil
}
