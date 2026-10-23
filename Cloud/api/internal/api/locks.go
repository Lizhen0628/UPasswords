package api

import (
	"context"
	"database/sql"
	"database/sql/driver"

	"sort"
	"time"
)

// codeTransaction keeps named locks through commit and releases them on their owning connection.
func (s *Server) codeTransaction(ctx context.Context, eh, ip string, fn func(*sql.Tx) error) error {
	conn, e := s.DB.Conn(ctx)
	if e != nil {
		return e
	}
	defer conn.Close()
	keys := []string{"code-email:" + digest([]byte(eh))[:48], "code-ip:" + digest([]byte(ip))[:48]}
	sort.Strings(keys)
	held := []string{}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		for _, key := range held {
			var released sql.NullInt64
			if e := conn.QueryRowContext(cleanup, "SELECT RELEASE_LOCK(?)", key).Scan(&released); e != nil || !released.Valid || released.Int64 != 1 {
				s.Log.Error("code lock cleanup failed")
				conn.Raw(func(any) error { return driver.ErrBadConn })
			}
		}
	}()
	for _, key := range keys {
		var got int
		if e = conn.QueryRowContext(ctx, "SELECT GET_LOCK(?,5)", key).Scan(&got); e != nil {
			return e
		}
		if got != 1 {
			return &apiError{429, "rate_limited", 5}
		}
		held = append(held, key)
	}
	t, e := conn.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer t.Rollback()
	if e = fn(t); e != nil {
		return e
	}
	return t.Commit()
}
