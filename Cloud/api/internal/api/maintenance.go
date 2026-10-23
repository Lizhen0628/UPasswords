package api

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"time"
)

func (s *Server) stats(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	var active, deregistered, normal, subscription, permanent, total, active365, items, attach, sessions, codes, changes, sites int64
	queries := []struct {
		q    string
		args []any
		dest []any
	}{
		{"SELECT COALESCE(SUM(state='active'),0),COALESCE(SUM(state='deregistered'),0) FROM users", nil, []any{&active, &deregistered}},
		{"SELECT COALESCE(SUM(plan='normal'),0),COALESCE(SUM(plan='subscription'),0),COALESCE(SUM(plan='permanent'),0) FROM users WHERE state='active'", nil, []any{&normal, &subscription, &permanent}},
		{"SELECT COUNT(*),COALESCE(SUM(updated_ms>?),0),COALESCE(SUM(item_count),0),COALESCE(SUM(attach_bytes),0) FROM vaults", []any{now() - 365*dayMS}, []any{&total, &active365, &items, &attach}},
		{"SELECT COUNT(*) FROM sessions WHERE revoked_ms IS NULL AND expires_ms>?", []any{now()}, []any{&sessions}},
		{"SELECT COUNT(*) FROM email_codes WHERE created_ms>?", []any{now() - dayMS}, []any{&codes}},
		{"SELECT COUNT(*) FROM item_changes WHERE created_ms>?", []any{now() - dayMS}, []any{&changes}},
		{"SELECT COUNT(*) FROM websites WHERE status=1", nil, []any{&sites}},
	}
	for _, q := range queries {
		if e := s.DB.QueryRowContext(ctx, q.q, q.args...).Scan(q.dest...); e != nil {
			return e
		}
	}
	writeJSON(w, 200, map[string]any{"users": map[string]any{"active": active, "deregistered": deregistered, "plans": map[string]int64{"normal": normal, "subscription": subscription, "permanent": permanent}}, "vaults": map[string]int64{"total": total, "active365d": active365, "items": items, "attachBytes": attach}, "sessions": sessions, "codes24h": codes, "itemChanges24h": changes, "sites": sites})
	return nil
}

