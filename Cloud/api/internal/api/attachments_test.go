package api

import (
	"bytes"
	"context"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestAttachmentOwnershipAndCommitFailure(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, m, "attach-"+randomHex(5)+"@example.com")
	other, _ := login(t, s, m, "attother-"+randomHex(5)+"@example.com")
	vid := newVault(t, h, token)
	id := "32345678-1234-4234-8234-123456789abc"
	path := "/v2/vaults/" + vid + "/attachments/" + id
	upload := randomHex(16)
	raw := []byte("encrypted-attachment")
	req := httptest.NewRequest("PUT", path+"?upload="+upload, bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("stage %d %s", w.Code, w.Body.String())
	}
	b := map[string]any{"uploadId": upload, "sha256": digest(raw), "cardUuid": id, "dekWrapped": b64(bytes.Repeat([]byte{1}, 40))}
	store := s.Objects.(*memoryStore)
	store.FailPut = true
	if status, _ := call(t, h, "POST", path+"/commit", token, b); status != 500 {
		t.Fatal("storage failure accepted")
	}
	var count int
	if e := s.DB.QueryRow("SELECT COUNT(*) FROM attachments WHERE vault_id=?", vid).Scan(&count); e != nil || count != 0 {
		t.Fatal("DB published before blob")
	}
	store.FailPut = false
	if status, out := call(t, h, "POST", path+"/commit", token, b); status != 200 {
		t.Fatalf("commit %d %v", status, out)
	}
	for _, method := range []string{"GET", "DELETE"} {
		if status, _ := call(t, h, method, path, other, nil); status != 404 {
			t.Fatalf("cross-user attachment %s %d", method, status)
		}
	}
	req = httptest.NewRequest("GET", path, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), raw) {
		t.Fatal("attachment did not roundtrip")
	}
	if status, _ := call(t, h, "DELETE", path, token, nil); status != 200 {
		t.Fatal("delete failed")
	}
}
func TestCodeAttemptsReplayAndSessionRevocation(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	em := "code-" + randomHex(5) + "@example.com"
	if code, _ := call(t, h, "POST", "/v2/auth/code", "", map[string]any{"email": em}); code != 202 {
		t.Fatal(code)
	}
	correct := m.get(em, "login")
	wrong := "000000"
	if correct == wrong {
		wrong = "000001"
	}
	for i := 0; i < 5; i++ {
		if code, _ := call(t, h, "POST", "/v2/auth/verify", "", map[string]any{"email": em, "code": wrong}); code != 400 {
			t.Fatal("wrong code accepted")
		}
	}
	if code, _ := call(t, h, "POST", "/v2/auth/verify", "", map[string]any{"email": em, "code": correct}); code != 400 {
		t.Fatal("attempt limit bypassed")
	}
	em = "replay-" + randomHex(5) + "@example.com"
	token, _ := login(t, s, m, em)
	if code, _ := call(t, h, "POST", "/v2/auth/verify", "", map[string]any{"email": em, "code": m.get(em, "login")}); code != 400 {
		t.Fatal("code replay accepted")
	}
	if code, _ := call(t, h, "DELETE", "/v2/auth/session", token, nil); code != 200 {
		t.Fatal("revoke failed")
	}
	if code, _ := call(t, h, "GET", "/v2/vaults", token, nil); code != 401 {
		t.Fatal("revoked token accepted")
	}
}
func TestCodeHourlyQuota(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	s.Config.Limits["CODE_HOURLY_PER_EMAIL"] = 2
	em := "quota-" + randomHex(5) + "@example.com"
	for i := 0; i < 2; i++ {
		if code, out := call(t, h, "POST", "/v2/auth/code", "", map[string]any{"email": em}); code != 202 {
			t.Fatalf("send %d %v", code, out)
		}
		if m.get(em, "login") == "" {
			t.Fatal("mail missing")
		}
		if _, e := s.DB.Exec("UPDATE email_codes SET created_ms=created_ms-120000 WHERE email_hmc=?", s.mac("email:"+em)); e != nil {
			t.Fatal(e)
		}
	}
	if code, _ := call(t, h, "POST", "/v2/auth/code", "", map[string]any{"email": em}); code != 429 {
		t.Fatalf("hourly quota not enforced: %d", code)
	}
}
func TestRekeyRejectsWrongUUIDSetAndOtherVault(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, m, "wrongset-"+randomHex(5)+"@example.com")
	other, _ := login(t, s, m, "wrongother-"+randomHex(5)+"@example.com")
	vid := newVault(t, h, token)
	base := "/v2/vaults/" + vid
	id := "42345678-1234-4234-8234-123456789abc"
	call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 0, "one")}})
	code, out := call(t, h, "POST", base+"/rekey/begin", token, map[string]any{"envelope": fakeEnvelope(), "itemCount": 1, "dekCount": 0})
	if code != 201 {
		t.Fatal(out)
	}
	rp := base + "/rekey/" + out["rekeyId"].(string)
	if code, _ = call(t, h, "POST", rp+"/chunk", other, map[string]any{"items": []any{map[string]any{"uuid": id, "bodyB64": b64([]byte("x")), "sha256": digest([]byte("x"))}}}); code != 404 {
		t.Fatal("foreign rekey reachable")
	}
	if code, _ = call(t, h, "POST", rp+"/chunk", token, map[string]any{"items": []any{map[string]any{"uuid": "52345678-1234-4234-8234-123456789abc", "bodyB64": b64([]byte("x")), "sha256": digest([]byte("x"))}}}); code != 409 {
		t.Fatal("wrong UUID staged")
	}
}
func TestSensitiveDeleteAndTransfer(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	em := "transfer-" + randomHex(5) + "@example.com"
	token, _ := login(t, s, m, em)
	vid := newVault(t, h, token)
	base := "/v2/vaults/" + vid
	if code, _ := call(t, h, "DELETE", base, token, map[string]any{"code": "000000"}); code != 403 {
		t.Fatal("delete without sensitive code")
	}
	target := "target-" + randomHex(5) + "@example.com"
	for _, e := range []string{em, target} {
		if code, out := call(t, h, "POST", "/v2/auth/code", "", map[string]any{"email": e, "purpose": "sensitive"}); code != 202 {
			t.Fatal(code, out)
		}
	}
	code, out := call(t, h, "POST", base+"/transfer", token, map[string]any{"email": target, "code": m.get(target, "sensitive"), "currentCode": m.get(em, "sensitive")})
	if code != 200 {
		t.Fatal(code, out)
	}
	if code, _ = call(t, h, "GET", base, token, nil); code != 404 {
		t.Fatal("old owner retained access")
	}
	if code, _ = call(t, h, "GET", base, out["token"].(string), nil); code != 200 {
		t.Fatal("new owner cannot read")
	}
}
func TestSafeLogsAndMalformedInput(t *testing.T) {
	s, m := testServer(t)
	var logs bytes.Buffer
	s.Log = slog.New(slog.NewJSONHandler(&logs, nil))
	_ = m
	h := s.Handler()
	secret := "ABCDE"
	call(t, h, "GET", "/v2/breach/range/"+secret, "", nil)
	if strings.Contains(logs.String(), secret) {
		t.Fatal("query prefix leaked")
	}
	for _, input := range []string{"null", "[]", "{} {}"} {
		r := httptest.NewRequest("POST", "/v2/auth/code", strings.NewReader(input))
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != 400 {
			t.Fatalf("malformed %s status %d", input, w.Code)
		}
	}
}
func TestMaintenanceGraceAndFloor(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, m, "maintenance-"+randomHex(5)+"@example.com")
	vid := newVault(t, h, token)
	id := "62345678-1234-4234-8234-123456789abc"
	call(t, h, "POST", "/v2/vaults/"+vid+"/items", token, map[string]any{"items": []any{incoming(id, 1, 0, "x")}})
	var seq int64
	s.DB.QueryRow("SELECT head_seq FROM vaults WHERE vault_id=?", vid).Scan(&seq)
	if _, e := s.DB.Exec("UPDATE item_changes SET created_ms=? WHERE vault_id=?", now()-100*dayMS, vid); e != nil {
		t.Fatal(e)
	}
	key := attachPrefix(vid) + "fresh-orphan"
	s.Objects.Put(context.Background(), key, []byte("x"), "application/octet-stream")
	if e := s.Maintain(context.Background()); e != nil {
		t.Fatal(e)
	}
	var floor int64
	if e := s.DB.QueryRow("SELECT changes_floor_seq FROM vaults WHERE vault_id=?", vid).Scan(&floor); e != nil || floor != seq {
		t.Fatalf("floor %d seq %d %v", floor, seq, e)
	}
	stream, _, e := s.Objects.Get(context.Background(), key)
	if e != nil {
		t.Fatal("fresh orphan deleted")
	}
	stream.Close()

}
