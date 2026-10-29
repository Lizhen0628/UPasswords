// 库密钥轮换的暂存会话、分块与事务提交；普通写入在轮换期间拒绝。
package api

import (
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
)

const (
	rekeyConflictPageLimit        = 200
	rekeyConflictPageMaximumBytes = 6 << 20
)

// rekey is the locked staging manifest for a pending key rotation; counts are verified again at commit.
type rekey struct {
	ID, Envelope                                         string
	Version, Items, Deks, ItemStaged, DekStaged, Expires int64
}

// loadRekey locks a vault-scoped manifest and rejects missing or expired staging sessions.
func loadRekey(r *http.Request, t *sql.Tx, vid, rid string) (rekey, error) {
	var k rekey
	if !idPattern.MatchString(rid) {
		return k, fail(404, "not_found")
	}
	e := t.QueryRowContext(r.Context(), "SELECT rekey_id,new_envelope_enc,new_password_version,item_total,dek_total,item_staged,dek_staged,expires_ms FROM rekeys WHERE vault_id=? AND rekey_id=? FOR UPDATE", vid, rid).Scan(&k.ID, &k.Envelope, &k.Version, &k.Items, &k.Deks, &k.ItemStaged, &k.DekStaged, &k.Expires)
	if errors.Is(e, sql.ErrNoRows) {
		return k, fail(404, "not_found")
	}
	if e == nil && k.Expires <= now() {
		return k, fail(410, "rekey_expired")
	}
	return k, e
}

// rekeyBegin records the new encrypted envelope and expected counts while holding the vault write lock.
func (s *Server) rekeyBegin(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Envelope            string
		ItemCount, DekCount *int64
	}
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	raw, e := decode64(b.Envelope)
	if e != nil || !validEnvelope(raw) {
		return fail(400, "invalid_envelope")
	}
	if b.ItemCount == nil || b.DekCount == nil || *b.ItemCount < 0 || *b.DekCount < 0 || *b.ItemCount > s.Config.limit("ITEMS_PER_VAULT_LIMIT") || *b.DekCount > 50000 {
		return fail(400, "bad_request")
	}
	enc, e := s.seal(raw)
	if e != nil {
		return e
	}
	a := identity(r)
	vid := param(r, "vaultID")
	rid := randomHex(16)
	expires := now() + s.Config.limit("REKEY_TTL_MS")
	var version, conflictCount int64
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		if e = s.noRekey(r, t, vid); e != nil {
			return e
		}
		var purgingAttachments int
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachment_versions WHERE vault_id=? AND purge_started_ms IS NOT NULL", vid).Scan(&purgingAttachments); e != nil {
			return e
		}
		if purgingAttachments > 0 {
			return fail(409, "attachment_cleanup_in_progress")
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=?", vid).Scan(&conflictCount); e != nil {
			return e
		}
		version = v.Version + 1
		_, e = t.ExecContext(r.Context(), "INSERT INTO rekeys(rekey_id,vault_id,new_envelope_enc,new_password_version,item_total,dek_total,item_staged,dek_staged,expires_ms,created_ms) VALUES(?,?,?,?,?,?,0,0,?,?)", rid, vid, enc, version, *b.ItemCount, *b.DekCount, expires, now())
		if e == nil {
			_, e = t.ExecContext(r.Context(), "INSERT INTO rekey_conflict_manifests(rekey_id,vault_id,candidate_total,candidate_staged) VALUES(?,?,?,0)", rid, vid, conflictCount)
		}
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "rekey_begin", a.UserID, vid, nil)
	writeJSON(w, 201, map[string]any{
		"rekeyId": rid, "expiresAt": expires, "passwordVersion": version,
		"conflictCount": conflictCount,
	})
	return nil
}

