package api

import (
	"bytes"
	"context"
	"database/sql"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
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
	version := "42345678-1234-4234-8234-123456789abc"
	path := "/v1/vaults/" + vid + "/attachments/" + id
	upload := randomHex(16)
	raw := []byte("encrypted-attachment")
	req := httptest.NewRequest("PUT", path+"?upload="+upload+"&version="+version, bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set(syncProtocolHeader, strconv.Itoa(syncProtocolVersion))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("stage %d %s", w.Code, w.Body.String())
	}
	dek := bytes.Repeat([]byte{1}, 40)
	b := map[string]any{"uploadId": upload, "sha256": digest(raw), "cardUuid": id,
		"contentVersion": version, "dekWrapped": b64(dek)}
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
	row := incoming(id, 1, 0, "card")
	row["attachmentRefs"] = []any{map[string]any{
		"attachmentId": id, "contentVersion": version,
	}}
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token,
		map[string]any{"items": []any{row}}); status != 200 {
		t.Fatalf("item reference activation %d %v", status, out)
	}
	for _, method := range []string{"GET", "DELETE"} {
		if status, _ := call(t, h, method, path, other, nil); status != 404 {
			t.Fatalf("cross-user attachment %s %d", method, status)
		}
	}
	req = httptest.NewRequest("GET", path+"?version="+version, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set(syncProtocolHeader, strconv.Itoa(syncProtocolVersion))
	w = httptest.NewRecorder()
	h.ServeHTTP(w, req)
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), raw) || w.Header().Get("X-Dek-Wrapped") != b64(dek) || w.Header().Get("X-Content-Version") != version {
		t.Fatal("attachment did not roundtrip")
	}
	if status, _ := call(t, h, "DELETE", path, token, nil); status != 200 {
		t.Fatal("delete failed")
	}
	if status, _ := call(t, h, "GET", path+"?version="+version, token, nil); status != 200 {
		t.Fatal("deleted attachment version should remain recoverable during retention")
	}
}

