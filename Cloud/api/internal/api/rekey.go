// 库密钥轮换的暂存会话、分块与事务提交；普通写入在轮换期间拒绝。
package api

import (
	"database/sql"
	"errors"
	"net/http"
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
	var version int64
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		if e = s.noRekey(r, t, vid); e != nil {
			return e
		}
		version = v.Version + 1
		_, e = t.ExecContext(r.Context(), "INSERT INTO rekeys(rekey_id,vault_id,new_envelope_enc,new_password_version,item_total,dek_total,item_staged,dek_staged,expires_ms,created_ms) VALUES(?,?,?,?,?,?,0,0,?,?)", rid, vid, enc, version, *b.ItemCount, *b.DekCount, expires, now())
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "rekey_begin", a.UserID, vid, nil)
	writeJSON(w, 201, map[string]any{"rekeyId": rid, "expiresAt": expires, "passwordVersion": version})
	return nil
}

// rekeyItem carries replacement ciphertext and its digest; the current row supplies the authoritative record kind.
type rekeyItem struct{ UUID, BodyB64, SHA256 string }

// rekeyDEK carries an attachment key wrapper, not a plaintext data-encryption key.
type rekeyDEK struct{ UUID, DekB64 string }

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
			if e = t.QueryRowContext(r.Context(), "SELECT kind FROM vault_items WHERE vault_id=? AND item_uuid=?", vid, id).Scan(&kind); errors.Is(e, sql.ErrNoRows) {
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
			raw, e := decode64(item.DekB64)
			if e != nil || len(raw) < 28 || len(raw) > 256 {
				return fail(400, "bad_request")
			}
			var n int
			if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, id).Scan(&n); e != nil {
				return e
			}
			if n != 1 {
				return fail(409, "rekey_stale")
			}
			if _, e = t.ExecContext(r.Context(), "INSERT INTO rekey_staging(rekey_id,item_uuid,kind,payload,sha256) VALUES(?,?,2,?,?) ON DUPLICATE KEY UPDATE kind=2,payload=VALUES(payload),sha256=VALUES(sha256)", rid, id, raw, digest(raw)); e != nil {
				return e
			}
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COALESCE(SUM(kind=1),0),COALESCE(SUM(kind=2),0) FROM rekey_staging WHERE rekey_id=?", rid).Scan(&ni, &nd); e != nil {
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
		if k.ItemStaged != k.Items || k.DekStaged != k.Deks {
			return fail(409, "rekey_incomplete")
		}
		var items, deks, matchedItems, matchedDeks int64
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vault_items WHERE vault_id=?", vid).Scan(&items); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachments WHERE vault_id=?", vid).Scan(&deks); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vault_items i JOIN rekey_staging s ON s.item_uuid=i.item_uuid AND s.rekey_id=? AND s.kind=1 WHERE i.vault_id=?", rid, vid).Scan(&matchedItems); e != nil {
			return e
		}
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM attachments a JOIN rekey_staging s ON s.item_uuid=a.attach_uuid AND s.rekey_id=? AND s.kind=2 WHERE a.vault_id=?", rid, vid).Scan(&matchedDeks); e != nil {
			return e
		}
		if items != k.Items || deks != k.Deks || matchedItems != items || matchedDeks != deks {
			return fail(409, "rekey_stale")
		}
		// Update only existing rows, preserving card/label kind and modification timestamps.
		if _, e = t.ExecContext(r.Context(), "UPDATE vault_items i JOIN rekey_staging s ON s.rekey_id=? AND s.kind=1 AND s.item_uuid=i.item_uuid SET i.revision=i.revision+1,i.body=s.payload,i.body_sha256=s.sha256,i.body_bytes=LENGTH(s.payload),i.updated_ms=? WHERE i.vault_id=?", rid, ts, vid); e != nil {
			return e
		}
		if _, e = t.ExecContext(r.Context(), "UPDATE attachments a JOIN rekey_staging s ON s.rekey_id=? AND s.kind=2 AND s.item_uuid=a.attach_uuid SET a.dek_wrapped=s.payload WHERE a.vault_id=?", rid, vid); e != nil {
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
