// 邮箱验证码、账户身份和设备会话；主密码及库密钥不进入本模块。
package api

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"regexp"
	"strings"
)

// authKey is the private request-context key for authenticated identity.
type authKey struct{}

// auth holds validated account and session metadata; it must not carry plaintext credentials.
type auth struct {
	UserID, EmailHMC, SessionID string
	DeviceName, Platform        string
	Created                     int64
}

// identity reads authentication populated by middleware; protected handlers must run behind authenticated.
func identity(r *http.Request) auth { a, _ := r.Context().Value(authKey{}).(auth); return a }

// authenticated validates a Bearer token hash, loads account identity and updates sliding session activity.
func (s *Server) authenticated(next http.Handler) http.Handler {
	return s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		token := r.Header.Get("Authorization")
		if len(token) < 7 || !strings.EqualFold(token[:7], "Bearer ") {
			return fail(401, "unauthorized")
		}
		token = token[7:]
		if !hashPattern.MatchString(token) {
			return fail(401, "unauthorized")
		}
		var a auth
		var expires, last int64
		var revoked sql.NullInt64
		var state string
		e := s.DB.QueryRowContext(r.Context(), "SELECT s.id,s.device_name,s.platform,s.expires_ms,s.revoked_ms,s.last_seen_ms,u.id,u.email_hmc,u.state,u.created_ms FROM sessions s JOIN users u ON u.id=s.user_id WHERE s.token_hash=?", digest([]byte(token))).Scan(&a.SessionID, &a.DeviceName, &a.Platform, &expires, &revoked, &last, &a.UserID, &a.EmailHMC, &state, &a.Created)
		if errors.Is(e, sql.ErrNoRows) {
			return fail(401, "unauthorized")
		}
		if e != nil {
			return e
		}
		if revoked.Valid || expires <= now() || state != "active" {
			return fail(401, "unauthorized")
		}
		if now()-last >= 3600000 {
			if _, e = s.DB.ExecContext(r.Context(), "UPDATE sessions SET last_seen_ms=?,expires_ms=? WHERE id=? AND revoked_ms IS NULL", now(), now()+s.Config.limit("SESSION_TTL_DAYS")*dayMS, a.SessionID); e != nil {
				return e
			}
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), authKey{}, a)))
		return nil
	})
}

// admin requires the separate administrator token before dispatching maintenance or catalog management requests.
func (s *Server) admin(next http.Handler) http.Handler {
	return s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		v := r.Header.Get("X-Admin-Token")
		if v == "" || !equal(v, s.Config.AdminToken) {
			return fail(401, "unauthorized")
		}
		next.ServeHTTP(w, r)
		return nil
	})
}

var codePattern = regexp.MustCompile("^[0-9]{6}$")

// consumeCode serializes expiry, attempt claiming and consumption with resend operations.
func (s *Server) consumeCode(ctx context.Context, t *sql.Tx, eh, purpose, code string) (bool, error) {
	if !codePattern.MatchString(code) {
		return false, nil
	}
	var stored string
	var attempts, expires int64
	var used sql.NullInt64
	e := t.QueryRowContext(ctx, "SELECT code_hash,attempts,expires_ms,used_ms FROM email_codes WHERE email_hmc=? AND purpose=? FOR UPDATE", eh, purpose).Scan(&stored, &attempts, &expires, &used)
	if errors.Is(e, sql.ErrNoRows) {
		return false, nil
	}
	if e != nil {
		return false, e
	}
	if used.Valid || expires <= now() || attempts >= s.Config.limit("CODE_MAX_ATTEMPTS") {
		return false, nil
	}
	valid := equal(stored, s.mac("code:"+eh+":"+code+":"+purpose))
	var spent any
	if valid {
		spent = now()
	}
	_, e = t.ExecContext(ctx, "UPDATE email_codes SET attempts=attempts+1,used_ms=? WHERE email_hmc=? AND purpose=?", spent, eh, purpose)
	return valid, e
}