func TestAttachmentVersionCASRetainsPreviousVersion(t *testing.T) {
	s, mail := testServer(t)
	handler := s.Handler()
	token, _ := login(t, s, mail, "attachversions-"+randomHex(5)+"@example.com")
	vaultID := newVault(t, handler, token)
	attachmentID := "32345678-1234-4234-8234-123456789abc"
	cardID := "52345678-1234-4234-8234-123456789abc"
	version1 := "42345678-1234-4234-8234-123456789abc"
	version2 := "62345678-1234-4234-8234-123456789abc"
	path := "/v1/vaults/" + vaultID + "/attachments/" + attachmentID
	commit := func(version string, raw []byte) int {
		t.Helper()
		uploadID := randomHex(16)
		put := httptest.NewRequest(http.MethodPut, path+"?upload="+uploadID+"&version="+version, bytes.NewReader(raw))
		put.Header.Set("Authorization", "Bearer "+token)
		put.Header.Set(syncProtocolHeader, strconv.Itoa(syncProtocolVersion))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, put)
		if response.Code != http.StatusOK {
			t.Fatalf("stage returned %d: %s", response.Code, response.Body.String())
		}
		body := map[string]any{
			"uploadId": uploadID, "sha256": digest(raw), "cardUuid": cardID,
			"contentVersion": version,
			"dekWrapped":     b64(bytes.Repeat([]byte{byte(len(raw))}, 40)),
		}
		status, _ := call(t, handler, http.MethodPost, path+"/commit", token, body)
		return status
	}

	if status := commit(version1, []byte("cipher-one")); status != http.StatusOK {
		t.Fatalf("first version commit returned %d", status)
	}
	firstRow := incoming(cardID, 1, 0, "card-one")
	firstRow["attachmentRefs"] = []any{map[string]any{"attachmentId": attachmentID, "contentVersion": version1}}
	if status, _ := call(t, handler, http.MethodPost, "/v1/vaults/"+vaultID+"/items", token, map[string]any{"items": []any{firstRow}}); status != http.StatusOK {
		t.Fatalf("first row commit returned %d", status)
	}
	if status := commit(version2, []byte("cipher-two")); status != http.StatusOK {
		t.Fatalf("replacement commit returned %d", status)
	}
	secondRow := incoming(cardID, 1, 1, "card-two")
	secondRow["attachmentRefs"] = []any{map[string]any{"attachmentId": attachmentID, "contentVersion": version2}}
	if status, _ := call(t, handler, http.MethodPost, "/v1/vaults/"+vaultID+"/items", token, map[string]any{"items": []any{secondRow}}); status != http.StatusOK {
		t.Fatalf("replacement row commit returned %d", status)
	}
	staleRow := incoming(cardID, 1, 1, "stale-card")
	staleRow["attachmentRefs"] = []any{map[string]any{"attachmentId": attachmentID, "contentVersion": version1}}
	if status, out := call(t, handler, http.MethodPost, "/v1/vaults/"+vaultID+"/items", token, map[string]any{"items": []any{staleRow}}); status != http.StatusOK || result(out)["status"] != "conflict" {
		t.Fatalf("stale row base was not rejected: %d %v", status, out)
	}
	for _, version := range []string{version1, version2} {
		request := httptest.NewRequest(http.MethodGet, path+"?version="+version, nil)
		request.Header.Set("Authorization", "Bearer "+token)
		request.Header.Set(syncProtocolHeader, strconv.Itoa(syncProtocolVersion))
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusOK || response.Header().Get("X-Content-Version") != version {
			t.Fatalf("retained version %s unavailable: %d", version, response.Code)
		}
	}
	var count int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM attachment_versions WHERE vault_id=? AND attach_uuid=?", vaultID, attachmentID).Scan(&count); err != nil || count != 2 {
		t.Fatalf("expected two retained versions, got %d: %v", count, err)
	}
	var currentVersion string
	if err := s.DB.QueryRow("SELECT content_version FROM attachments WHERE vault_id=? AND attach_uuid=?", vaultID, attachmentID).Scan(&currentVersion); err != nil || currentVersion != version2 {
		t.Fatalf("row CAS did not activate the requested version: %q %v", currentVersion, err)
	}
}
func TestCodeAttemptsReplayAndSessionRevocation(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	em := "code-" + randomHex(5) + "@example.com"
	if code, _ := call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": em}); code != 202 {
		t.Fatal(code)
	}
	correct := m.get(em, "login")
	wrong := "000000"
	if correct == wrong {
		wrong = "000001"
	}
	for i := 0; i < 5; i++ {
		if code, _ := call(t, h, "POST", "/v1/auth/verify", "", map[string]any{"email": em, "code": wrong}); code != 400 {
			t.Fatal("wrong code accepted")
		}
	}
	if code, _ := call(t, h, "POST", "/v1/auth/verify", "", map[string]any{"email": em, "code": correct}); code != 400 {
		t.Fatal("attempt limit bypassed")
	}
	em = "replay-" + randomHex(5) + "@example.com"
	token, _ := login(t, s, m, em)
	if code, _ := call(t, h, "POST", "/v1/auth/verify", "", map[string]any{"email": em, "code": m.get(em, "login")}); code != 400 {
		t.Fatal("code replay accepted")
	}
	if code, _ := call(t, h, "DELETE", "/v1/auth/session", token, nil); code != 200 {
		t.Fatal("revoke failed")
	}
	if code, _ := call(t, h, "GET", "/v1/vaults", token, nil); code != 401 {
		t.Fatal("revoked token accepted")
	}
}
func TestCodeHourlyQuota(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	s.Config.Limits["CODE_HOURLY_PER_EMAIL"] = 2
	em := "quota-" + randomHex(5) + "@example.com"
	if code, out := call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": em}); code != 202 {
		t.Fatalf("first send %d %v", code, out)
	}
	if code, _ := call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": em}); code != 429 {
		t.Fatalf("resend cooldown not enforced: %d", code)
	}
	if _, e := s.DB.Exec("UPDATE email_codes SET created_ms=created_ms-120000 WHERE email_hmc=?", s.mac("email:"+em)); e != nil {
		t.Fatal(e)
	}
	if code, out := call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": em}); code != 202 {
		t.Fatalf("second send %d %v", code, out)
	}
	if m.get(em, "login") == "" {
		t.Fatal("mail missing")
	}
	if _, e := s.DB.Exec("UPDATE email_codes SET created_ms=created_ms-120000 WHERE email_hmc=?", s.mac("email:"+em)); e != nil {
		t.Fatal(e)
	}
	if code, _ := call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": em}); code != 429 {
		t.Fatalf("hourly quota not enforced: %d", code)
	}
}
func TestRekeyRejectsWrongUUIDSetAndOtherVault(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, m, "wrongset-"+randomHex(5)+"@example.com")
	other, _ := login(t, s, m, "wrongother-"+randomHex(5)+"@example.com")
	vid := newVault(t, h, token)
	base := "/v1/vaults/" + vid
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
	base := "/v1/vaults/" + vid
	if code, _ := call(t, h, "DELETE", base, token, map[string]any{"code": "000000"}); code != 403 {
		t.Fatal("delete without sensitive code")
	}
	target := "target-" + randomHex(5) + "@example.com"
	for _, e := range []string{em, target} {
		if code, out := call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": e, "purpose": "sensitive"}); code != 202 {
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
	call(t, h, "GET", "/v1/breach/range/"+secret, "", nil)
	if strings.Contains(logs.String(), secret) {
		t.Fatal("query prefix leaked")
	}
	for _, input := range []string{"null", "[]", "{} {}"} {
		r := httptest.NewRequest("POST", "/v1/auth/code", strings.NewReader(input))
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
	call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{incoming(id, 1, 0, "x")}})
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