// rekeyConflictCandidates pages the candidate inventory captured by an active rekey.
func (s *Server) rekeyConflictCandidates(w http.ResponseWriter, r *http.Request) error {
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 || offset > 1_600_000 {
		return fail(400, "bad_request")
	}
	limit, err := strconv.Atoi(r.URL.Query().Get("limit"))
	if err != nil || limit < 1 || limit > rekeyConflictPageLimit {
		return fail(400, "bad_request")
	}
	a := identity(r)
	vid := param(r, "vaultID")
	rid := param(r, "rekeyID")
	var total int64
	var candidates []map[string]any
	err = s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, err := loadVault(r.Context(), t, a.UserID, vid, false); err != nil {
			return err
		}
		if _, err := loadRekey(r, t, vid, rid); err != nil {
			return err
		}
		if err = t.QueryRowContext(r.Context(), "SELECT candidate_total FROM rekey_conflict_manifests WHERE rekey_id=? AND vault_id=?", rid, vid).Scan(&total); err != nil {
			return err
		}
		var liveCount int64
		if err = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=?", vid).Scan(&liveCount); err != nil {
			return err
		}
		if liveCount != total || offset > total {
			return fail(409, "rekey_stale")
		}
		rows, err := t.QueryContext(r.Context(), "SELECT c.conflict_id,c.item_uuid,x.candidate_id,x.kind,x.op,x.revision,x.body,x.body_sha256 FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=? ORDER BY c.conflict_id,x.committed_ms,x.candidate_id LIMIT ? OFFSET ?", vid, limit, offset)
		if err != nil {
			return err
		}
		defer rows.Close()
		candidates = make([]map[string]any, 0, limit)
		pageBytes := 0
		for rows.Next() {
			var conflictID, itemUUID, candidateID string
			var kind, op int
			var revision uint64
			var body []byte
			var sha sql.NullString
			if err = rows.Scan(&conflictID, &itemUUID, &candidateID, &kind, &op, &revision, &body, &sha); err != nil {
				rows.Close()
				return err
			}
			candidate := map[string]any{
				"conflictId": conflictID, "itemUuid": itemUUID, "candidateId": candidateID,
				"kind": kind, "revision": revision,
			}
			if op == 1 {
				candidate["op"] = "upsert"
				candidate["bodyB64"] = b64(body)
				candidate["sha256"] = sha.String
			} else if op == 2 {
				candidate["op"] = "delete"
			} else {
				rows.Close()
				return fail(500, "internal_error")
			}
			encoded, err := json.Marshal(candidate)
			if err != nil {
				return err
			}
			candidateBytes := len(encoded)
			if len(candidates) > 0 {
				candidateBytes++
			}
			if pageBytes+candidateBytes+256 > rekeyConflictPageMaximumBytes {
				if len(candidates) == 0 {
					return fail(500, "internal_error")
				}
				break
			}
			pageBytes += candidateBytes
			candidates = append(candidates, candidate)
		}
		if err = rows.Err(); err != nil {
			rows.Close()
			return err
		}
		return nil
	})
	if err != nil {
		return err
	}
	writeJSON(w, 200, map[string]any{
		"totalCandidates": total,
		"offset":          offset,
		"candidates":      candidates,
	})
	return nil
}

// rekeyItem carries replacement ciphertext and its digest; the current row supplies the authoritative record kind.
type rekeyItem struct{ UUID, BodyB64, SHA256 string }

// rekeyDEK carries an attachment key wrapper, not a plaintext data-encryption key.
type rekeyDEK struct {
	UUID, ContentVersion, DekB64 string
}

