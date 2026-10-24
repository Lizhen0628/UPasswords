package api

import "testing"

// A count-complete staging set can still be stale if the current row identities changed.
func TestRekeyStaleSnapshotAndAbort(t *testing.T) {
	s, m := testServer(t)
	token, _ := login(t, s, m, "rekey-abort-"+randomHex(5)+"@example.com")
	h := s.Handler()
	vid := newVault(t, h, token)
	base := "/v1/vaults/" + vid
	id := "a2345678-1234-4234-8234-123456789abc"
	if code, out := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 0, "old-cipher")}}); code != 200 || result(out)["status"] != "ok" {
		t.Fatalf("initial row: %d %v", code, out)
	}
	_, original := call(t, h, "GET", base, token, nil)
	code, out := call(t, h, "POST", base+"/rekey/begin", token, map[string]any{"envelope": fakeEnvelope(), "itemCount": 1, "dekCount": 0})
	if code != 201 {
		t.Fatalf("begin: %d %v", code, out)
	}
	rid := out["rekeyId"].(string)
	rp := base + "/rekey/" + rid
	chunk := map[string]any{"items": []any{map[string]any{"uuid": id, "bodyB64": b64([]byte("new-cipher")), "sha256": digest([]byte("new-cipher"))}}}
	for range 2 {
		if code, out = call(t, h, "POST", rp+"/chunk", token, chunk); code != 200 || out["itemStaged"] != float64(1) {
			t.Fatalf("idempotent chunk: %d %v", code, out)
		}
	}
	// Simulate a changed database snapshot without bypassing the public API write lock.
	if _, err := s.DB.Exec("UPDATE vault_items SET item_uuid=? WHERE vault_id=? AND item_uuid=?", "b2345678-1234-4234-8234-123456789abc", vid, id); err != nil {
		t.Fatal(err)
	}
	if code, out = call(t, h, "POST", rp+"/commit", token, map[string]any{}); code != 409 || out["error"] != "rekey_stale" {
		t.Fatalf("stale commit: %d %v", code, out)
	}
	if code, out = call(t, h, "DELETE", rp, token, nil); code != 200 {
		t.Fatalf("abort: %d %v", code, out)
	}
	var staged int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM rekey_staging WHERE rekey_id=?", rid).Scan(&staged); err != nil || staged != 0 {
		t.Fatalf("abort left staging rows: %d, %v", staged, err)
	}
	code, detail := call(t, h, "GET", base, token, nil)
	if code != 200 || detail["envelope"] != original["envelope"] || detail["passwordVersion"] != original["passwordVersion"] {
		t.Fatalf("abort changed active envelope/version: %d %v", code, detail)
	}
	if code, out = call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 0, "after-abort")}}); code != 200 || result(out)["status"] != "ok" {
		t.Fatalf("abort did not release write lock: %d %v", code, out)
	}
}