// checkCode runs code consumption in its own transaction so an accepted code cannot be replayed.
func (s *Server) checkCode(ctx context.Context, eh, purpose, code string) (bool, error) {
	var ok bool
	e := s.transaction(ctx, func(t *sql.Tx) error { var e error; ok, e = s.consumeCode(ctx, t, eh, purpose, code); return e })
	return ok, e
}

// sensitive requires a fresh code for the authenticated account before destructive or account-transfer operations.
func (s *Server) sensitive(r *http.Request, code string) error {
	ok, e := s.checkCode(r.Context(), identity(r).EmailHMC, "sensitive", code)
	if e != nil {
		return e
	}
	if !ok {
		return fail(403, "invalid_code")
	}
	return nil
}

// code issues a purpose-scoped email code under email/IP limits and returns an enumeration-resistant accepted response.
func (s *Server) code(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Email   string
		Purpose string
		Lang    string
	}
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	em, e := email(b.Email)
	if e != nil {
		return e
	}
	purpose := "login"
	if b.Purpose == "sensitive" {
		purpose = b.Purpose
	}
	eh := s.mac("email:" + em)
	ip := s.ip(r)
	n, e := rand.Int(rand.Reader, big.NewInt(1000000))
	if e != nil {
		return e
	}
	code := fmt.Sprintf("%06d", n.Int64())
	ts := now()
	e = s.codeTransaction(r.Context(), eh, ip, func(t *sql.Tx) error {
		var last int64
		e := t.QueryRowContext(r.Context(), "SELECT created_ms FROM email_codes WHERE email_hmc=? AND purpose=? FOR UPDATE", eh, purpose).Scan(&last)
		if e != nil && !errors.Is(e, sql.ErrNoRows) {
			return e
		}
		cool := s.Config.limit("CODE_RESEND_COOLDOWN_SECONDS") * 1000
		if e == nil && ts-last < cool {
			return &apiError{429, "rate_limited", int((cool - (ts - last) + 999) / 1000)}
		}
		var ce, ci int64
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM audit_log WHERE action='code_send' AND detail LIKE ? AND ts_ms>?", "%"+eh+"%", ts-3600000).Scan(&ce); e != nil {
			return e
		}
		iph := s.mac("ip:" + ip)
		if e = t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM audit_log WHERE action='code_send' AND detail LIKE ? AND ts_ms>?", "%"+iph+"%", ts-3600000).Scan(&ci); e != nil {
			return e
		}
		if ce >= s.Config.limit("CODE_HOURLY_PER_EMAIL") || ci >= s.Config.limit("CODE_HOURLY_PER_IP") {
			return &apiError{429, "rate_limited", 3600}
		}
		_, e = t.ExecContext(r.Context(), "INSERT INTO email_codes(email_hmc,purpose,code_hash,ip,expires_ms,attempts,used_ms,created_ms) VALUES(?,?,?,?,?,0,NULL,?) ON DUPLICATE KEY UPDATE code_hash=VALUES(code_hash),ip=VALUES(ip),expires_ms=VALUES(expires_ms),attempts=0,used_ms=NULL,created_ms=VALUES(created_ms)", eh, purpose, s.mac("code:"+eh+":"+code+":"+purpose), ip, ts+s.Config.limit("CODE_TTL_SECONDS")*1000, ts)
		if e != nil {
			return e
		}
		_, e = t.ExecContext(r.Context(), "INSERT INTO audit_log(action,detail,ts_ms) VALUES('code_send',?,?)", fmt.Sprintf("emailHmc=%s ipHmc=%s purpose=%s", eh, iph, purpose), ts)
		return e
	})
	if e != nil {
		return e
	}
	mailPurpose := purpose
	if purpose == "login" {
		var users int
		if e = s.DB.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM users WHERE email_hmc=? AND state='active'", eh).Scan(&users); e != nil {
			return e
		}
		if users == 0 {
			mailPurpose = "register"
		}
	}
	if e = s.Mailer.Send(r.Context(), em, code, mailPurpose, strings.HasPrefix(strings.ToLower(b.Lang), "zh")); e != nil {
		s.Log.Error("verification mail delivery failed", "kind", fmt.Sprintf("%T", e))
	}
	writeJSON(w, 202, map[string]bool{"ok": true})
	return nil
}

