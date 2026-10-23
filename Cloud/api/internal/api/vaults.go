package api

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
)

type vault struct {
	ID, UserID, Name                                                    string
	Version, Changed, Head, Floor, Count, AttachBytes, Created, Updated int64
	Envelope                                                            sql.NullString
	EnvelopeChanged                                                     sql.NullInt64
}
type queryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

const vaultColumns = "vault_id,user_id,name,password_version,password_changed_ms,envelope_enc,envelope_changed_ms,head_seq,changes_floor_seq,item_count,attach_bytes,created_ms,updated_ms"

func loadVault(ctx context.Context, q queryer, uid, id string, lock bool) (vault, error) {
	var v vault
	if !idPattern.MatchString(id) {
		return v, fail(404, "not_found")
	}
	sqlText := "SELECT " + vaultColumns + " FROM vaults WHERE vault_id=? AND user_id=?"
	if lock {
		sqlText += " FOR UPDATE"
	}
	e := q.QueryRowContext(ctx, sqlText, id, uid).Scan(&v.ID, &v.UserID, &v.Name, &v.Version, &v.Changed, &v.Envelope, &v.EnvelopeChanged, &v.Head, &v.Floor, &v.Count, &v.AttachBytes, &v.Created, &v.Updated)
	if errors.Is(e, sql.ErrNoRows) {
		e = fail(404, "not_found")
	}
	return v, e
}
func (v vault) meta() map[string]any {
	return map[string]any{"vaultId": v.ID, "name": v.Name, "passwordVersion": v.Version, "passwordChangedAt": v.Changed, "envelopeChangedAt": intOrNil(v.EnvelopeChanged), "hasEnvelope": v.Envelope.Valid, "headSeq": v.Head, "itemCount": v.Count, "attachBytes": v.AttachBytes, "createdAt": v.Created, "updatedAt": v.Updated}
}
func (s *Server) vaultCreate(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Name     string
		Envelope *string
	}
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	name, e := vaultName(b.Name)
	if e != nil {
		return e
	}
	var enc any
	var changed any
	if b.Envelope != nil {
		raw, e := decode64(*b.Envelope)
		if e != nil || !validEnvelope(raw) {
			return fail(400, "invalid_envelope")
		}
		v, e := s.seal(raw)
		if e != nil {
			return e
		}
		enc = v
		changed = now()
	}
	a := identity(r)
	id := randomHex(16)
	ts := now()
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		// User lock serializes quota checks with creates and transfers.
		var uid string
		if e := t.QueryRowContext(r.Context(), "SELECT id FROM users WHERE id=? AND state='active' FOR UPDATE", a.UserID).Scan(&uid); e != nil {
			return e
		}
		var count int64
		if e := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vaults WHERE user_id=?", a.UserID).Scan(&count); e != nil {
			return e
		}
		if count >= s.Config.limit("VAULT_LIMIT_PER_USER") {
			return fail(413, "quota_exceeded")
		}
		_, e := t.ExecContext(r.Context(), "INSERT INTO vaults(vault_id,user_id,name,password_version,password_changed_ms,envelope_enc,envelope_changed_ms,created_ms,updated_ms) VALUES(?,?,?,1,?,?,?,?,?)", id, a.UserID, name, ts, enc, changed, ts, ts)
		if duplicate(e) {
			return fail(409, "name_exists")
		}
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "vault_create", a.UserID, id, nil)
	writeJSON(w, 201, map[string]any{"vaultId": id, "passwordVersion": 1})
	return nil
}
func (s *Server) vaultList(w http.ResponseWriter, r *http.Request) error {
	rows, e := s.DB.QueryContext(r.Context(), "SELECT "+vaultColumns+" FROM vaults WHERE user_id=? ORDER BY created_ms", identity(r).UserID)
	if e != nil {
		return e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var v vault
		if e = rows.Scan(&v.ID, &v.UserID, &v.Name, &v.Version, &v.Changed, &v.Envelope, &v.EnvelopeChanged, &v.Head, &v.Floor, &v.Count, &v.AttachBytes, &v.Created, &v.Updated); e != nil {
			return e
		}
		out = append(out, v.meta())
	}
	if e = rows.Err(); e != nil {
		return e
	}
	writeJSON(w, 200, map[string]any{"vaults": out})
	return nil
}
func (s *Server) vaultGet(w http.ResponseWriter, r *http.Request) error {
	v, e := loadVault(r.Context(), s.DB, identity(r).UserID, param(r, "vaultID"), false)
	if e != nil {
		return e
	}
	raw, e := s.open(v.Envelope)
	if e != nil {
		return e
	}
	out := v.meta()
	out["envelope"] = nil
	if raw != nil {
		out["envelope"] = b64(raw)
	}
	writeJSON(w, 200, out)
	return nil
}
func (s *Server) vaultSeq(w http.ResponseWriter, r *http.Request) error {
	v, e := loadVault(r.Context(), s.DB, identity(r).UserID, param(r, "vaultID"), false)
	if e != nil {
		return e
	}
	writeJSON(w, 200, map[string]any{"headSeq": v.Head, "passwordVersion": v.Version})
	return nil
}
func (s *Server) vaultRename(w http.ResponseWriter, r *http.Request) error {
	var b struct{ Name string }
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	name, e := vaultName(b.Name)
	if e != nil {
		return e
	}
	a := identity(r)
	id := param(r, "vaultID")
	if _, e = loadVault(r.Context(), s.DB, a.UserID, id, false); e != nil {
		return e
	}
	res, e := s.DB.ExecContext(r.Context(), "UPDATE vaults SET name=?,updated_ms=? WHERE vault_id=? AND user_id=?", name, now(), id, a.UserID)
	if duplicate(e) {
		return fail(409, "name_exists")
	}
	if e = requireAffected(res, e); e != nil {
		return e
	}
	s.audit(r.Context(), "vault_rename", a.UserID, id, nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}
func (s *Server) vaultDelete(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	id := param(r, "vaultID")
	if _, e := loadVault(r.Context(), s.DB, a.UserID, id, false); e != nil {
		return e
	}
	var b struct{ Code string }
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	if e := s.sensitive(r, b.Code); e != nil {
		return e
	}
	// Delete objects while retaining the ownership lock; concurrent transfer cannot change the target.
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := loadVault(r.Context(), t, a.UserID, id, true); e != nil {
			return e
		}
		if e := s.deletePrefix(r.Context(), "vaults/"+id+"/attachments/"); e != nil {
			return e
		}
		_, e := t.ExecContext(r.Context(), "DELETE FROM vaults WHERE vault_id=? AND user_id=?", id, a.UserID)
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "vault_registry_delete", a.UserID, id, nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}
func (s *Server) vaultTransfer(w http.ResponseWriter, r *http.Request) error {
	var b struct{ Email, Code, CurrentCode, DeviceName, Platform string }
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	em, e := email(b.Email)
	if e != nil {
		return e
	}
	a := identity(r)
	id := param(r, "vaultID")
	if _, e = loadVault(r.Context(), s.DB, a.UserID, id, false); e != nil {
		return e
	}
	eh := s.mac("email:" + em)
	if eh == a.EmailHMC {
		return fail(400, "invalid_email")
	}
	if e = s.sensitive(r, b.CurrentCode); e != nil {
		return e
	}
	ok, e := s.checkCode(r.Context(), eh, "sensitive", b.Code)
	if e != nil {
		return e
	}
	if !ok {
		return fail(403, "invalid_code")
	}
	target, e := s.getOrCreateUser(r.Context(), em)
	if e != nil {
		return e
	}
	e = s.transaction(r.Context(), func(t *sql.Tx) error {
		var uid string
		if e := t.QueryRowContext(r.Context(), "SELECT id FROM users WHERE id=? AND state='active' FOR UPDATE", target.UserID).Scan(&uid); e != nil {
			return e
		}
		if _, e := loadVault(r.Context(), t, a.UserID, id, true); e != nil {
			return e
		}
		var count int64
		if e := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM vaults WHERE user_id=?", target.UserID).Scan(&count); e != nil {
			return e
		}
		if count >= s.Config.limit("VAULT_LIMIT_PER_USER") {
			return fail(413, "quota_exceeded")
		}
		_, e := t.ExecContext(r.Context(), "UPDATE vaults SET user_id=?,updated_ms=? WHERE vault_id=? AND user_id=?", target.UserID, now(), id, a.UserID)
		if duplicate(e) {
			return fail(409, "name_exists")
		}
		return e
	})
	if e != nil {
		return e
	}
	v, e := s.issueSession(r.Context(), target.UserID, b.DeviceName, b.Platform)
	if e != nil {
		return e
	}
	s.audit(r.Context(), "vault_transfer", a.UserID, id, nil)
	writeJSON(w, 200, v)
	return nil
}