func TestExpiredAttachmentPurgeIsDurableAndRetryable(t *testing.T) {
	s, mail := testServer(t)
	handler := s.Handler()
	token, _ := login(t, s, mail, "attachment-purge-"+randomHex(5)+"@example.com")
	vaultID := newVault(t, handler, token)
	cardID := "72345678-1234-4234-8234-123456789abc"
	attachmentID := "82345678-1234-4234-8234-123456789abc"
	contentVersion := "92345678-1234-4234-8234-123456789abc"
	path := "/v1/vaults/" + vaultID + "/attachments/" + attachmentID
	uploadID := randomHex(16)
	ciphertext := []byte("encrypted-attachment")
	put := httptest.NewRequest(http.MethodPut, path+"?upload="+uploadID+"&version="+contentVersion, bytes.NewReader(ciphertext))
	put.Header.Set("Authorization", "Bearer "+token)
	put.Header.Set(syncProtocolHeader, strconv.Itoa(syncProtocolVersion))
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, put)
	if response.Code != http.StatusOK {
		t.Fatalf("stage returned %d: %s", response.Code, response.Body.String())
	}
	dek := bytes.Repeat([]byte{1}, 40)
	commit := map[string]any{
		"uploadId": uploadID, "sha256": digest(ciphertext), "cardUuid": cardID,
		"contentVersion": contentVersion, "dekWrapped": b64(dek),
	}
	if status, out := call(t, handler, http.MethodPost, path+"/commit", token, commit); status != http.StatusOK {
		t.Fatalf("commit returned %d: %v", status, out)
	}
	row := incoming(cardID, 1, 0, "attachment-owner")
	row["attachmentRefs"] = []any{map[string]any{"attachmentId": attachmentID, "contentVersion": contentVersion}}
	if status, out := call(t, handler, http.MethodPost, "/v1/vaults/"+vaultID+"/items", token, map[string]any{"items": []any{row}}); status != http.StatusOK {
		t.Fatalf("activate reference returned %d: %v", status, out)
	}
	if status, out := call(t, handler, http.MethodDelete, path, token, nil); status != http.StatusOK {
		t.Fatalf("delete returned %d: %v", status, out)
	}
	old := now() - 31*dayMS
	if _, err := s.DB.Exec("UPDATE attachment_versions SET unreferenced_ms=?,retired_ms=? WHERE vault_id=? AND attach_uuid=? AND content_version=?", old, old, vaultID, attachmentID, contentVersion); err != nil {
		t.Fatal(err)
	}
	objects := s.Objects.(*memoryStore)
	objects.FailDelete = true
	if err := s.Maintain(context.Background()); err == nil {
		t.Fatal("failed object deletion was ignored")
	}
	var purgeStarted sql.NullInt64
	var retainedBytes int64
	if err := s.DB.QueryRow("SELECT purge_started_ms,bytes FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?", vaultID, attachmentID, contentVersion).Scan(&purgeStarted, &retainedBytes); err != nil {
		t.Fatal(err)
	}
	if !purgeStarted.Valid || retainedBytes != int64(len(ciphertext)) {
		t.Fatal("failed cleanup did not keep a charged, retryable version")
	}
	var quotaBytes int64
	if err := s.DB.QueryRow("SELECT attach_bytes FROM vaults WHERE vault_id=?", vaultID).Scan(&quotaBytes); err != nil || quotaBytes != retainedBytes {
		t.Fatalf("failed cleanup changed quota: %d %v", quotaBytes, err)
	}
	if status, _ := call(t, handler, http.MethodGet, path+"?version="+contentVersion, token, nil); status != http.StatusNotFound {
		t.Fatal("purge-pending content remained downloadable")
	}
	restore := incoming(cardID, 1, 1, "attachment-owner")
	restore["attachmentRefs"] = []any{map[string]any{
		"attachmentId": attachmentID, "contentVersion": contentVersion, "restoreDeleted": true,
	}}
	if status, _ := call(t, handler, http.MethodPost, "/v1/vaults/"+vaultID+"/items", token,
		map[string]any{"items": []any{restore}}); status != http.StatusConflict {
		t.Fatal("purge-pending content was restored")
	}
	if status, _ := call(t, handler, http.MethodPost, "/v1/vaults/"+vaultID+"/rekey/begin", token,
		map[string]any{"envelope": fakeEnvelope(), "itemCount": int64(1), "dekCount": int64(1)}); status != http.StatusConflict {
		t.Fatal("rekey began while attachment cleanup was pending")
	}
	objects.FailDelete = false
	if _, err := s.DB.Exec("CREATE TRIGGER fail_attachment_version_purge BEFORE DELETE ON attachment_versions FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='test cleanup failure'"); err != nil {
		t.Fatal(err)
	}
	if err := s.Maintain(context.Background()); err == nil {
		t.Fatal("failed metadata deletion was ignored")
	}
	if err := s.DB.QueryRow("SELECT attach_bytes FROM vaults WHERE vault_id=?", vaultID).Scan(&quotaBytes); err != nil || quotaBytes != retainedBytes {
		t.Fatalf("SQL cleanup failure changed quota: %d %v", quotaBytes, err)
	}
	if _, _, err := objects.Get(context.Background(), attachPrefix(vaultID)+attachmentID+"/"+contentVersion+"/"+digest(ciphertext)); err == nil {
		t.Fatal("object was not deleted before the metadata failure")
	}
	if _, err := s.DB.Exec("DROP TRIGGER fail_attachment_version_purge"); err != nil {
		t.Fatal(err)
	}
	if err := s.Maintain(context.Background()); err != nil {
		t.Fatalf("retry cleanup failed: %v", err)
	}
	var versionCount int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM attachment_versions WHERE vault_id=? AND attach_uuid=?", vaultID, attachmentID).Scan(&versionCount); err != nil || versionCount != 0 {
		t.Fatalf("purged version count %d: %v", versionCount, err)
	}
	if err := s.DB.QueryRow("SELECT attach_bytes FROM vaults WHERE vault_id=?", vaultID).Scan(&quotaBytes); err != nil || quotaBytes != 0 {
		t.Fatalf("purge quota %d: %v", quotaBytes, err)
	}
}