// rekeyChunk idempotently stages encrypted rows and attachment wrappers, then renews the staging expiry.
func (s *Server) rekeyChunk(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Items    []rekeyItem
		DekWraps []rekeyDEK
	}
	if e := body(w, r, batchJSON, &b); e != nil {
		return e
	}
	if len(b.Items)+len(b.DekWraps) == 0 || int64(len(b.Items)+len(b.DekWraps)) > s.Config.limit("ITEMS_BATCH_MAX") {
		return fail(400, "bad_request")
	}
	a := identity(r)
	vid := param(r, "vaultID")
	rid := param(r, "rekeyID")
	var ni, nd int64
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := loadVault(r.Context(), t, a.UserID, vid, true); e != nil {
			return e
		}
		k, e := loadRekey(r, t, vid, rid)
		if e != nil {
			return e
		}
		for _, item := range b.Items {
			id, e := uuid(item.UUID)
			if e != nil {
				return e
			}
			raw, e := decode64(item.BodyB64)
			if e != nil || len(raw) < 1 || int64(len(raw)) > s.Config.limit("ITEM_BODY_MAX_BYTES") {
				return fail(400, "bad_request")
			}
			sha := digest(raw)
			if !equal(sha, lower(item.SHA256)) {
				return fail(400, "hash_mismatch")
			}
			var kind int
			if e = t.QueryRowContext(r.Context(), "SELECT kind FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, id).Scan(&kind); errors.Is(e, sql.ErrNoRows) {
				return fail(409, "rekey_stale")
			} else if e != nil {
				return e
			}
			if _, e = t.ExecContext(r.Context(), "INSERT INTO rekey_staging(rekey_id,item_uuid,kind,payload,sha256) VALUES(?,?,1,?,?) ON DUPLICATE KEY UPDATE kind=1,payload=VALUES(payload),sha256=VALUES(sha256)", rid, id, raw, sha); e != nil {
				return e
			}
		}
		for _, item := range b.DekWraps {
			id, e := uuid(item.UUID)
			if e != nil {
				return e
			}
			contentVersion, e := uuid(item.ContentVersion)
			if e != nil {
				return e
			}
			raw, e := decode64(item.DekB64)
			if e != nil || len(raw) < 28 || len(raw) > 256 {
				return fail(400, "bad_request")
			}
			var n int
			if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?", vid, id, contentVersion).Scan(&n); e != nil {
				return e
			}
			if n != 1 {
				return fail(409, "rekey_stale")
			}
			if _, e = t.ExecContext(r.Context(), "INSERT INTO rekey_attachment_staging(rekey_id,vault_id,attach_uuid,content_version,dek_wrapped) VALUES(?,?,?,?,?) ON DUPLICATE KEY UPDATE dek_wrapped=VALUES(dek_wrapped)", rid, vid, id, contentVersion, raw); e != nil {
				return e
			}
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekey_staging WHERE rekey_id=? AND kind=1", rid).Scan(&ni); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekey_attachment_staging WHERE rekey_id=?", rid).Scan(&nd); e != nil {
			return e
		}
		if ni > k.Items || nd > k.Deks {
			return fail(400, "bad_request")
		}
		_, e = t.ExecContext(r.Context(), "UPDATE rekeys SET item_staged=?,dek_staged=?,expires_ms=? WHERE rekey_id=?", ni, nd, now()+s.Config.limit("REKEY_TTL_MS"), rid)
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "rekey_chunk", a.UserID, vid, map[string]int64{"items": ni, "deks": nd})
	writeJSON(w, 200, map[string]any{"itemStaged": ni, "dekStaged": nd})
	return nil
}

