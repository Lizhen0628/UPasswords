package api

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"
)

const maxConflictCandidatesPerItem = 32

type conflictCandidateRow struct {
	ID, SourceSession, DeviceName, Platform string
	Kind, Op                                int
	Revision, Modified, Committed           int64
	Body                                    []byte
	SHA                                     sql.NullString
}

func (c conflictCandidateRow) wire() map[string]any {
	result := map[string]any{
		"candidateId": c.ID,
		"kind":        c.Kind,
		"op":          map[int]string{1: "upsert", 2: "delete"}[c.Op],
		"revision":    c.Revision,
		"modifiedMs":  c.Modified,
		"committedMs": c.Committed,
		"deviceName":  c.DeviceName,
		"platform":    c.Platform,
	}
	if c.SourceSession != "" {
		result["sourceSessionId"] = c.SourceSession
	}
	if c.Body != nil {
		result["bodyB64"] = b64(c.Body)
	}
	if c.SHA.Valid {
		result["sha256"] = c.SHA.String
	}
	return result
}

// conflictsList returns encrypted, unresolved candidates and immutable source snapshots.
func (s *Server) conflictsList(w http.ResponseWriter, r *http.Request) error {
	vid := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, identity(r).UserID, vid, false); e != nil {
		return e
	}
	rows, e := s.DB.QueryContext(r.Context(), "SELECT conflict_id,item_uuid,base_revision,current_revision,current_deleted_seq,generation,created_ms,updated_ms FROM item_conflicts WHERE vault_id=? AND status='open' ORDER BY updated_ms,conflict_id", vid)
	if e != nil {
		return e
	}
	type conflictRow struct {
		id, item                                                string
		base, current, deletedSeq, generation, created, updated int64
	}
	groups := []conflictRow{}
	for rows.Next() {
		var group conflictRow
		if e = rows.Scan(&group.id, &group.item, &group.base, &group.current, &group.deletedSeq, &group.generation, &group.created, &group.updated); e != nil {
			rows.Close()
			return e
		}
		groups = append(groups, group)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	out := make([]map[string]any, 0, len(groups))
	for _, group := range groups {
		candidates, e := s.conflictCandidates(r, group.id)
		if e != nil {
			return e
		}
		out = append(out, map[string]any{
			"conflictId":        group.id,
			"itemUuid":          group.item,
			"baseRevision":      group.base,
			"currentRevision":   group.current,
			"currentDeletedSeq": group.deletedSeq,
			"generation":        group.generation,
			"createdMs":         group.created,
			"updatedMs":         group.updated,
			"candidates":        candidates,
		})
	}
	writeJSON(w, 200, map[string]any{"conflicts": out})
	return nil
}

func (s *Server) conflictCandidates(r *http.Request, conflictID string) ([]map[string]any, error) {
	rows, e := s.DB.QueryContext(r.Context(), "SELECT candidate_id,COALESCE(source_session_id,''),source_device_name,source_platform,kind,op,revision,modified_ms,committed_ms,body,body_sha256 FROM item_conflict_candidates WHERE conflict_id=? ORDER BY committed_ms,candidate_id", conflictID)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var candidate conflictCandidateRow
		if e = rows.Scan(&candidate.ID, &candidate.SourceSession, &candidate.DeviceName, &candidate.Platform, &candidate.Kind, &candidate.Op, &candidate.Revision, &candidate.Modified, &candidate.Committed, &candidate.Body, &candidate.SHA); e != nil {
			return nil, e
		}
		out = append(out, candidate.wire())
	}
	return out, rows.Err()
}

