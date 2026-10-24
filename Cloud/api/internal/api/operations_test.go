package api

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"io"
	"log/slog"
	"mime"
	"net/mail"
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

func TestVerificationMailLanguageAndPurpose(t *testing.T) {
	for _, zh := range []bool{false, true} {
		for _, purpose := range []string{"register", "login", "sensitive"} {
			message, err := mail.ReadMessage(strings.NewReader(verificationMessage(Config{SMTPFrom: "sender@example.com"}, "user@example.com", "123456", purpose, zh)))
			if err != nil {
				t.Fatal(err)
			}
			subject, err := new(mime.WordDecoder).DecodeHeader(message.Header.Get("Subject"))
			if err != nil {
				t.Fatal(err)
			}
			wantSubject := "UPasswords sign-in code"
			if purpose == "sensitive" {
				wantSubject = "UPasswords security code"
			}
			if zh {
				wantSubject = "UPasswords 登录验证码"
				if purpose == "sensitive" {
					wantSubject = "UPasswords 安全操作验证码"
				}
			}
			raw, err := io.ReadAll(base64.NewDecoder(base64.StdEncoding, message.Body))
			if err != nil {
				t.Fatal(err)
			}
			wantExpiry := "10 minutes"
			if zh {
				wantExpiry = "10 分钟"
			}
			if subject != wantSubject || !strings.Contains(string(raw), "123456") || !strings.Contains(string(raw), wantExpiry) || message.Header.Get("Content-Type") != "text/plain; charset=UTF-8" {
				t.Fatalf("mail content mismatch for zh=%v purpose=%s: %q", zh, purpose, subject)
			}
		}
	}
}

func TestVersionedRouteCompatibility(t *testing.T) {
	s := &Server{Log: slog.New(slog.NewJSONHandler(io.Discard, nil))}
	h := s.Handler()
	for _, path := range []string{"/v1/", "/v2/"} {
		status, body := call(t, h, "GET", path, "", nil)
		if status != 200 || body["version"] != float64(2) {
			t.Errorf("capability route %s returned %d", path, status)
		}
		capabilities := body["capabilities"].([]any)
		found := map[string]bool{}
		for _, capability := range capabilities {
			found[capability.(string)] = true
		}
		if !found["vaults.row_sync"] || !found["breach.range"] {
			t.Errorf("capability route %s omitted row-sync capabilities: %v", path, capabilities)
		}
	}
	for _, path := range []string{"/v1/vaults", "/v2/vaults"} {
		status, _ := call(t, h, "GET", path, "", nil)
		if status != 401 {
			t.Errorf("protected route %s returned %d without a token", path, status)
		}
	}
}