// getOrCreateUser resolves the keyed email identity and creates an account with application-encrypted email when absent.
func (s *Server) getOrCreateUser(ctx context.Context, em string) (auth, error) {
	eh := s.mac("email:" + em)
	var a auth
	var state string
	a.EmailHMC = eh
	e := s.DB.QueryRowContext(ctx, "SELECT id,state,created_ms FROM users WHERE email_hmc=?", eh).Scan(&a.UserID, &state, &a.Created)
	if e == nil && state == "active" {
		return a, nil
	}
	if e != nil && !errors.Is(e, sql.ErrNoRows) {
		return a, e
	}
	if e == nil {
		if e = s.purgeUser(ctx, a.UserID, eh); e != nil {
			return a, e
		}
	}
	a.UserID = randomHex(16)
	a.Created = now()
	sealed, e := s.seal([]byte(em))
	if e != nil {
		return a, e
	}
	_, e = s.DB.ExecContext(ctx, "INSERT INTO users(id,email_hmc,email_enc,state,plan,created_ms,last_login_ms) VALUES(?,?,?,'active','normal',?,?)", a.UserID, eh, sealed, a.Created, a.Created)
	if duplicate(e) {
		e = s.DB.QueryRowContext(ctx, "SELECT id,created_ms FROM users WHERE email_hmc=? AND state='active'", eh).Scan(&a.UserID, &a.Created)
	}
	return a, e
}

// issueSession creates a random Bearer token, persists only its hash and returns the plaintext token once.
func (s *Server) issueSession(ctx context.Context, uid, name, plat string) (map[string]any, error) {
	token := randomHex(32)
	ts := now()
	exp := ts + s.Config.limit("SESSION_TTL_DAYS")*dayMS
	_, e := s.DB.ExecContext(ctx, "INSERT INTO sessions(id,user_id,token_hash,device_name,platform,created_ms,last_seen_ms,expires_ms) VALUES(?,?,?,?,?,?,?,?)", randomHex(16), uid, digest([]byte(token)), deviceName(name), platform(plat), ts, ts, exp)
	return map[string]any{"token": token, "expiresAt": exp, "userId": uid}, e
}

// verify consumes a login code, resolves the account and issues a device session.
func (s *Server) verify(w http.ResponseWriter, r *http.Request) error {
	var b struct{ Email, Code, DeviceName, Platform string }
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	em, e := email(b.Email)
	if e != nil {
		return e
	}
	ok, e := s.checkCode(r.Context(), s.mac("email:"+em), "login", b.Code)
	if e != nil {
		return e
	}
	if !ok {
		return fail(400, "invalid_code")
	}
	a, e := s.getOrCreateUser(r.Context(), em)
	if e != nil {
		return e
	}
	if _, e = s.DB.ExecContext(r.Context(), "UPDATE users SET last_login_ms=? WHERE id=?", now(), a.UserID); e != nil {
		return e
	}
	v, e := s.issueSession(r.Context(), a.UserID, b.DeviceName, b.Platform)
	if e != nil {
		return e
	}
	v["createdAt"] = a.Created
	s.audit(r.Context(), "login", a.UserID, "", nil)
	writeJSON(w, 200, v)
	return nil
}

// sessions lists authenticated account sessions without returning token hashes or plaintext tokens.
func (s *Server) sessions(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	rows, e := s.DB.QueryContext(r.Context(), "SELECT id,device_name,platform,created_ms,last_seen_ms,expires_ms FROM sessions WHERE user_id=? AND revoked_ms IS NULL ORDER BY last_seen_ms DESC", a.UserID)
	if e != nil {
		return e
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var id, name, plat string
		var c, l, x int64
		if e = rows.Scan(&id, &name, &plat, &c, &l, &x); e != nil {
			return e
		}
		out = append(out, map[string]any{"id": id, "deviceName": name, "platform": plat, "createdAt": c, "lastSeenAt": l, "expiresAt": x, "current": id == a.SessionID})
	}
	if e = rows.Err(); e != nil {
		return e
	}
	writeJSON(w, 200, map[string]any{"sessions": out})
	return nil
}

