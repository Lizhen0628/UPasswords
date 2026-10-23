package api

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"
	"strings"
)

type incomingItem struct {
	UUID         string  `json:"uuid"`
	Kind         int     `json:"kind"`
	Op           string  `json:"op"`
	BaseRevision *int64  `json:"baseRevision"`
	BodyB64      string  `json:"bodyB64"`
	SHA256       *string `json:"sha256"`
	ModifiedMS   *int64  `json:"modifiedMs"`
	Body         []byte  `json:"-"`
}
type itemRow struct {
	UUID              string
	Kind              int
	Revision          int64
	Body              []byte
	SHA               string
	Modified, Updated int64
}

func (i itemRow) wire() map[string]any {
	return map[string]any{"uuid": i.UUID, "kind": i.Kind, "revision": i.Revision, "bodyB64": b64(i.Body), "sha256": i.SHA, "modifiedMs": i.Modified}
}
func (s *Server) itemsPost(w http.ResponseWriter, r *http.Request) error {
	var b struct{ Items []incomingItem }
	if e := body(w, r, batchJSON, &b); e != nil {
		return e
	}
	if len(b.Items) == 0 {
		return fail(400, "bad_request")
	}
	if int64(len(b.Items)) > s.Config.limit("ITEMS_BATCH_MAX") {
		return fail(413, "too_many_items")
	}
	seen := map[string]bool{}
	for i := range b.Items {
		v := &b.Items[i]
		id, e := uuid(v.UUID)
		if e != nil {
			return e
		}
		v.UUID = id
		if seen[id] {
			return fail(400, "duplicate_uuid")
		}
		seen[id] = true
		if (v.Kind != 1 && v.Kind != 2) || (v.Op != "upsert" && v.Op != "delete") || v.BaseRevision == nil || *v.BaseRevision < 0 || v.ModifiedMS == nil || *v.ModifiedMS < 0 || *v.BaseRevision >= 9007199254740991 || *v.ModifiedMS > 9007199254740991 {
			return fail(400, "bad_request")
		}
		if v.Op == "upsert" {
			raw, e := decode64(v.BodyB64)
			if e != nil || len(raw) == 0 {
				return fail(400, "bad_request")
			}
			if int64(len(raw)) > s.Config.limit("ITEM_BODY_MAX_BYTES") {
				return fail(413, "item_too_large")
			}
			v.Body = raw
			sha := digest(raw)
			if v.SHA256 != nil && (!hashPattern.MatchString(*v.SHA256) || strings.ToLower(*v.SHA256) != sha) {
				return fail(400, "hash_mismatch")
			}
			v.SHA256 = &sha
		} else if v.SHA256 != nil {
			return fail(400, "bad_request")
		}
	}
	a := identity(r)
	vid := param(r, "vaultID")
	out := []map[string]any{}
	purged := []string{}
	ts := now()
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		v, e := loadVault(r.Context(), t, a.UserID, vid, true)
		if e != nil {
			return e
		}
		if e = s.noRekey(r, t, vid); e != nil {
			return e
		}
		for _, i := range b.Items {
			result := map[string]any{"uuid": i.UUID}
			var rev int64
			var current []byte
			e := t.QueryRowContext(r.Context(), "SELECT revision,body FROM vault_items WHERE vault_id=? AND item_uuid=?", vid, i.UUID).Scan(&rev, &current)
			exists := e == nil
			if e != nil && !errors.Is(e, sql.ErrNoRows) {
				return e
			}
			if exists && rev != *i.BaseRevision {
				result["status"] = "conflict"
				result["current"] = map[string]any{"revision": rev, "bodyB64": b64(current)}
				out = append(out, result)
				continue
			}
			if !exists && i.Op == "upsert" && *i.BaseRevision > 0 {
				result["status"] = "not_found"
				var deleted, seq int64
				e = t.QueryRowContext(r.Context(), "SELECT created_ms,seq FROM item_changes WHERE vault_id=? AND item_uuid=? AND op=2 ORDER BY seq DESC LIMIT 1", vid, i.UUID).Scan(&deleted, &seq)
				if e == nil {
					result["deletedAt"] = deleted
					result["seq"] = seq
				} else if !errors.Is(e, sql.ErrNoRows) {
					return e
				}
				out = append(out, result)
				continue
			}
			if !exists && i.Op == "delete" {
				result["status"] = "ok"
				out = append(out, result)
				continue
			}
			op := 1
			newRev := rev + 1
			if i.Op == "upsert" {
				if !exists {
					v.Count++
					if v.Count > s.Config.limit("ITEMS_PER_VAULT_LIMIT") {
						return fail(413, "quota_exceeded")
					}
					_, e = t.ExecContext(r.Context(), "INSERT INTO vault_items(vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,created_ms,updated_ms) VALUES(?,?,?,?,?,?,?,?,?,?)", vid, i.UUID, i.Kind, newRev, i.Body, *i.SHA256, len(i.Body), *i.ModifiedMS, ts, ts)
				} else {
					_, e = t.ExecContext(r.Context(), "UPDATE vault_items SET kind=?,revision=?,body=?,body_sha256=?,body_bytes=?,modified_ms=?,updated_ms=? WHERE vault_id=? AND item_uuid=?", i.Kind, newRev, i.Body, *i.SHA256, len(i.Body), *i.ModifiedMS, ts, vid, i.UUID)
				}
				if e != nil {
					return e
				}
				result["revision"] = newRev
			} else {
				op = 2
				rows, e := t.QueryContext(r.Context(), "SELECT object_key,bytes FROM attachments WHERE vault_id=? AND card_uuid=?", vid, i.UUID)
				if e != nil {
					return e
				}
				for rows.Next() {
					var key string
					var size int64
					if e = rows.Scan(&key, &size); e != nil {
						rows.Close()
						return e
					}
					purged = append(purged, key)
					v.AttachBytes -= size
				}
				e = rows.Err()
				rows.Close()
				if e != nil {
					return e
				}
				if _, e = t.ExecContext(r.Context(), "DELETE FROM attachments WHERE vault_id=? AND card_uuid=?", vid, i.UUID); e != nil {
					return e
				}
				if _, e = t.ExecContext(r.Context(), "DELETE FROM vault_items WHERE vault_id=? AND item_uuid=?", vid, i.UUID); e != nil {
					return e
				}
				v.Count--
			}
			res, e := t.ExecContext(r.Context(), "INSERT INTO item_changes(vault_id,item_uuid,op,revision,session_id,created_ms) VALUES(?,?,?,?,?,?)", vid, i.UUID, op, newRev, a.SessionID, ts)
			if e != nil {
				return e
			}
			seq, e := res.LastInsertId()
			if e != nil {
				return e
			}
			if seq > v.Head {
				v.Head = seq
			}
			result["status"] = "ok"
			out = append(out, result)
		}
		_, e = t.ExecContext(r.Context(), "UPDATE vaults SET item_count=?,attach_bytes=?,head_seq=?,updated_ms=? WHERE vault_id=?", v.Count, v.AttachBytes, v.Head, ts, vid)
		return e
	})
	if e != nil {
		return e
	}
	for _, key := range purged {
		if e = s.Objects.Delete(r.Context(), key); e != nil {
			s.Log.Warn("attachment cleanup deferred")
		}
	}
	s.audit(r.Context(), "items_post", a.UserID, vid, map[string]int{"n": len(b.Items)})
	writeJSON(w, 200, map[string]any{"results": out})
	return nil
}
func (s *Server) noRekey(r *http.Request, t *sql.Tx, vid string) error {
	if _, e := t.ExecContext(r.Context(), "DELETE FROM rekeys WHERE vault_id=? AND expires_ms<?", vid, now()); e != nil {
		return e
	}
	var n int
	if e := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekeys WHERE vault_id=?", vid).Scan(&n); e != nil {
		return e
	}
	if n > 0 {
		return fail(409, "rekey_in_progress")
	}
	return nil
}
func uintQuery(r *http.Request, key string, def int64) (int64, error) {
	raw := r.URL.Query().Get(key)
	if raw == "" {
		return def, nil
	}
	if strings.HasPrefix(raw, "+") || strings.HasPrefix(raw, "-") {
		return 0, fail(400, "bad_request")
	}
	n, e := strconv.ParseInt(raw, 10, 64)
	if e != nil || n < 0 || n > 9007199254740991 {
		return 0, fail(400, "bad_request")
	}
	return n, nil
}
func (s *Server) itemsList(w http.ResponseWriter, r *http.Request) error {
	v, e := loadVault(r.Context(), s.DB, identity(r).UserID, param(r, "vaultID"), false)
	if e != nil {
		return e
	}
	ms, e := uintQuery(r, "cursorMs", 0)
	if e != nil {
		return e
	}
	limit, e := uintQuery(r, "limit", 500)
	if e != nil || limit == 0 {
		return fail(400, "bad_request")
	}
	if limit > 500 {
		limit = 500
	}
	cursor := r.URL.Query().Get("cursorUuid")
	if cursor != "" {
		cursor, e = uuid(cursor)
		if e != nil {
			return e
		}
	}
	rows, e := s.DB.QueryContext(r.Context(), "SELECT item_uuid,kind,revision,body,body_sha256,modified_ms,updated_ms FROM vault_items WHERE vault_id=? AND (updated_ms>? OR(updated_ms=? AND item_uuid>?)) ORDER BY updated_ms,item_uuid LIMIT ?", v.ID, ms, ms, cursor, limit)
	if e != nil {
		return e
	}
	defer rows.Close()
	out := []map[string]any{}
	var last itemRow
	for rows.Next() {
		var i itemRow
		if e = rows.Scan(&i.UUID, &i.Kind, &i.Revision, &i.Body, &i.SHA, &i.Modified, &i.Updated); e != nil {
			return e
		}
		out = append(out, i.wire())
		last = i
	}
	if e = rows.Err(); e != nil {
		return e
	}
	var next any
	if int64(len(out)) == limit {
		next = map[string]any{"ms": last.Updated, "uuid": last.UUID}
	}
	writeJSON(w, 200, map[string]any{"items": out, "nextCursor": next, "headSeq": v.Head})
	return nil
}
func (s *Server) changes(w http.ResponseWriter, r *http.Request) error {
	v, e := loadVault(r.Context(), s.DB, identity(r).UserID, param(r, "vaultID"), false)
	if e != nil {
		return e
	}
	since, e := uintQuery(r, "since", -1)
	if e != nil || since < 0 {
		return fail(400, "bad_request")
	}
	limit, e := uintQuery(r, "limit", 200)
	if e != nil || limit == 0 {
		return fail(400, "bad_request")
	}
	if limit > 500 {
		limit = 500
	}
	if since < v.Floor {
		return fail(410, "cursor_expired")
	}
	// The event and live row are read in one statement to avoid mixed snapshots.
	rows, e := s.DB.QueryContext(r.Context(), "SELECT c.seq,c.item_uuid,c.op,c.revision,i.kind,i.revision,i.body,i.body_sha256,i.modified_ms FROM item_changes c LEFT JOIN vault_items i ON i.vault_id=c.vault_id AND i.item_uuid=c.item_uuid WHERE c.vault_id=? AND c.seq>? ORDER BY c.seq LIMIT ?", v.ID, since, limit)
	if e != nil {
		return e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var seq, rev int64
		var id string
		var op int
		var kind, liveRev, modified sql.NullInt64
		var data []byte
		var sha sql.NullString
		if e = rows.Scan(&seq, &id, &op, &rev, &kind, &liveRev, &data, &sha, &modified); e != nil {
			return e
		}
		opName := "upsert"
		if op == 2 {
			opName = "purge"
		} else if op == 3 {
			opName = "rekey"
		}
		c := map[string]any{"seq": seq, "uuid": id, "op": opName, "revision": rev}
		if op == 1 && liveRev.Valid {
			c["revision"] = liveRev.Int64
			c["bodyB64"] = b64(data)
			c["sha256"] = sha.String
			c["kind"] = kind.Int64
			c["modifiedMs"] = modified.Int64
		} else if op != 3 {
			c["deleted"] = true
		}
		out = append(out, c)
	}
	if e = rows.Err(); e != nil {
		return e
	}
	writeJSON(w, 200, map[string]any{"headSeq": v.Head, "changes": out})
	return nil
}
