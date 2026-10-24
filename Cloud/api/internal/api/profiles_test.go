package api

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"io"
	"strings"
	"testing"
)

func TestEncryptedProfileTableMigrationSyncRekeyAndDelete(t *testing.T) {
	s, m := testServer(t)
	token, uid := login(t, s, m, "profile-"+randomHex(6)+"@example.com")
	t.Cleanup(func() { s.DB.Exec("DELETE FROM users WHERE id=?", uid) })
	h := s.Handler()
	vid := newVault(t, h, token)
	id := "4a00a000-0000-4000-8000-000000000003"
	key := bytes.Repeat([]byte{0x42}, 32)
	seal := func(value string) []byte {
		block, err := aes.NewCipher(key)
		if err != nil {
			t.Fatal(err)
		}
		aead, err := cipher.NewGCM(block)
		if err != nil {
			t.Fatal(err)
		}
		nonce := make([]byte, aead.NonceSize())
		if _, err = io.ReadFull(rand.Reader, nonce); err != nil {
			t.Fatal(err)
		}
		return aead.Seal(nonce, nonce, []byte(value), []byte(strings.ToUpper(id)))
	}
	old := incoming(id, 1, 0, "legacy-encrypted-row")
	status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{old}})
	if status != 200 || result(out)["revision"] != float64(1) {
		t.Fatalf("legacy row: %d %v", status, out)
	}
	// A table move must preserve logical record creation time, revision and quota.
	if _, err := s.DB.Exec("UPDATE vault_items SET created_ms=123 WHERE vault_id=? AND item_uuid=?", vid, id); err != nil {
		t.Fatal(err)
	}
	encrypted := seal("<user_profile><email>fixture@example.com</email></user_profile>")
	next := incoming(id, 3, 1, string(encrypted))
	status, out = call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{next}})
	if status != 200 || result(out)["revision"] != float64(2) {
		t.Fatalf("profile migration: %d %v", status, out)
	}
	var created int64
	if err := s.DB.QueryRow("SELECT created_ms FROM vault_user_profiles WHERE vault_id=? AND item_uuid=?", vid, id).Scan(&created); err != nil || created != 123 {
		t.Fatalf("profile migration changed creation time: %d, %v", created, err)
	}
	if code, conflict := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{incoming(id, 3, 1, "stale-cipher")}}); code != 200 || result(conflict)["status"] != "conflict" {
		t.Fatalf("profile CAS: %d %v", code, conflict)
	}
	if code, rejected := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{incoming(id, 1, 2, "legacy-client-overwrite")}}); code != 409 || rejected["error"] != "record_type_changed" {
		t.Fatalf("profile downgrade accepted: %d %v", code, rejected)
	}
	var profiles, cards int
	var stored []byte
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_items WHERE vault_id=?", vid).Scan(&cards); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_user_profiles WHERE vault_id=?", vid).Scan(&profiles); err != nil {
		t.Fatal(err)
	}
	if cards != 0 || profiles != 1 {
		t.Fatalf("table isolation: cards=%d profiles=%d", cards, profiles)
	}
	if err := s.DB.QueryRow("SELECT body FROM vault_user_profiles WHERE vault_id=?", vid).Scan(&stored); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(stored, encrypted) || bytes.Contains(stored, []byte("fixture@example.com")) {
		t.Fatal("profile body must remain ciphertext")
	}
	status, out = call(t, h, "GET", "/v1/vaults/"+vid+"/items", token, nil)
	if status != 200 || len(out["items"].([]any)) != 1 || out["items"].([]any)[0].(map[string]any)["kind"] != float64(3) {
		t.Fatalf("profile snapshot: %d %v", status, out)
	}
	status, out = call(t, h, "GET", "/v1/vaults/"+vid+"/changes?since=0", token, nil)
	if status != 200 || out["changes"].([]any)[0].(map[string]any)["kind"] != float64(3) {
		t.Fatalf("profile delta: %d %v", status, out)
	}
	status, out = call(t, h, "POST", "/v1/vaults/"+vid+"/rekey/begin", token, map[string]any{"envelope": fakeEnvelope(), "itemCount": 1, "dekCount": 0})
	if status != 201 {
		t.Fatalf("rekey begin: %d %v", status, out)
	}
	rid := out["rekeyId"].(string)
	replacement := seal("replacement encrypted profile")
	status, out = call(t, h, "POST", "/v1/vaults/"+vid+"/rekey/"+rid+"/chunk", token, map[string]any{"items": []any{map[string]any{"uuid": id, "bodyB64": b64(replacement), "sha256": digest(replacement)}}})
	if status != 200 {
		t.Fatalf("rekey chunk: %d %v", status, out)
	}
	status, out = call(t, h, "POST", "/v1/vaults/"+vid+"/rekey/"+rid+"/commit", token, map[string]any{})
	if status != 200 {
		t.Fatalf("rekey commit: %d %v", status, out)
	}
	var revision, kind int
	if err := s.DB.QueryRow("SELECT revision,kind,body FROM vault_user_profiles WHERE vault_id=?", vid).Scan(&revision, &kind, &stored); err != nil {
		t.Fatal(err)
	}
	if revision != 3 || kind != 3 || !bytes.Equal(stored, replacement) {
		t.Fatal("rekey did not preserve profile identity and kind")
	}
	status, out = call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{map[string]any{"uuid": id, "kind": 1, "op": "delete", "baseRevision": 3, "modifiedMs": 2000}}})
	if status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("profile delete: %d %v", status, out)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_user_profiles WHERE vault_id=?", vid).Scan(&profiles); err != nil || profiles != 0 {
		t.Fatal("profile deletion failed")
	}
}

