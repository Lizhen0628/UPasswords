package api

import (
	"database/sql"
	"errors"
	"net/http"
	"sort"
)

type conflictResolveCandidate struct {
	ID       string
	Kind     int
	Op       int
	Revision int64
	Modified int64
	Body     []byte
	SHA      sql.NullString
}

type conflictResolveRequest struct {
	Generation              *int64                 `json:"generation"`
	CandidateIDs            []string               `json:"candidateIds"`
	WinnerCandidateID       string                 `json:"winnerCandidateId"`
	ExpectedCurrentRevision *int64                 `json:"expectedCurrentRevision"`
	ExpectedDeletedSeq      *int64                 `json:"expectedDeletedSeq"`
	AttachmentRefs          *[]attachmentReference `json:"attachmentRefs"`
	RestoreItemUUID         string                 `json:"restoreItemUuid,omitempty"`
	BodyB64                 string                 `json:"bodyB64,omitempty"`
	MergedBodyB64           *string                `json:"mergedBodyB64,omitempty"`
	MergedModifiedMS        *int64                 `json:"mergedModifiedMs,omitempty"`
}

// conflictResolve atomically applies one authenticated client's encrypted resolution.
func (s *Server) conflictResolve(w http.ResponseWriter, r *http.Request) error {
	var b conflictResolveRequest
	if e := body(w, r, batchJSON, &b); e != nil {
		return e
	}
	conflictID := param(r, "conflictID")
	if !idPattern.MatchString(conflictID) || b.Generation == nil || *b.Generation < 0 || b.ExpectedCurrentRevision == nil || *b.ExpectedCurrentRevision < 0 || b.ExpectedDeletedSeq == nil || *b.ExpectedDeletedSeq < 0 || len(b.CandidateIDs) < 2 || len(b.CandidateIDs) > maxConflictCandidatesPerItem || !idPattern.MatchString(b.WinnerCandidateID) {
		return fail(400, "bad_request")
	}
	hasMergedBody := b.MergedBodyB64 != nil
	if hasMergedBody != (b.MergedModifiedMS != nil) ||
		(hasMergedBody && (b.RestoreItemUUID != "" || b.BodyB64 != "" || *b.ExpectedDeletedSeq != 0 ||
			*b.MergedModifiedMS < 0 || *b.MergedModifiedMS > 253402300799999)) {
		return fail(400, "bad_request")
	}
	var mergedBody []byte
	if hasMergedBody {
		var err error
		mergedBody, err = decode64(*b.MergedBodyB64)
		if err != nil || len(mergedBody) == 0 {
			return fail(400, "bad_request")
		}
		if int64(len(mergedBody)) > s.Config.limit("ITEM_BODY_MAX_BYTES") {
			return fail(413, "item_too_large")
		}
	}
	requestedIDs := append([]string(nil), b.CandidateIDs...)
	sort.Strings(requestedIDs)
	for i, id := range requestedIDs {
		if !idPattern.MatchString(id) || (i > 0 && requestedIDs[i-1] == id) {
			return fail(400, "bad_request")
		}
	}
	a := identity(r)
	vid := param(r, "vaultID")
	ts := now()
	var resolvedItemID string
	var headSeq int64
	var itemCount int64
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		headSeq = v.Head
		if e = s.noRekey(r, t, vid); e != nil {
			return e
		}
		var itemID, status string
		var currentRevision, deletedSeq, generation int64
		e = t.QueryRowContext(r.Context(), "SELECT item_uuid,status,current_revision,current_deleted_seq,generation FROM item_conflicts WHERE conflict_id=? AND vault_id=? FOR UPDATE", conflictID, vid).Scan(&itemID, &status, &currentRevision, &deletedSeq, &generation)
		if errors.Is(e, sql.ErrNoRows) {
			return fail(404, "not_found")
		}
		if e != nil {
			return e
		}
		if status != "open" {
			return fail(409, "conflict_resolved")
		}
		if generation != *b.Generation || currentRevision != *b.ExpectedCurrentRevision || deletedSeq != *b.ExpectedDeletedSeq {
			return fail(409, "conflict_stale")
		}

		candidates := make([]conflictResolveCandidate, 0, len(requestedIDs))
		rows, e := t.QueryContext(r.Context(), "SELECT candidate_id,kind,op,revision,modified_ms,body,body_sha256 FROM item_conflict_candidates WHERE conflict_id=? ORDER BY candidate_id FOR UPDATE", conflictID)
		if e != nil {
			return e
		}
		for rows.Next() {
			var candidate conflictResolveCandidate
			if e = rows.Scan(&candidate.ID, &candidate.Kind, &candidate.Op, &candidate.Revision, &candidate.Modified, &candidate.Body, &candidate.SHA); e != nil {
				rows.Close()
				return e
			}
			candidates = append(candidates, candidate)
		}
		e = rows.Err()
		rows.Close()
		if e != nil {
			return e
		}
		actualIDs := make([]string, len(candidates))
		for i, candidate := range candidates {
			actualIDs[i] = candidate.ID
		}
		if len(actualIDs) != len(requestedIDs) {
			return fail(409, "conflict_candidates_changed")
		}
		for i := range actualIDs {
			if actualIDs[i] != requestedIDs[i] {
				return fail(409, "conflict_candidates_changed")
			}
		}
		var winner *conflictResolveCandidate
		for i := range candidates {
			if candidates[i].ID == b.WinnerCandidateID {
				winner = &candidates[i]
				break
			}
		}
		if winner == nil {
			return fail(400, "bad_request")
		}
		if hasMergedBody && winner.Op != 1 {
			return fail(400, "bad_request")
		}
		if (winner.Op != 1 || winner.Kind != 1) && b.AttachmentRefs != nil && len(*b.AttachmentRefs) != 0 {
			return fail(400, "bad_attachment_reference")
		}
		attachmentRefs := []attachmentReference{}
		if b.AttachmentRefs != nil {
			attachmentRefs = *b.AttachmentRefs
		} else if winner.Op == 1 && winner.Kind == 1 {
			var candidateAttachmentCount int
			if e = t.QueryRowContext(
				r.Context(),
				"SELECT COUNT(*) FROM attachment_version_conflicts WHERE vault_id=? AND conflict_id=?",
				vid, conflictID,
			).Scan(&candidateAttachmentCount); e != nil {
				return e
			}
			if candidateAttachmentCount > 0 {
				return fail(409, "conflict_attachments_pending")
			}
		}
		if hasMergedBody && len(attachmentRefs) != 0 {
			return fail(400, "bad_attachment_reference")
		}

		var currentKind int
		var actualRevision int64
		currentErr := t.QueryRowContext(r.Context(), "SELECT kind,revision FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&currentKind, &actualRevision)
		currentExists := currentErr == nil
		if currentErr != nil && !errors.Is(currentErr, sql.ErrNoRows) {
			return currentErr
		}
		if currentExists {
			var tombstoneCount int
			if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&tombstoneCount); e != nil {
				return e
			}
			if deletedSeq != 0 || tombstoneCount > 0 || actualRevision != currentRevision {
				return fail(409, "conflict_stale")
			}
		} else {
			var tombstoneRevision, actualDeletedSeq int64
			e = t.QueryRowContext(r.Context(), "SELECT revision,seq FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&tombstoneRevision, &actualDeletedSeq)
			if errors.Is(e, sql.ErrNoRows) || (e == nil && (deletedSeq == 0 || actualDeletedSeq != deletedSeq || tombstoneRevision != currentRevision)) {
				return fail(409, "conflict_stale")
			}
			if e != nil {
				return e
			}
		}
		tombstoneRevision := currentRevision
		writeTombstone := !currentExists

		if winner.Op == 1 {
			if !winner.SHA.Valid || len(winner.Body) == 0 || digest(winner.Body) != winner.SHA.String {
				return fail(409, "candidate_corrupt")
			}
		} else if winner.Op != 2 || len(winner.Body) != 0 {
			return fail(409, "candidate_corrupt")
		}

		if currentExists {
			if b.RestoreItemUUID != "" || b.BodyB64 != "" {
				return fail(400, "bad_request")
			}
			if winner.Op == 1 {
				if winner.Kind != currentKind {
					return fail(409, "record_type_changed")
				}
				newRevision := currentRevision + 1
				body := winner.Body
				sha := winner.SHA.String
				modified := winner.Modified
				if hasMergedBody {
					body = mergedBody
					sha = digest(body)
					modified = *b.MergedModifiedMS
				}
				if _, e = t.ExecContext(r.Context(), "UPDATE "+itemTable(currentKind)+" SET revision=?,body=?,body_sha256=?,body_bytes=?,modified_ms=?,updated_ms=?,origin_session_id=?,origin_device_name=?,origin_platform=? WHERE vault_id=? AND item_uuid=?", newRevision, body, sha, len(body), modified, ts, a.SessionID, a.DeviceName, a.Platform, vid, itemID); e != nil {
					return e
				}
				resolvedItemID = itemID
				tombstoneRevision = newRevision
				if winner.Kind == 1 {
					if e = activateConflictAttachmentReferences(
						r.Context(), t, vid, conflictID, itemID, itemID, attachmentRefs); e != nil {
						return e
					}
				}
			} else {
				if currentKind == 1 {
					if e = activateAttachmentReferences(r.Context(), t, vid, itemID, []attachmentReference{}); e != nil {
						return e
					}
				}
				if _, e = t.ExecContext(r.Context(), "DELETE FROM "+itemTable(currentKind)+" WHERE vault_id=? AND item_uuid=?", vid, itemID); e != nil {
					return e
				}
				v.Count--
				tombstoneRevision = currentRevision + 1
				writeTombstone = true
			}
		} else if winner.Op == 1 {
			newItemID, e := uuid(b.RestoreItemUUID)
			if e != nil || newItemID == itemID || b.BodyB64 == "" {
				return fail(400, "bad_request")
			}
			body, e := decode64(b.BodyB64)
			if e != nil || len(body) == 0 {
				return fail(400, "bad_request")
			}
			if int64(len(body)) > s.Config.limit("ITEM_BODY_MAX_BYTES") {
				return fail(413, "item_too_large")
			}
			if v.Count+1 > s.Config.limit("ITEMS_PER_VAULT_LIMIT") {
				return fail(413, "quota_exceeded")
			}
			var liveCount, deletedCount int
			if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, newItemID).Scan(&liveCount); e != nil {
				return e
			}
			if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, newItemID).Scan(&deletedCount); e != nil {
				return e
			}
			if liveCount != 0 || deletedCount != 0 {
				return fail(409, "item_id_reused")
			}
			sha := digest(body)
			if _, e = t.ExecContext(r.Context(), "INSERT INTO "+itemTable(winner.Kind)+"(vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,created_ms,updated_ms,origin_session_id,origin_device_name,origin_platform) VALUES(?,?,?,1,?,?,?,?,?,?,?,?,?)", vid, newItemID, winner.Kind, body, sha, len(body), ts, ts, ts, a.SessionID, a.DeviceName, a.Platform); e != nil {
				return e
			}
			v.Count++
			resolvedItemID = newItemID
			if winner.Kind == 1 {
				if e = activateConflictAttachmentReferences(
					r.Context(), t, vid, conflictID, itemID, newItemID, attachmentRefs); e != nil {
					return e
				}
			}
		} else if b.RestoreItemUUID != "" || b.BodyB64 != "" {
			return fail(400, "bad_request")
		}

		var resolvedTarget any
		if resolvedItemID != "" {
			resolvedTarget = resolvedItemID
		}
		resolutionType := 1
		if hasMergedBody {
			resolutionType = 2
		}
		headSeq, e = appendConflictResolutionChange(
			r, t, vid, itemID, conflictID, *winner, resolvedTarget,
			tombstoneRevision, a.SessionID, resolutionType, ts)
		if e != nil {
			return e
		}
		if writeTombstone {
			if e = storeConflictTombstone(
				r, t, vid, itemID, tombstoneRevision, headSeq, ts, a); e != nil {
				return e
			}
		}
		expires := ts + 30*dayMS
		if _, e = t.ExecContext(r.Context(), "UPDATE item_conflict_candidates SET disposition='retained',expires_ms=? WHERE conflict_id=?", expires, conflictID); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE attachment_version_conflicts SET release_after_ms=? WHERE vault_id=? AND conflict_id=?", expires, vid, conflictID); e != nil {
			return e
		}
		var resolved any
		if resolvedItemID != "" {
			resolved = resolvedItemID
		}
		result, e := t.ExecContext(r.Context(), "UPDATE item_conflicts SET status='resolved',resolved_ms=?,expires_ms=?,selected_candidate_id=?,resolved_item_uuid=? WHERE conflict_id=? AND status='open' AND generation=?", ts, expires, winner.ID, resolved, conflictID, generation)
		if e != nil {
			return e
		}
		changed, e := result.RowsAffected()
		if e != nil {
			return e
		}
		if changed != 1 {
			return fail(409, "conflict_stale")
		}
		if headSeq > v.Head {
			v.Head = headSeq
		}
		if headSeq > 0 {
			if _, e = t.ExecContext(r.Context(), "UPDATE vaults SET item_count=?,head_seq=?,updated_ms=? WHERE vault_id=?", v.Count, v.Head, ts, vid); e != nil {
				return e
			}
		}
		itemCount = v.Count
		return nil
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "conflict_resolve", a.UserID, vid, map[string]any{"itemUuid": resolvedItemID, "itemCount": itemCount})
	writeJSON(w, 200, map[string]any{"status": "resolved", "itemUuid": nullableString(resolvedItemID), "itemCount": itemCount, "headSeq": headSeq})
	return nil
}