// conflictRegister stores the live remote ciphertext and an authenticated client's competing ciphertext.
func (s *Server) conflictRegister(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		ExpectedRevision     *int64
		ExpectedDeletedSeq   *int64
		BaseRevision         *int64
		CandidateID          string
		CandidateFingerprint *string
		Kind                 int
		Op                   string
		BodyB64              string
		SHA256               *string
		ModifiedMS           *int64
	}
	if e := body(w, r, batchJSON, &b); e != nil {
		return e
	}
	itemID, e := uuid(param(r, "itemID"))
	if e != nil {
		return e
	}
	if b.ExpectedRevision == nil || b.BaseRevision == nil || b.ModifiedMS == nil || b.CandidateFingerprint == nil || *b.ExpectedRevision < 1 || *b.BaseRevision < 0 || *b.BaseRevision >= *b.ExpectedRevision || *b.ModifiedMS < 0 || *b.ExpectedRevision >= 9007199254740991 || *b.ModifiedMS > 9007199254740991 || !idPattern.MatchString(b.CandidateID) || !hashPattern.MatchString(*b.CandidateFingerprint) || !equal(b.CandidateID, strings.ToLower((*b.CandidateFingerprint)[:32])) || (b.ExpectedDeletedSeq != nil && *b.ExpectedDeletedSeq < 1) || (b.Kind != 1 && b.Kind != 2 && b.Kind != 3) || (b.Op != "upsert" && b.Op != "delete") {
		return fail(400, "bad_request")
	}
	var candidateBody []byte
	var candidateHash sql.NullString
	if b.Op == "upsert" {
		candidateBody, e = decode64(b.BodyB64)
		if e != nil || len(candidateBody) == 0 {
			return fail(400, "bad_request")
		}
		if int64(len(candidateBody)) > s.Config.limit("ITEM_BODY_MAX_BYTES") {
			return fail(413, "item_too_large")
		}
		sha := digest(candidateBody)
		if b.SHA256 != nil && (!hashPattern.MatchString(*b.SHA256) || !equal(strings.ToLower(*b.SHA256), sha)) {
			return fail(400, "hash_mismatch")
		}
		candidateHash = sql.NullString{String: sha, Valid: true}
	} else if b.BodyB64 != "" || b.SHA256 != nil {
		return fail(400, "bad_request")
	}
	candidateOp := 1
	if b.Op == "delete" {
		candidateOp = 2
	}

	a := identity(r)
	vid := param(r, "vaultID")
	ts := now()
	var conflictID string
	var generation, candidateCount, currentDeletedSeq int64
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := loadVault(r.Context(), t, a.UserID, vid, true); e != nil {
			return e
		}
		if e := s.noRekey(r, t, vid); e != nil {
			return e
		}
		var current conflictCandidateRow
		var currentOrigin sql.NullString
		var currentRevision int64
		err := t.QueryRowContext(r.Context(), "SELECT kind,revision,body,body_sha256,modified_ms,updated_ms,COALESCE(origin_session_id,''),origin_device_name,origin_platform FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&current.Kind, &currentRevision, &current.Body, &current.SHA, &current.Modified, &current.Committed, &currentOrigin, &current.DeviceName, &current.Platform)
		if errors.Is(err, sql.ErrNoRows) {
			if b.ExpectedDeletedSeq == nil {
				return fail(409, "conflict_stale")
			}
			var deletedRevision, deletedMs int64
			err = t.QueryRowContext(r.Context(), "SELECT revision,deleted_ms,seq,COALESCE(session_id,''),device_name,platform FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&deletedRevision, &deletedMs, &currentDeletedSeq, &currentOrigin, &current.DeviceName, &current.Platform)
			if errors.Is(err, sql.ErrNoRows) || (err == nil && (deletedRevision != *b.ExpectedRevision || currentDeletedSeq != *b.ExpectedDeletedSeq)) {
				return fail(409, "conflict_stale")
			}
			if err != nil {
				return err
			}
			current.Kind = b.Kind
			current.Op = 2
			current.Modified = deletedMs
			current.Committed = deletedMs
			current.Revision = deletedRevision
			currentRevision = deletedRevision
			current.SourceSession = currentOrigin.String
			current.DeviceName = strings.TrimSpace(current.DeviceName)
			current.Platform = strings.TrimSpace(current.Platform)
			if current.Platform == "" {
				current.Platform = "other"
			}
		} else if err != nil {
			return err
		} else {
			var tombstoneCount int
			if err = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&tombstoneCount); err != nil {
				return err
			}
			if tombstoneCount > 0 {
				return fail(409, "conflict_stale")
			}
			if b.ExpectedDeletedSeq != nil || currentRevision != *b.ExpectedRevision {
				return fail(409, "conflict_stale")
			}
			currentDeletedSeq = 0
			current.Revision = currentRevision
			current.SourceSession = currentOrigin.String
			current.Op = 1
			if !current.SHA.Valid {
				current.SHA = sql.NullString{String: digest(current.Body), Valid: true}
			}
		}
		if e := t.QueryRowContext(r.Context(), "SELECT conflict_id,generation FROM item_conflicts WHERE vault_id=? AND item_uuid=? AND status='open' ORDER BY updated_ms DESC LIMIT 1 FOR UPDATE", vid, itemID).Scan(&conflictID, &generation); errors.Is(e, sql.ErrNoRows) {
			conflictID = randomHex(16)
			generation = 0
			if _, e = t.ExecContext(r.Context(), "INSERT INTO item_conflicts(conflict_id,vault_id,item_uuid,base_revision,current_revision,current_deleted_seq,generation,status,created_ms,updated_ms) VALUES(?,?,?,?,?,?,0,'open',?,?)", conflictID, vid, itemID, *b.BaseRevision, currentRevision, currentDeletedSeq, ts, ts); e != nil {
				return e
			}
		} else if e != nil {
			return e
		}
		if e := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_conflict_candidates WHERE conflict_id=?", conflictID).Scan(&candidateCount); e != nil {
			return e
		}
		added := false
		var existingHash sql.NullString
		var existingFingerprint sql.NullString
		var existingRevision int64
		var existingOp, existingKind int
		err = t.QueryRowContext(r.Context(), "SELECT candidate_fingerprint,body_sha256,op,kind,revision FROM item_conflict_candidates WHERE conflict_id=? AND candidate_id=?", conflictID, b.CandidateID).Scan(&existingFingerprint, &existingHash, &existingOp, &existingKind, &existingRevision)
		if err == nil {
			sameFingerprint := existingFingerprint.Valid && equal(existingFingerprint.String, *b.CandidateFingerprint)
			legacySameCiphertext := !existingFingerprint.Valid && existingHash == candidateHash
			if (!sameFingerprint && !legacySameCiphertext) || existingOp != candidateOp || existingKind != b.Kind || existingRevision != *b.BaseRevision {
				return fail(409, "candidate_id_reused")
			}
		} else if !errors.Is(err, sql.ErrNoRows) {
			return err
		} else {
			if candidateCount >= maxConflictCandidatesPerItem {
				return fail(413, "conflict_limit")
			}
			if _, e = t.ExecContext(r.Context(), "INSERT INTO item_conflict_candidates(candidate_id,conflict_id,kind,op,revision,body,body_sha256,candidate_fingerprint,modified_ms,source_session_id,source_device_name,source_platform,committed_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", b.CandidateID, conflictID, b.Kind, candidateOp, *b.BaseRevision, nullableBytes(candidateBody), candidateHash, *b.CandidateFingerprint, *b.ModifiedMS, a.SessionID, a.DeviceName, a.Platform, ts); e != nil {
				return e
			}
			candidateCount++
			added = true
		}
		var remoteExists int
		remoteCandidateQuery := "SELECT COUNT(*) FROM item_conflict_candidates WHERE conflict_id=? AND revision=? AND op=?"
		remoteCandidateArgs := []any{conflictID, current.Revision, current.Op}
		if current.Op == 1 {
			remoteCandidateQuery += " AND body_sha256=?"
			remoteCandidateArgs = append(remoteCandidateArgs, current.SHA.String)
		}
		if e := t.QueryRowContext(r.Context(), remoteCandidateQuery, remoteCandidateArgs...).Scan(&remoteExists); e != nil {
			return e
		}
		if remoteExists == 0 {
			if candidateCount >= maxConflictCandidatesPerItem {
				return fail(413, "conflict_limit")
			}
			if _, e = t.ExecContext(r.Context(), "INSERT INTO item_conflict_candidates(candidate_id,conflict_id,kind,op,revision,body,body_sha256,candidate_fingerprint,modified_ms,source_session_id,source_device_name,source_platform,committed_ms) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", randomHex(16), conflictID, current.Kind, current.Op, current.Revision, nullableBytes(current.Body), nullableStringValue(current.SHA), nil, current.Modified, nullableString(current.SourceSession), current.DeviceName, current.Platform, ts); e != nil {
				return e
			}
			candidateCount++
			added = true
		}
		if added {
			generation++
		}
		if _, e := t.ExecContext(r.Context(), "UPDATE item_conflicts SET current_revision=?,current_deleted_seq=?,generation=?,updated_ms=? WHERE conflict_id=?", currentRevision, currentDeletedSeq, generation, ts, conflictID); e != nil {
			return e
		}
		if _, e := t.ExecContext(r.Context(), "INSERT IGNORE INTO attachment_version_conflicts(vault_id,conflict_id,attach_uuid,content_version) SELECT vault_id,?,attach_uuid,content_version FROM attachment_versions WHERE vault_id=? AND card_uuid=? AND purge_started_ms IS NULL AND (unreferenced_ms IS NULL OR unreferenced_ms>=?)", conflictID, vid, itemID, now()-30*dayMS); e != nil {
			return e
		}
		if _, e := t.ExecContext(r.Context(), "UPDATE attachment_versions av SET unreferenced_ms=NULL WHERE av.vault_id=? AND av.card_uuid=? AND EXISTS(SELECT 1 FROM attachment_version_conflicts c WHERE c.vault_id=av.vault_id AND c.conflict_id=? AND c.attach_uuid=av.attach_uuid AND c.content_version=av.content_version)", vid, itemID, conflictID); e != nil {
			return e
		}
		return nil
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "conflict_register", a.UserID, vid, map[string]int64{"candidates": candidateCount})
	writeJSON(w, 200, map[string]any{"conflictId": conflictID, "generation": generation, "candidateCount": candidateCount, "currentRevision": *b.ExpectedRevision})
	return nil
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func nullableStringValue(value sql.NullString) any {
	if !value.Valid {
		return nil
	}
	return value.String
}

func nullableBytes(value []byte) any {
	if len(value) == 0 {
		return nil
	}
	return value
}
