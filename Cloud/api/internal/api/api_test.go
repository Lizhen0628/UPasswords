package api

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type memoryObject struct {
	Data []byte
	Meta Object
}
type memoryStore struct {
	mu      sync.Mutex
	Objects map[string]memoryObject
	FailPut bool
}

func (m *memoryStore) Put(_ context.Context, k string, b []byte, mime string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.FailPut {
		return errors.New("test put failure")
	}
	m.Objects[k] = memoryObject{append([]byte(nil), b...), Object{Key: k, Size: int64(len(b)), ContentType: mime, Modified: time.Now()}}
	return nil
}
func (m *memoryStore) Get(_ context.Context, k string) (io.ReadCloser, Object, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	v, ok := m.Objects[k]
	if !ok {
		return nil, Object{}, fail(404, "not_found")
	}
	return io.NopCloser(bytes.NewReader(v.Data)), v.Meta, nil
}
func (m *memoryStore) Delete(_ context.Context, k string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.Objects, k)
	return nil
}
func (m *memoryStore) List(_ context.Context, p, c string) ([]Object, string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Object{}
	for k, v := range m.Objects {
		if strings.HasPrefix(k, p) {
			out = append(out, v.Meta)
		}
	}
	return out, "", nil
}

type testMailer struct {
	mu    sync.Mutex
	Codes map[string]string
}