// Maintain runs the daily job once. A dedicated connection holds the replica-wide lock.
func (s *Server) Maintain(ctx context.Context) error {
	started := time.Now()
	s.Log.Info("maintenance started")
	defer func() { s.Log.Info("maintenance finished", "elapsedMs", time.Since(started).Milliseconds()) }()
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return e
	}
	defer conn.Close()
	var got int
	if e = conn.QueryRowContext(ctx, "SELECT GET_LOCK('upw-maintenance',0)").Scan(&got); e != nil {
		return e
	}
	if got != 1 {
		s.Log.Info("maintenance already running")
		return nil
	}
	defer func() {
		var released int
		if e := conn.QueryRowContext(context.Background(), "SELECT RELEASE_LOCK('upw-maintenance')").Scan(&released); e != nil {
			s.Log.Warn("maintenance lock release failed")
		}
	}()
	rows, e := s.DB.QueryContext(ctx, "SELECT id,email_hmc FROM users WHERE state='deregistered' AND deregistered_at_ms<?", now()-s.Config.limit("DEREGISTER_PURGE_DAYS")*dayMS)
	if e != nil {
		return e
	}
	type u struct{ id, eh string }
	users := []u{}
	for rows.Next() {
		var x u
		if e = rows.Scan(&x.id, &x.eh); e != nil {
			rows.Close()
			return e
		}
		users = append(users, x)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, u := range users {
		if e = s.purgeUser(ctx, u.id, u.eh); e != nil {
			return e
		}
	}
	cutoff := now() - s.Config.limit("CHANGE_RETENTION_DAYS")*dayMS
	e = s.transaction(ctx, func(t *sql.Tx) error {
		if _, e := t.ExecContext(ctx, "UPDATE vaults v JOIN (SELECT vault_id,MAX(seq) AS m FROM item_changes WHERE created_ms<? GROUP BY vault_id) c ON c.vault_id=v.vault_id SET v.changes_floor_seq=GREATEST(v.changes_floor_seq,c.m)", cutoff); e != nil {
			return e
		}
		_, e := t.ExecContext(ctx, "DELETE FROM item_changes WHERE created_ms<?", cutoff)
		return e
	})
	if e != nil {
		return e
	}
	// Lock each vault during orphan reconciliation so commits cannot race deletion decisions.
	rows, e = s.DB.QueryContext(ctx, "SELECT vault_id,user_id FROM vaults")
	if e != nil {
		return e
	}
	type v struct{ id, uid string }
	vaults := []v{}
	for rows.Next() {
		var x v
		if e = rows.Scan(&x.id, &x.uid); e != nil {
			rows.Close()
			return e
		}
		vaults = append(vaults, x)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, v := range vaults {
		e = s.transaction(ctx, func(t *sql.Tx) error {
			if _, e := loadVault(ctx, t, v.uid, v.id, true); e != nil {
				var a *apiError
				if errors.As(e, &a) && a.Status == 404 {
					return nil
				}
				return e
			}
			// Rows are removed first; immutable blobs receive a full-day grace before sweeping.
			if _, e := t.ExecContext(ctx, "DELETE a FROM attachments a LEFT JOIN vault_items i ON i.vault_id=a.vault_id AND i.item_uuid=a.card_uuid WHERE a.vault_id=? AND i.item_uuid IS NULL AND a.created_ms<?", v.id, now()-7*dayMS); e != nil {
				return e
			}
			known := map[string]bool{}
			rs, e := t.QueryContext(ctx, "SELECT object_key FROM attachments WHERE vault_id=?", v.id)
			if e != nil {
				return e
			}
			for rs.Next() {
				var key string
				if e = rs.Scan(&key); e != nil {
					rs.Close()
					return e
				}
				known[key] = true
			}
			e = rs.Err()
			rs.Close()
			if e != nil {
				return e
			}
			cursor := ""
			for {
				objects, next, e := s.Objects.List(ctx, attachPrefix(v.id), cursor)
				if e != nil {
					return e
				}
				for _, o := range objects {
					if !known[o.Key] && o.Modified.UnixMilli() < now()-dayMS {
						if e = s.Objects.Delete(ctx, o.Key); e != nil {
							return e
						}
					}
				}
				if next == "" {
					break
				}
				if next == cursor {
					return errors.New("object listing made no progress")
				}
				cursor = next
			}
			_, e = t.ExecContext(ctx, "UPDATE vaults v SET item_count=(SELECT COUNT(*) FROM vault_items i WHERE i.vault_id=v.vault_id),attach_bytes=(SELECT COALESCE(SUM(bytes),0) FROM attachments a WHERE a.vault_id=v.vault_id) WHERE v.vault_id=?", v.id)
			return e
		})
		if e != nil {
			return e
		}
	}
	for _, q := range []struct {
		sql string
		arg int64
	}{{"DELETE FROM rekeys WHERE expires_ms<?", now()}, {"DELETE FROM email_codes WHERE expires_ms<?", now() - dayMS}, {"DELETE FROM audit_log WHERE ts_ms<?", now() - 180*dayMS}} {
		if _, e = s.DB.ExecContext(ctx, q.sql, q.arg); e != nil {
			return e
		}
	}
	// Deleted-vault objects and obsolete v6 keys also get a grace period; never sweep fresh uploads.
	cursor := ""
	for {
		objects, next, e := s.Objects.List(ctx, "vaults/", cursor)
		if e != nil {
			return e
		}
		for _, o := range objects {
			if o.Modified.UnixMilli() >= now()-dayMS {
				continue
			}
			parts := strings.Split(o.Key, "/")
			if len(parts) < 2 {
				continue
			}
			var n int
			if e = s.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM vaults WHERE vault_id=?", parts[1]).Scan(&n); e != nil {
				return e
			}
			if n == 0 || len(parts) == 2 {
				if e = s.Objects.Delete(ctx, o.Key); e != nil {
					return e
				}
			}
		}
		if next == "" {
			break
		}
		if next == cursor {
			return errors.New("object listing made no progress")
		}
		cursor = next
	}
	return nil
}
