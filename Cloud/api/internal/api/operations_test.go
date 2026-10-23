package api

import (
	"bytes"
	"database/sql"
	"strings"
	"testing"
	"time"
)

func TestExistingWireEncryptionVector(t *testing.T) {
	s := &Server{Config: Config{KEK: bytes.Repeat([]byte{17}, 32)}}
	raw, err := s.open(sql.NullString{String: "v1.IiIiIiIiIiIiIiIidIVoOrPi8z6LWKtdL8PJs3bruZcY5FbVZfAkIqNMmLYfYsD43SY=", Valid: true})
	if err != nil || string(raw) != "cross-language fixture" {
		t.Fatal("Node AES-GCM fixture incompatible")
	}
}
func TestEmailValidationAndReplyRouting(t *testing.T) {
	for _, v := range []string{"alice@example.com", "user+tag@sub.example.com", "USER@EXAMPLE.COM"} {
		if _, e := email(v); e != nil {
			t.Errorf("valid email rejected: %s", v)
		}
	}
	for _, v := range []string{"user@exampleXcom", "x\\@example.com", "x@example.com\r\nBCC: victim@example.com"} {
		if _, e := email(v); e == nil {
			t.Error("invalid email accepted")
		}
	}
	c := Config{SMTPFrom: "sender@163.com", SMTPRegisterReplyTo: "register@upasswords.com", SMTPVerifyReplyTo: "verify@upasswords.com"}
	for _, p := range []string{"register", "login", "sensitive"} {
		msg := verificationMessage(c, "user@example.com", "123456", p, false)
		want := c.SMTPVerifyReplyTo
		if p == "register" {
			want = c.SMTPRegisterReplyTo
		}
		if !strings.Contains(msg, "Reply-To: "+want) || !strings.Contains(msg, "From: sender@163.com") {
			t.Error("incorrect sender or reply address")
		}
	}
}
func TestMaintenanceSchedule(t *testing.T) {
	ts := time.Date(2026, 10, 23, 4, 0, 0, 0, time.UTC)
	if nextMaintenance(ts) != ts.Add(24*time.Hour) {
		t.Fatal("schedule must advance at boundary")
	}
	if nextMaintenance(ts.Add(-time.Minute)) != ts {
		t.Fatal("schedule before boundary")
	}
}