// Mixed snapshots share pagination and quota across both physical tables.
func TestProfileMixedPaginationQuotaMaintenanceAndRollback(t *testing.T) {
	s, m := testServer(t)
	token, _ := login(t, s, m, "profile-mixed-"+randomHex(6)+"@example.com")
	h := s.Handler()
	vid := newVault(t, h, token)
	base := "/v1/vaults/" + vid
	ids := []string{"5a00a000-0000-4000-8000-000000000001", "5a00a000-0000-4000-8000-000000000002", "5a00a000-0000-4000-8000-000000000003"}
	rows := []any{incoming(ids[0], 1, 0, "card-cipher"), incoming(ids[1], 2, 0, "label-cipher"), incoming(ids[2], 3, 0, "profile-cipher")}
	if code, out := call(t, h, "POST", base+"/items", token, map[string]any{"items": rows}); code != 200 || len(out["results"].([]any)) != 3 {
		t.Fatalf("mixed insert: %d %v", code, out)
	}
	seen := map[string]bool{}
	path := base + "/items?limit=1"
	for range 3 {
		code, out := call(t, h, "GET", path, token, nil)
		if code != 200 || len(out["items"].([]any)) != 1 {
			t.Fatalf("mixed page: %d %v", code, out)
		}
		row := out["items"].([]any)[0].(map[string]any)
		if seen[row["uuid"].(string)] {
			t.Fatal("duplicate row across tables")
		}
		seen[row["uuid"].(string)] = true
		next, more := out["nextCursor"].(map[string]any)
		if len(seen) == 3 {
			if more {
				t.Fatal("mixed last page advertised another page")
			}
		} else {
			if !more {
				t.Fatal("mixed snapshot truncated")
			}
			path = base + "/items?limit=1&cursorMs=" + intString(int64(next["ms"].(float64))) + "&cursorUuid=" + next["uuid"].(string)
		}
	}
	newID := "5a00a000-0000-4000-8000-000000000004"
	// A rejected type conversion rolls back earlier writes from the same batch.
	code, out := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(newID, 1, 0, "must-rollback"), incoming(ids[2], 1, 1, "forbidden-downgrade")}})
	if code != 409 || out["error"] != "record_type_changed" {
		t.Fatalf("mixed rollback: %d %v", code, out)
	}
	var count int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=?", vid).Scan(&count); err != nil || count != 3 {
		t.Fatalf("batch was not rolled back: %d, %v", count, err)
	}
	if _, err := s.DB.Exec("UPDATE vaults SET item_count=0 WHERE vault_id=?", vid); err != nil {
		t.Fatal(err)
	}
	if err := s.Maintain(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT item_count FROM vaults WHERE vault_id=?", vid).Scan(&count); err != nil || count != 3 {
		t.Fatalf("maintenance omitted profiles: %d, %v", count, err)
	}
	s.Config.Limits["ITEMS_PER_VAULT_LIMIT"] = 3
	if code, out = call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(newID, 3, 0, "over-quota-profile")}}); code != 413 || out["error"] != "quota_exceeded" {
		t.Fatalf("profile bypassed shared quota: %d %v", code, out)
	}
	// Reapplying the canonical schema sequence must leave existing encrypted rows intact.
	second, _ := testServer(t)
	if err := second.DB.QueryRow("SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=?", vid).Scan(&count); err != nil || count != 3 {
		t.Fatalf("migration replay changed existing rows: %d, %v", count, err)
	}
}