func appendConflictResolutionChange(r *http.Request, t *sql.Tx, vid, itemID string,
	conflictID string, winner conflictResolveCandidate, resolvedItemID any,
	sourceRevision int64, sessionID string, resolutionType int, ts int64) (int64, error) {
	result, e := t.ExecContext(r.Context(), "INSERT INTO item_changes(vault_id,item_uuid,op,revision,resolved_item_uuid,conflict_id,base_revision,winner_candidate_id,winner_kind,winner_op,resolution_type,session_id,created_ms) VALUES(?,?,4,?,?,?,?,?,?,?,?,?,?)", vid, itemID, sourceRevision, resolvedItemID, conflictID, winner.Revision, winner.ID, winner.Kind, winner.Op, resolutionType, sessionID, ts)
	if e != nil {
		return 0, e
	}
	return result.LastInsertId()
}

func storeConflictTombstone(r *http.Request, t *sql.Tx, vid, itemID string, revision, seq, deletedMs int64, a auth) error {
	_, e := t.ExecContext(r.Context(), "INSERT INTO item_tombstones(vault_id,item_uuid,revision,seq,deleted_ms,session_id,device_name,platform) VALUES(?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE revision=VALUES(revision),seq=VALUES(seq),deleted_ms=VALUES(deleted_ms),session_id=VALUES(session_id),device_name=VALUES(device_name),platform=VALUES(platform)", vid, itemID, revision, seq, deletedMs, a.SessionID, a.DeviceName, a.Platform)
	return e
}