// renameSession changes only the authenticated session device display name.
func (s *Server) renameSession(w http.ResponseWriter, r *http.Request) error {
	var b struct{ DeviceName string }
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	name := deviceName(b.DeviceName)
	if name == "" {
		return fail(400, "invalid_name")
	}
	a := identity(r)
	if _, e := s.DB.ExecContext(r.Context(), "UPDATE sessions SET device_name=? WHERE id=? AND user_id=? AND revoked_ms IS NULL", name, a.SessionID, a.UserID); e != nil {
		return e
	}
	s.audit(r.Context(), "session_rename", a.UserID, "", nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}

// revokeSession revokes the requested account-owned session, or the current session when no ID is supplied.
func (s *Server) revokeSession(w http.ResponseWriter, r *http.Request) error {
	a := identity(r)
	id := param(r, "sessionID")
	if id == "" {
		id = a.SessionID
	}
	if !idPattern.MatchString(id) {
		return fail(404, "not_found")
	}
	res, e := s.DB.ExecContext(r.Context(), "UPDATE sessions SET revoked_ms=? WHERE id=? AND user_id=? AND revoked_ms IS NULL", now(), id, a.UserID)
	if e = requireAffected(res, e); e != nil {
		return e
	}
	s.audit(r.Context(), "session_revoke", a.UserID, "", nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}

// deleteUserObjects deletes encrypted attachment prefixes for all vaults owned by the account.
func (s *Server) deleteUserObjects(ctx context.Context, uid string) error {
	rows, e := s.DB.QueryContext(ctx, "SELECT vault_id FROM vaults WHERE user_id=?", uid)
	if e != nil {
		return e
	}
	ids := []string{}
	for rows.Next() {
		var id string
		if e = rows.Scan(&id); e != nil {
			rows.Close()
			return e
		}
		ids = append(ids, id)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, id := range ids {
		if e = s.deletePrefix(ctx, "vaults/"+id+"/attachments/"); e != nil {
			return e
		}
	}
	return nil
}

// purgeUser clears account object storage before deleting account rows and recording a metadata-only audit action.
func (s *Server) purgeUser(ctx context.Context, uid, eh string) error {
	if e := s.deleteUserObjects(ctx, uid); e != nil {
		return e
	}
	if _, e := s.DB.ExecContext(ctx, "DELETE FROM users WHERE id=?", uid); e != nil {
		return e
	}
	_, e := s.DB.ExecContext(ctx, "DELETE FROM email_codes WHERE email_hmc=?", eh)
	return e
}

// deregister requires a sensitive code and removes account data and sessions.
func (s *Server) deregister(w http.ResponseWriter, r *http.Request) error {
	var b struct{ Code string }
	if e := body(w, r, smallJSON, &b); e != nil {
		return e
	}
	if e := s.sensitive(r, b.Code); e != nil {
		return e
	}
	a := identity(r)
	ts := now()
	if _, e := s.DB.ExecContext(r.Context(), "UPDATE sessions SET revoked_ms=? WHERE user_id=? AND revoked_ms IS NULL", ts, a.UserID); e != nil {
		return e
	}
	if e := s.deleteUserObjects(r.Context(), a.UserID); e != nil {
		return e
	}
	e := s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, e := t.ExecContext(r.Context(), "DELETE FROM vaults WHERE user_id=?", a.UserID); e != nil {
			return e
		}
		_, e := t.ExecContext(r.Context(), "UPDATE users SET state='deregistered',email_enc=NULL,deregistered_at_ms=? WHERE id=?", ts, a.UserID)
		return e
	})
	if e != nil {
		return e
	}
	s.audit(r.Context(), "account_deregister", a.UserID, "", nil)
	writeJSON(w, 200, map[string]bool{"ok": true})
	return nil
}
