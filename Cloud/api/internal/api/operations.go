package api

import (
	"context"
	"crypto/tls"
	"database/sql"
	"errors"
	"net"
	"net/smtp"
	"time"
)

// CheckDependencies checks production credentials without sending mail or changing stored data.
func (s *Server) CheckDependencies(ctx context.Context) error {
	for _, table := range []string{"users", "sessions", "email_codes", "vaults", "vault_items", "item_changes", "attachments", "rekeys", "rekey_staging", "audit_log", "websites", "website_domains"} {
		var count int
		if err := s.DB.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+table).Scan(&count); err != nil {
			return errors.New("database schema check failed: " + table)
		}
	}
	var encrypted sql.NullString
	err := s.DB.QueryRowContext(ctx, "SELECT email_enc FROM users WHERE email_enc IS NOT NULL LIMIT 1").Scan(&encrypted)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return errors.New("stored encryption check query failed")
	}
	if err == nil {
		if _, err = s.open(encrypted); err != nil {
			return errors.New("APP_KEK cannot open existing encrypted email")
		}
	}
	if err == nil {
		s.Log.Info("existing encryption compatibility verified")
	} else {
		s.Log.Info("no encrypted email available for compatibility check")
	}
	s.Log.Info("database schema and TLS verified")
	if _, _, err := s.Objects.List(ctx, "sites/icons/", ""); err != nil {
		return errors.New("R2 credential check failed")
	}
	s.Log.Info("R2 read access verified")
	c := s.Config
	d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 10 * time.Second}, Config: &tls.Config{ServerName: c.SMTPHost, MinVersion: tls.VersionTLS12}}
	conn, err := d.DialContext(ctx, "tcp", net.JoinHostPort(c.SMTPHost, c.SMTPPort))
	if err != nil {
		return errors.New("SMTP TLS connection failed")
	}
	defer conn.Close()
	if err = conn.SetDeadline(time.Now().Add(15 * time.Second)); err != nil {
		return err
	}
	client, err := smtp.NewClient(conn, c.SMTPHost)
	if err != nil {
		return errors.New("SMTP greeting failed")
	}
	defer client.Close()
	if err = client.Auth(smtp.PlainAuth("", c.SMTPUser, c.SMTPPassword, c.SMTPHost)); err != nil {
		return errors.New("SMTP authentication failed")
	}
	if err = client.Quit(); err != nil {
		return errors.New("SMTP disconnect failed")
	}
	s.Log.Info("SMTP TLS and authentication verified; no mail sent")
	return nil
}

// ScheduleMaintenance runs at 04:00 UTC daily. Failed jobs retry after one hour.
func (s *Server) ScheduleMaintenance(ctx context.Context) error {
	s.Log.Info("maintenance scheduler started", "schedule", "04:00 UTC daily")
	next := nextMaintenance(time.Now())
	for {
		timer := time.NewTimer(time.Until(next))
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
		run, cancel := context.WithTimeout(ctx, 30*time.Minute)
		err := s.Maintain(run)
		cancel()
		if err != nil {
			s.Log.Error("maintenance failed", "kind", "dependency_or_database")
			next = time.Now().Add(time.Hour)
		} else {
			next = nextMaintenance(time.Now())
		}
	}
}
func nextMaintenance(ts time.Time) time.Time {
	ts = ts.UTC()
	next := time.Date(ts.Year(), ts.Month(), ts.Day(), 4, 0, 0, 0, time.UTC)
	if !next.After(ts) {
		next = next.AddDate(0, 0, 1)
	}
	return next
}