// rekeyCommit verifies counts and current identities before atomically replacing rows, envelope and password version.
func (s *Server) rekeyCommit(w http.ResponseWriter, r *http.Request) error {
	var b map[string]any
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	a := identity(r)
	vid := param(r, "vaultID")
	rid := param(r, "rekeyID")
	var version int64
	ts := now()
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		k, e := loadRekey(r, t, vid, rid)
		if e != nil {
			return e
		}
		if k.Version != v.Version+1 {
			return fail(409, "rekey_stale")
		}
		var expectedConflicts, stagedConflicts int64
		if e = t.QueryRowContext(r.Context(), "SELECT candidate_total,candidate_staged FROM rekey_conflict_manifests WHERE rekey_id=? AND vault_id=? FOR UPDATE", rid, vid).Scan(&expectedConflicts, &stagedConflicts); e != nil {
			return e
		}
		if stagedConflicts != expectedConflicts {
			return fail(409, "rekey_incomplete")
		}
		if k.ItemStaged != k.Items || k.DekStaged != k.Deks {
			return fail(409, "rekey_incomplete")
		}
		var items, deks, conflicts, matchedItems, matchedDeks, matchedConflicts int64
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=?", vid).Scan(&items); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachment_versions WHERE vault_id=?", vid).Scan(&deks); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=?", vid).Scan(&conflicts); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vault_sync_items i JOIN rekey_staging s ON s.item_uuid=i.item_uuid AND s.rekey_id=? AND s.kind=1 WHERE i.vault_id=?", rid, vid).Scan(&matchedItems); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachment_versions av JOIN rekey_attachment_staging s ON s.vault_id=av.vault_id AND s.attach_uuid=av.attach_uuid AND s.content_version=av.content_version AND s.rekey_id=? WHERE av.vault_id=?", rid, vid).Scan(&matchedDeks); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id JOIN rekey_conflict_staging s ON s.rekey_id=? AND s.conflict_id=c.conflict_id AND s.old_candidate_id=x.candidate_id WHERE c.vault_id=?", rid, vid).Scan(&matchedConflicts); e != nil {
			return e
		}
		if items != k.Items || deks != k.Deks || conflicts != expectedConflicts || matchedItems != items || matchedDeks != deks || matchedConflicts != conflicts {
			return fail(409, "rekey_stale")
		}
		var candidateCollisions int
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekey_conflict_staging a JOIN rekey_conflict_staging b ON a.rekey_id=b.rekey_id AND a.conflict_id=b.conflict_id AND a.new_candidate_id=b.new_candidate_id AND a.old_candidate_id<b.old_candidate_id WHERE a.rekey_id=?", rid).Scan(&candidateCollisions); e != nil {
			return e
		}
		if candidateCollisions > 0 {
			return fail(409, "rekey_candidate_collision")
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekey_conflict_staging s JOIN item_conflict_candidates c ON c.conflict_id=s.conflict_id AND c.candidate_id=s.new_candidate_id WHERE s.rekey_id=? AND c.candidate_id<>s.old_candidate_id", rid).Scan(&candidateCollisions); e != nil {
			return e
		}
		if candidateCollisions > 0 {
			return fail(409, "rekey_candidate_collision")
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE item_conflicts c JOIN rekey_conflict_staging s ON s.rekey_id=? AND s.conflict_id=c.conflict_id AND s.old_candidate_id=c.selected_candidate_id SET c.selected_candidate_id=s.new_candidate_id WHERE c.vault_id=?", rid, vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE item_changes i JOIN rekey_conflict_staging s ON s.rekey_id=? AND s.conflict_id=i.conflict_id AND s.old_candidate_id=i.winner_candidate_id SET i.winner_candidate_id=s.new_candidate_id WHERE i.vault_id=? AND i.winner_candidate_id IS NOT NULL", rid, vid); e != nil {
			return e
		}
		// Update existing card, label and profile rows without changing kind or modification time.
		if _, e = t.ExecContext(r.Context(), "UPDATE vault_items i JOIN rekey_staging s ON s.rekey_id=? AND s.kind=1 AND s.item_uuid=i.item_uuid SET i.revision=i.revision+1,i.body=s.payload,i.body_sha256=s.sha256,i.body_bytes=LENGTH(s.payload),i.updated_ms=? WHERE i.vault_id=?", rid, ts, vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE vault_user_profiles i JOIN rekey_staging s ON s.rekey_id=? AND s.kind=1 AND s.item_uuid=i.item_uuid SET i.revision=i.revision+1,i.body=s.payload,i.body_sha256=s.sha256,i.body_bytes=LENGTH(s.payload),i.updated_ms=? WHERE i.vault_id=?", rid, ts, vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE attachment_versions av JOIN rekey_attachment_staging s ON s.rekey_id=? AND s.vault_id=av.vault_id AND s.attach_uuid=av.attach_uuid AND s.content_version=av.content_version SET av.dek_wrapped=s.dek_wrapped WHERE av.vault_id=?", rid, vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE attachments a JOIN attachment_versions av ON av.vault_id=a.vault_id AND av.attach_uuid=a.attach_uuid AND av.content_version=COALESCE(a.content_version,'00000000-0000-0000-0000-000000000000') SET a.dek_wrapped=av.dek_wrapped WHERE a.vault_id=?", vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE item_conflict_candidates c JOIN rekey_conflict_staging s ON s.rekey_id=? AND s.conflict_id=c.conflict_id AND s.old_candidate_id=c.candidate_id JOIN item_conflicts g ON g.conflict_id=c.conflict_id SET c.candidate_id=s.new_candidate_id,c.candidate_fingerprint=s.candidate_fingerprint,c.body=s.body,c.body_sha256=s.body_sha256 WHERE g.vault_id=?", rid, vid); e != nil {
			return e
		}
		res, e := t.ExecContext(r.Context(), "INSERT INTO item_changes(vault_id,item_uuid,op,revision,session_id,created_ms) VALUES(?,'',3,?,?,?)", vid, k.Version, a.SessionID, ts)
		if e != nil {
			return e
		}
		seq, e := res.LastInsertId()
		if e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE vaults SET envelope_enc=?,envelope_changed_ms=?,password_version=?,password_changed_ms=?,updated_ms=?,head_seq=GREATEST(head_seq,?) WHERE vault_id=?", k.Envelope, ts, k.Version, ts, ts, seq, vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "DELETE FROM rekeys WHERE rekey_id=?", rid); e != nil {
			return e
		}
		version = k.Version
		return nil
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "rekey_commit", a.UserID, vid, map[string]int64{"version": version})
	writeJSON(w, 200, map[string]any{"ok": true, "passwordVersion": version})
	return nil
}

// rekeyAbort removes the pending manifest and staged payloads without changing live ciphertext.
func (s *Server) rekeyAbort(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	vid := param(r, "vaultID")
	rid := param(r, "rekeyID")
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := loadVault(r.Context(), t, a.UserID, vid, true); e != nil {
			return e
		}
		if _, e := loadRekey(r, t, vid, rid); e != nil {
			return e
		}
		_, e := t.ExecContext(r.Context(), "DELETE FROM rekeys WHERE rekey_id=?", rid)
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "rekey_abort", a.UserID, vid, nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}