func (m *testMailer) Send(_ context.Context, to, code, p string, _ bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if p == "register" {
		p = "login"
	}
	m.Codes[to+":"+p] = code
	return nil
}
func (m *testMailer) get(to, p string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.Codes[to+":"+p]
}
func testServer(t *testing.T) (*Server, *testMailer) {
	t.Helper()
	dsn := os.Getenv("UPW_TEST_DSN")
	if dsn == "" {
		t.Skip("UPW_TEST_DSN not set; use isolated compose.test.yaml")
	}
	db, e := sql.Open("mysql", dsn)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close() })
	var dbName string
	if e = db.QueryRow("SELECT DATABASE()").Scan(&dbName); e != nil {
		t.Fatal(e)
	}
	if !strings.HasSuffix(dbName, "_test") {
		t.Fatal("refusing integration tests against a non-test database")
	}
	schema, e := os.ReadFile(filepath.Join("..", "..", "..", "worker", "sql", "0001_init.sql"))
	if e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(string(schema)); e != nil {
		t.Fatal(e)
	}
	db.SetMaxOpenConns(16)
	mail := &testMailer{Codes: map[string]string{}}
	s := &Server{DB: db, Config: Config{KEK: bytes.Repeat([]byte{0x11}, 32), AdminToken: "test-only-admin-token", Limits: map[string]int64{}, TrustedProxy: "172.104.1.2"}, Objects: &memoryStore{Objects: map[string]memoryObject{}}, Mailer: mail, Log: slog.New(slog.NewJSONHandler(io.Discard, nil)), HTTP: &http.Client{Timeout: time.Second}}
	return s, mail
}
func call(t *testing.T, h http.Handler, method, path, token string, v any) (int, map[string]any) {
	t.Helper()
	var b io.Reader
	if v != nil {
		raw, e := json.Marshal(v)
		if e != nil {
			t.Fatal(e)
		}
		b = bytes.NewReader(raw)
	}
	r := httptest.NewRequest(method, path, b)
	r.RemoteAddr = "192.0.2.1:1234"
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	out := map[string]any{}
	if len(w.Body.Bytes()) > 0 {
		_ = json.Unmarshal(w.Body.Bytes(), &out)
	}
	return w.Code, out
}
func login(t *testing.T, s *Server, m *testMailer, em string) (string, string) {
	t.Helper()
	h := s.Handler()
	code, _ := call(t, h, "POST", "/v2/auth/code", "", map[string]any{"email": em})
	if code != 202 {
		t.Fatalf("code status %d", code)
	}
	code, out := call(t, h, "POST", "/v2/auth/verify", "", map[string]any{"email": em, "code": m.get(em, "login"), "platform": "macos", "deviceName": "test"})
	if code != 200 {
		t.Fatalf("login %d %v", code, out)
	}
	return out["token"].(string), out["userId"].(string)
}
func fakeEnvelope() string { b := make([]byte, 120); copy(b, []byte("UPWKEY1\x00")); return b64(b) }
func newVault(t *testing.T, h http.Handler, token string) string {
	t.Helper()
	status, v := call(t, h, "POST", "/v2/vaults", token, map[string]any{"name": "Test-" + randomHex(4), "envelope": fakeEnvelope()})
	if status != 201 {
		t.Fatalf("create vault %d %v", status, v)
	}
	return v["vaultId"].(string)
}
func incoming(id string, kind int, rev int64, data string) map[string]any {
	return map[string]any{"uuid": id, "kind": kind, "op": "upsert", "baseRevision": rev, "bodyB64": b64([]byte(data)), "modifiedMs": 1234}
}
func result(out map[string]any) map[string]any { return out["results"].([]any)[0].(map[string]any) }
func TestCryptoCompatibilityAndTamper(t *testing.T) {
	s := &Server{Config: Config{KEK: bytes.Repeat([]byte{0x11}, 32)}}
	sealed, e := s.seal([]byte("fixture"))
	if e != nil {
		t.Fatal(e)
	}
	raw, e := s.open(sql.NullString{String: sealed, Valid: true})
	if e != nil || string(raw) != "fixture" {
		t.Fatal("roundtrip failed")
	}
	parts, _ := decode64(sealed[3:])
	parts[len(parts)-1] ^= 1
	if _, e = s.open(sql.NullString{String: "v1." + b64(parts), Valid: true}); e == nil {
		t.Fatal("tampered envelope accepted")
	}
}
func TestClientIPTrust(t *testing.T) {
	s := &Server{Config: Config{TrustedProxy: "172.104.1.2"}}
	r := httptest.NewRequest("GET", "/", nil)
	r.Header.Set("X-Real-IP", "203.0.113.7")
	r.RemoteAddr = "192.0.2.2:10"
	if s.ip(r) != "192.0.2.2" {
		t.Fatal("untrusted proxy spoofed IP")
	}
	r.RemoteAddr = "172.104.1.2:10"
	if s.ip(r) != "203.0.113.7" {
		t.Fatal("trusted proxy not recognized")
	}
}
func TestJSONLimits(t *testing.T) {
	for _, raw := range []string{"{} {}", "null", "[]"} {
		w := httptest.NewRecorder()
		r := httptest.NewRequest("POST", "/", strings.NewReader(raw))
		var v struct{ Name string }
		e := body(w, r, 100, &v)
		if e == nil {
			t.Fatalf("accepted %s", raw)
		}
	}
	w := httptest.NewRecorder()
	r := httptest.NewRequest("POST", "/", strings.NewReader(strings.Repeat("x", 101)))
	var v any
	if body(w, r, 100, &v) == nil {
		t.Fatal("unbounded body")
	}
}
func TestSyncIsolationCASAndRekey(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	token, uid := login(t, s, m, "sync-"+randomHex(5)+"@example.com")
	other, _ := login(t, s, m, "other-"+randomHex(5)+"@example.com")
	vid := newVault(t, h, token)
	base := "/v2/vaults/" + vid
	id := "12345678-1234-4234-8234-123456789abc"
	label := "22345678-1234-4234-8234-123456789abc"
	for _, path := range []string{base, base + "/seq", base + "/items", base + "/changes?since=0", base + "/attachments/" + id} {
		if code, _ := call(t, h, "GET", path, other, nil); code != 404 {
			t.Fatalf("isolation failed %s %d", path, code)
		}
	}
	status, out := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(strings.ToUpper(id), 1, 0, "cipher-a"), incoming(label, 2, 0, "cipher-label")}})
	if status != 200 {
		t.Fatalf("insert %d %v", status, out)
	}
	var wg sync.WaitGroup
	statuses := make(chan string, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			code, out := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 1, "cipher-b")}})
			if code != 200 {
				statuses <- "error"
				return
			}
			statuses <- result(out)["status"].(string)
		}()
	}
	wg.Wait()
	close(statuses)
	counts := map[string]int{}
	for v := range statuses {
		counts[v]++
	}
	if counts["ok"] != 1 || counts["conflict"] != 1 {
		t.Fatalf("CAS %v", counts)
	}
	status, out = call(t, h, "POST", base+"/rekey/begin", token, map[string]any{"envelope": fakeEnvelope(), "itemCount": 2, "dekCount": 0})
	if status != 201 {
		t.Fatalf("begin %d %v", status, out)
	}
	rid := out["rekeyId"].(string)
	rp := base + "/rekey/" + rid
	if code, _ := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 2, "late")}}); code != 409 {
		t.Fatal("rekey write lock missing")
	}
	if code, _ := call(t, h, "POST", rp+"/commit", token, map[string]any{}); code != 409 {
		t.Fatal("incomplete rekey committed")
	}
	stage := []any{map[string]any{"uuid": id, "bodyB64": b64([]byte("new-a")), "sha256": digest([]byte("new-a"))}, map[string]any{"uuid": label, "bodyB64": b64([]byte("new-label")), "sha256": digest([]byte("new-label"))}}
	if code, out := call(t, h, "POST", rp+"/chunk", token, map[string]any{"items": stage}); code != 200 {
		t.Fatalf("chunk %d %v", code, out)
	}
	if code, out := call(t, h, "POST", rp+"/commit", token, map[string]any{}); code != 200 || out["passwordVersion"] != float64(2) {
		t.Fatalf("commit %d %v", code, out)
	}
	var kind, revision int
	var modified int64
	if e := s.DB.QueryRow("SELECT kind,revision,modified_ms FROM vault_items WHERE vault_id=? AND item_uuid=?", vid, label).Scan(&kind, &revision, &modified); e != nil {
		t.Fatal(e)
	}
	if kind != 2 || revision != 2 || modified != 1234 {
		t.Fatalf("label damaged kind=%d rev=%d modified=%d", kind, revision, modified)
	}
	if code, out := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 2, "old-key")}}); code != 200 || result(out)["status"] != "conflict" {
		t.Fatal("old-key CAS accepted")
	}
	code, out := call(t, h, "GET", base+"/changes?since=0", token, nil)
	if code != 200 || len(out["changes"].([]any)) != 4 {
		t.Fatalf("changes %d %v", code, out)
	}
	if _, e := s.DB.Exec("UPDATE vaults SET changes_floor_seq=1 WHERE vault_id=? AND user_id=?", vid, uid); e != nil {
		t.Fatal(e)
	}
	if code, _ := call(t, h, "GET", base+"/changes?since=0", token, nil); code != 410 {
		t.Fatal("cursor expiry lost")
	}
	code, out = call(t, h, "GET", base+"/items?limit=1", token, nil)
	if code != 200 || out["nextCursor"] == nil {
		t.Fatal("pagination missing")
	}
}