func TestAttachmentReferenceRestoreAndRowCASRollback(t *testing.T) {
	s, mail := testServer(t)
	handler := s.Handler()
	token, _ := login(t, s, mail, "attach-restore-"+randomHex(5)+"@example.com")
	vaultID := newVault(t, handler, token)
	attachmentID := "32345678-1234-4234-8234-123456789abc"
	cardID := "52345678-1234-4234-8234-123456789abc"
	contentVersion := "42345678-1234-4234-8234-123456789abc"
	attachmentPath := "/v1/vaults/" + vaultID + "/attachments/" + attachmentID
	uploadID := randomHex(16)
	ciphertext := []byte("encrypted-attachment")
	put := httptest.NewRequest(http.MethodPut,
		attachmentPath+"?upload="+uploadID+"&version="+contentVersion, bytes.NewReader(ciphertext))
	put.Header.Set("Authorization", "Bearer "+token)
	put.Header.Set(syncProtocolHeader, strconv.Itoa(syncProtocolVersion))
	putResponse := httptest.NewRecorder()
	handler.ServeHTTP(putResponse, put)
	if putResponse.Code != http.StatusOK {
		t.Fatalf("stage returned %d: %s", putResponse.Code, putResponse.Body.String())
	}
	commit := map[string]any{
		"uploadId": uploadID, "sha256": digest(ciphertext), "cardUuid": cardID,
		"contentVersion": contentVersion, "dekWrapped": b64(bytes.Repeat([]byte{1}, 40)),
	}
	if status, out := call(t, handler, http.MethodPost, attachmentPath+"/commit", token, commit); status != http.StatusOK {
		t.Fatalf("commit returned %d: %v", status, out)
	}
	initialRow := incoming(cardID, 1, 0, "card-before-delete")
	initialRow["attachmentRefs"] = []any{map[string]any{
		"attachmentId": attachmentID, "contentVersion": contentVersion,
	}}
	itemsPath := "/v1/vaults/" + vaultID + "/items"
	if status, out := call(t, handler, http.MethodPost, itemsPath, token,
		map[string]any{"items": []any{initialRow}}); status != http.StatusOK {
		t.Fatalf("initial row commit returned %d: %v", status, out)
	}
	if status, out := call(t, handler, http.MethodDelete, attachmentPath, token, nil); status != http.StatusOK {
		t.Fatalf("attachment delete returned %d: %v", status, out)
	}
	restoredRow := incoming(cardID, 1, 1, "card-restored")
	restoredRow["attachmentRefs"] = []any{map[string]any{
		"attachmentId": attachmentID, "contentVersion": contentVersion, "restoreDeleted": true,
	}}
	if status, out := call(t, handler, http.MethodPost, itemsPath, token,
		map[string]any{"items": []any{restoredRow}}); status != http.StatusOK || result(out)["status"] != "ok" {
		t.Fatalf("deleted attachment did not restore: %d %v", status, out)
	}
	var activeCount, tombstoneCount int
	var retired, unreferenced sql.NullInt64
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM attachments WHERE vault_id=? AND attach_uuid=? AND content_version=?",
		vaultID, attachmentID, contentVersion).Scan(&activeCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM attachment_tombstones WHERE vault_id=? AND attach_uuid=?",
		vaultID, attachmentID).Scan(&tombstoneCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT retired_ms,unreferenced_ms FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?",
		vaultID, attachmentID, contentVersion).Scan(&retired, &unreferenced); err != nil {
		t.Fatal(err)
	}
	if activeCount != 1 || tombstoneCount != 0 || retired.Valid || unreferenced.Valid {
		t.Fatal("attachment restore did not atomically reactivate its retained version")
	}
	if _, err := s.DB.Exec("CREATE TRIGGER fail_attachment_reference_change BEFORE INSERT ON item_changes FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='test item change failure'"); err != nil {
		t.Fatal(err)
	}
	removalRow := incoming(cardID, 1, 2, "card-reference-removal")
	removalRow["attachmentRefs"] = []any{}
	failureStatus, _ := call(t, handler, http.MethodPost, itemsPath, token,
		map[string]any{"items": []any{removalRow}})
	if _, err := s.DB.Exec("DROP TRIGGER fail_attachment_reference_change"); err != nil {
		t.Fatal(err)
	}
	if failureStatus != http.StatusInternalServerError {
		t.Fatalf("injected change-event failure returned %d", failureStatus)
	}
	var revision int64
	var body []byte
	if err := s.DB.QueryRow("SELECT revision,body FROM vault_sync_items WHERE vault_id=? AND item_uuid=?",
		vaultID, cardID).Scan(&revision, &body); err != nil {
		t.Fatal(err)
	}
	if revision != 2 || string(body) != "card-restored" {
		t.Fatal("failed reference change partially updated the card row")
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM attachments WHERE vault_id=? AND attach_uuid=? AND content_version=?",
		vaultID, attachmentID, contentVersion).Scan(&activeCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM attachment_tombstones WHERE vault_id=? AND attach_uuid=?",
		vaultID, attachmentID).Scan(&tombstoneCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT retired_ms,unreferenced_ms FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?",
		vaultID, attachmentID, contentVersion).Scan(&retired, &unreferenced); err != nil {
		t.Fatal(err)
	}
	if activeCount != 1 || tombstoneCount != 0 || retired.Valid || unreferenced.Valid {
		t.Fatal("failed reference change partially retired or removed the attachment")
	}
}
