package api

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestConflictCandidatesAreEncryptedAndGenerationChecked(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "conflicts@example.test")
	vid := newVault(t, h, token)
	itemID := "123e4567-e89b-12d3-a456-426614174000"
	status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{incoming(itemID, 1, 0, "remote ciphertext")},
	})
	if status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("create item %d %v", status, out)
	}
	status, out = call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{incoming(itemID, 1, 0, "stale ciphertext")},
	})
	if status != 200 || result(out)["status"] != "conflict" {
		t.Fatalf("create CAS conflict %d %v", status, out)
	}
	status, _ = call(t, h, "PATCH", "/v1/auth/session", token, map[string]any{"deviceName": "renamed"})
	if status != 200 {
		t.Fatalf("rename session %d", status)
	}

	candidateID := randomHex(16)
	fingerprint := candidateID + candidateID
	request := map[string]any{
		"expectedRevision":     1,
		"baseRevision":         0,
		"candidateId":          candidateID,
		"candidateFingerprint": fingerprint,
		"kind":                 1,
		"op":                   "upsert",
		"bodyB64":              b64([]byte("local encrypted candidate")),
		"modifiedMs":           2000,
	}
	status, registered := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, request)
	if status != 200 || registered["candidateCount"] != float64(2) || registered["generation"] != float64(1) {
		t.Fatalf("register candidates %d %v", status, registered)
	}

	status, listed := call(t, h, "GET", "/v1/vaults/"+vid+"/conflicts", token, nil)
	if status != 200 {
		t.Fatalf("list candidates %d %v", status, listed)
	}
	groups, ok := listed["conflicts"].([]any)
	if !ok || len(groups) != 1 {
		t.Fatalf("unexpected conflict list %v", listed)
	}
	group := groups[0].(map[string]any)
	if group["itemUuid"] != itemID || group["generation"] != float64(1) {
		t.Fatalf("unexpected conflict group %v", group)
	}
	candidates, ok := group["candidates"].([]any)
	if !ok || len(candidates) != 2 {
		t.Fatalf("unexpected candidates %v", group)
	}
	origins := map[string]string{}
	for _, raw := range candidates {
		candidate := raw.(map[string]any)
		body, err := base64.StdEncoding.DecodeString(candidate["bodyB64"].(string))
		if err != nil {
			t.Fatal(err)
		}
		origins[string(body)] = candidate["deviceName"].(string)
		if candidate["platform"] != "macos" || candidate["committedMs"] == nil {
			t.Fatalf("candidate origin metadata missing: %v", candidate)
		}
	}
	if origins["remote ciphertext"] != "test" || origins["local encrypted candidate"] != "renamed" {
		t.Fatalf("candidate origin snapshots are incorrect: %v", origins)
	}

	request["bodyB64"] = b64([]byte("same logical candidate, new random nonce"))
	request["modifiedMs"] = 2500
	status, duplicate := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, request)
	if status != 200 || duplicate["generation"] != float64(1) || duplicate["candidateCount"] != float64(2) {
		t.Fatalf("idempotent registration %d %v", status, duplicate)
	}
	request["candidateFingerprint"] = candidateID + strings.Repeat("b", 32)
	status, reused := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, request)
	if status != 409 || reused["error"] != "candidate_id_reused" {
		t.Fatalf("candidate ID accepted changed content: %d %v", status, reused)
	}

	request["expectedRevision"] = 2
	status, stale := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, request)
	if status != 409 || stale["error"] != "conflict_stale" {
		t.Fatalf("stale revision accepted: %d %v", status, stale)
	}
}

func TestConflictCandidatePreservesLocalEditAgainstRemoteDelete(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "deleted-conflict@example.test")
	vid := newVault(t, h, token)
	itemID := "123e4567-e89b-12d3-a456-426614174001"
	status, created := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{incoming(itemID, 1, 0, "remote before delete")},
	})
	if status != 200 || result(created)["status"] != "ok" {
		t.Fatalf("create item %d %v", status, created)
	}
	status, deleted := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{{
			"uuid": itemID, "kind": 1, "op": "delete", "baseRevision": 1, "modifiedMs": 3000,
		}},
	})
	if status != 200 || result(deleted)["status"] != "ok" {
		t.Fatalf("delete item %d %v", status, deleted)
	}
	var deletedRevision, deletedSeq int64
	if err := s.DB.QueryRow("SELECT revision,seq FROM item_changes WHERE vault_id=? AND item_uuid=? AND op=2 ORDER BY seq DESC LIMIT 1", vid, itemID).Scan(&deletedRevision, &deletedSeq); err != nil {
		t.Fatal(err)
	}
	fingerprint := strings.Repeat("c", 64)
	request := map[string]any{
		"expectedRevision":     deletedRevision,
		"expectedDeletedSeq":   deletedSeq,
		"baseRevision":         1,
		"candidateId":          fingerprint[:32],
		"candidateFingerprint": fingerprint,
		"kind":                 1,
		"op":                   "upsert",
		"bodyB64":              b64([]byte("local encrypted recovery candidate")),
		"modifiedMs":           4000,
	}
	status, registered := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, request)
	if status != 200 || registered["candidateCount"] != float64(2) || registered["currentRevision"] != float64(deletedRevision) {
		t.Fatalf("register deleted conflict %d %v", status, registered)
	}
	status, listed := call(t, h, "GET", "/v1/vaults/"+vid+"/conflicts", token, nil)
	groups, ok := listed["conflicts"].([]any)
	if status != 200 || !ok || len(groups) != 1 {
		t.Fatalf("list deleted conflict %d %v", status, listed)
	}
	candidates := groups[0].(map[string]any)["candidates"].([]any)
	if len(candidates) != 2 {
		t.Fatalf("expected delete and recovery candidates, got %v", candidates)
	}
	ops := map[string]bool{}
	for _, raw := range candidates {
		candidate := raw.(map[string]any)
		ops[candidate["op"].(string)] = true
		if candidate["op"] == "delete" && candidate["bodyB64"] != nil {
			t.Fatalf("delete candidate unexpectedly has a body: %v", candidate)
		}
	}
	if !ops["delete"] || !ops["upsert"] {
		t.Fatalf("remote deletion and local edit were not both retained: %v", ops)
	}

	request["expectedDeletedSeq"] = deletedSeq + 1
	status, stale := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, request)
	if status != 409 || stale["error"] != "conflict_stale" {
		t.Fatalf("stale deletion event accepted: %d %v", status, stale)
	}
}

func TestConflictResolveChecksCASAndComposesEncryptedBody(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "resolve-live@example.test")
	vid := newVault(t, h, token)
	itemID := "123e4567-e89b-12d3-a456-426614174010"
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{incoming(itemID, 1, 0, "remote ciphertext")},
	}); status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("create item %d %v", status, out)
	}
	var createdSeq int64
	if err := s.DB.QueryRow("SELECT seq FROM item_changes WHERE vault_id=? AND item_uuid=? AND op=1 ORDER BY seq DESC LIMIT 1", vid, itemID).Scan(&createdSeq); err != nil {
		t.Fatal(err)
	}
	candidateID := randomHex(16)
	fingerprint := candidateID + candidateID
	register := map[string]any{
		"expectedRevision":     1,
		"baseRevision":         0,
		"candidateId":          candidateID,
		"candidateFingerprint": fingerprint,
		"kind":                 1,
		"op":                   "upsert",
		"bodyB64":              b64([]byte("local ciphertext")),
		"modifiedMs":           5000,
	}
	status, registered := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, register)
	if status != 200 {
		t.Fatalf("register conflict %d %v", status, registered)
	}
	status, listed := call(t, h, "GET", "/v1/vaults/"+vid+"/conflicts", token, nil)
	if status != 200 {
		t.Fatalf("list conflict %d %v", status, listed)
	}
	groups := listed["conflicts"].([]any)
	group := groups[0].(map[string]any)
	candidates := group["candidates"].([]any)
	candidateIDs := make([]string, 0, len(candidates))
	for _, raw := range candidates {
		candidateIDs = append(candidateIDs, raw.(map[string]any)["candidateId"].(string))
	}
	resolve := map[string]any{
		"generation":              group["generation"],
		"candidateIds":            candidateIDs,
		"winnerCandidateId":       candidateID,
		"expectedCurrentRevision": group["currentRevision"],
		"expectedDeletedSeq":      group["currentDeletedSeq"],
		"attachmentRefs":          []any{},
	}
	changedSet := append([]string(nil), candidateIDs...)
	changedSet[0] = randomHex(16)
	resolve["candidateIds"] = changedSet
	status, staleSet := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, resolve)
	if status != 409 || staleSet["error"] != "conflict_candidates_changed" {
		t.Fatalf("changed candidate set accepted: %d %v", status, staleSet)
	}
	resolve["candidateIds"] = candidateIDs
	resolve["generation"] = float64(0)
	status, staleGeneration := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, resolve)
	if status != 409 || staleGeneration["error"] != "conflict_stale" {
		t.Fatalf("stale generation accepted: %d %v", status, staleGeneration)
	}
	resolve["generation"] = group["generation"]
	mergedCiphertext := []byte("client-composed ciphertext")
	resolve["mergedBodyB64"] = b64(mergedCiphertext)
	status, incomplete := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, resolve)
	if status != 400 || incomplete["error"] != "bad_request" {
		t.Fatalf("incomplete composition accepted: %d %v", status, incomplete)
	}
	delete(resolve, "mergedModifiedMs")
	resolve["mergedBodyB64"] = ""
	status, emptyComposition := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, resolve)
	if status != 400 || emptyComposition["error"] != "bad_request" {
		t.Fatalf("empty composition treated as candidate selection: %d %v", status, emptyComposition)
	}
	resolve["mergedBodyB64"] = b64(mergedCiphertext)
	resolve["mergedModifiedMs"] = 6000
	status, resolved := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, resolve)
	if status != 200 || resolved["status"] != "resolved" || resolved["itemUuid"] != itemID {
		t.Fatalf("resolve composed body %d %v", status, resolved)
	}
	var revision, modified int64
	var body []byte
	if err := s.DB.QueryRow("SELECT revision,body,modified_ms FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&revision, &body, &modified); err != nil {
		t.Fatal(err)
	}
	if revision != 2 || string(body) != string(mergedCiphertext) || modified != 6000 {
		t.Fatalf("unexpected composed row revision=%d modified=%d body=%q", revision, modified, body)
	}
	status, changes := call(t, h, "GET", fmt.Sprintf("/v1/vaults/%s/changes?since=%d", vid, createdSeq), token, nil)
	events, ok := changes["changes"].([]any)
	if status != 200 || !ok || len(events) != 1 {
		t.Fatalf("resolution change event missing: %d %v", status, changes)
	}
	event := events[0].(map[string]any)
	if event["op"] != "resolve" || event["uuid"] != itemID || event["resolvedItemUuid"] != itemID ||
		event["revision"] != float64(2) || event["resolvedRevision"] != float64(2) ||
		event["winnerCandidateId"] != candidateID || event["winnerOp"] != "upsert" ||
		event["resolutionType"] != "composed" ||
		event["baseRevision"] != float64(0) ||
		event["bodyB64"] != b64(mergedCiphertext) || event["modifiedMs"] != float64(6000) || event["kind"] != float64(1) || event["deleted"] != nil {
		t.Fatalf("unexpected active resolution event: %v", event)
	}
	var retained, expires int
	if err := s.DB.QueryRow("SELECT COUNT(*),COUNT(expires_ms) FROM item_conflict_candidates WHERE conflict_id=? AND disposition='retained'", group["conflictId"]).Scan(&retained, &expires); err != nil {
		t.Fatal(err)
	}
	if retained != 2 || expires != 2 {
		t.Fatalf("unselected candidate was not retained: count=%d expires=%d", retained, expires)
	}
}

func TestConflictResolveDeletionWinnerWritesTombstone(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "resolve-delete@example.test")
	vid := newVault(t, h, token)
	itemID := "123e4567-e89b-12d3-a456-426614174013"
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{incoming(itemID, 1, 0, "remote ciphertext")},
	}); status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("create item %d %v", status, out)
	}
	var createdSeq int64
	if err := s.DB.QueryRow("SELECT seq FROM item_changes WHERE vault_id=? AND item_uuid=? AND op=1 ORDER BY seq DESC LIMIT 1", vid, itemID).Scan(&createdSeq); err != nil {
		t.Fatal(err)
	}
	candidateID := randomHex(16)
	fingerprint := candidateID + candidateID
	status, registered := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, map[string]any{
		"expectedRevision":     1,
		"baseRevision":         0,
		"candidateId":          candidateID,
		"candidateFingerprint": fingerprint,
		"kind":                 1,
		"op":                   "delete",
		"modifiedMs":           9000,
	})
	if status != 200 {
		t.Fatalf("register deletion candidate %d %v", status, registered)
	}
	status, listed := call(t, h, "GET", "/v1/vaults/"+vid+"/conflicts", token, nil)
	if status != 200 {
		t.Fatalf("list conflict %d %v", status, listed)
	}
	group := listed["conflicts"].([]any)[0].(map[string]any)
	candidates := group["candidates"].([]any)
	candidateIDs := make([]string, 0, len(candidates))
	for _, raw := range candidates {
		candidateIDs = append(candidateIDs, raw.(map[string]any)["candidateId"].(string))
	}
	status, resolved := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, map[string]any{
		"generation":              group["generation"],
		"candidateIds":            candidateIDs,
		"winnerCandidateId":       candidateID,
		"expectedCurrentRevision": group["currentRevision"],
		"expectedDeletedSeq":      group["currentDeletedSeq"],
	})
	if status != 200 || resolved["itemUuid"] != nil {
		t.Fatalf("resolve deletion winner %d %v", status, resolved)
	}
	var liveCount int
	var deletedRevision int64
	var itemCount int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&liveCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT revision FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&deletedRevision); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT item_count FROM vaults WHERE vault_id=?", vid).Scan(&itemCount); err != nil {
		t.Fatal(err)
	}
	if liveCount != 0 || deletedRevision != 2 || itemCount != 0 {
		t.Fatalf("delete resolution mismatch: live=%d deletedRevision=%d count=%d", liveCount, deletedRevision, itemCount)
	}
	status, changes := call(t, h, "GET", fmt.Sprintf("/v1/vaults/%s/changes?since=%d", vid, createdSeq), token, nil)
	events, ok := changes["changes"].([]any)
	if status != 200 || !ok || len(events) != 1 {
		t.Fatalf("deletion resolution event missing: %d %v", status, changes)
	}
	event := events[0].(map[string]any)
	if event["op"] != "resolve" || event["uuid"] != itemID || event["resolvedItemUuid"] != nil ||
		event["winnerCandidateId"] != candidateID || event["winnerOp"] != "delete" ||
		event["deleted"] != true {
		t.Fatalf("unexpected deletion resolution event: %v", event)
	}
}

func TestConflictResolveActivatesSelectedAttachmentVersion(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "resolve-attachment@example.test")
	vid := newVault(t, h, token)
	itemID := "123e4567-e89b-12d3-a456-426614174021"
	attachmentID := "223e4567-e89b-12d3-a456-426614174021"
	versionOne := "323e4567-e89b-12d3-a456-426614174021"
	versionTwo := "423e4567-e89b-12d3-a456-426614174021"
	for _, version := range []string{versionOne, versionTwo} {
		if _, err := s.DB.Exec("INSERT INTO attachment_versions(vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms) VALUES(?,?,?,?,?,?,?,?,?)", vid, attachmentID, version, itemID, "test-object-"+version, bytes.Repeat([]byte{1}, 40), strings.Repeat("a", 64), 10, now()); err != nil {
			t.Fatal(err)
		}
	}
	initial := incoming(itemID, 1, 0, "current ciphertext")
	initial["attachmentRefs"] = []any{map[string]any{"attachmentId": attachmentID, "contentVersion": versionOne}}
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{"items": []any{initial}}); status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("create item with attachment %d %v", status, out)
	}
	candidateID := randomHex(16)
	status, registered := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, map[string]any{
		"expectedRevision": 1, "baseRevision": 0,
		"candidateId": candidateID, "candidateFingerprint": candidateID + candidateID,
		"kind": 1, "op": "upsert", "bodyB64": b64([]byte("winning ciphertext")), "modifiedMs": 8000,
	})
	if status != 200 {
		t.Fatalf("register candidate %d %v", status, registered)
	}
	status, listed := call(t, h, "GET", "/v1/vaults/"+vid+"/conflicts", token, nil)
	if status != 200 {
		t.Fatalf("list conflict %d %v", status, listed)
	}
	group := listed["conflicts"].([]any)[0].(map[string]any)
	candidates := group["candidates"].([]any)
	candidateIDs := make([]string, 0, len(candidates))
	for _, raw := range candidates {
		candidateIDs = append(candidateIDs, raw.(map[string]any)["candidateId"].(string))
	}
	legacyPayload := map[string]any{
		"generation": group["generation"], "candidateIds": candidateIDs,
		"winnerCandidateId":       candidateID,
		"expectedCurrentRevision": group["currentRevision"],
		"expectedDeletedSeq":      group["currentDeletedSeq"],
	}
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, legacyPayload); status != 409 || out["error"] != "conflict_attachments_pending" {
		t.Fatalf("legacy resolver must remain fail-closed for attachments: %d %v", status, out)
	}
	status, resolved := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, map[string]any{
		"generation": group["generation"], "candidateIds": candidateIDs,
		"winnerCandidateId":       candidateID,
		"expectedCurrentRevision": group["currentRevision"], "expectedDeletedSeq": group["currentDeletedSeq"],
		"attachmentRefs": []any{map[string]any{"attachmentId": attachmentID, "contentVersion": versionTwo}},
	})
	if status != 200 || resolved["itemUuid"] != itemID {
		t.Fatalf("resolve candidate with attachment %d %v", status, resolved)
	}
	var activeVersion string
	if err := s.DB.QueryRow("SELECT content_version FROM attachments WHERE vault_id=? AND attach_uuid=? AND card_uuid=?", vid, attachmentID, itemID).Scan(&activeVersion); err != nil {
		t.Fatal(err)
	}
	var retired bool
	if err := s.DB.QueryRow("SELECT retired_ms IS NOT NULL FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?", vid, attachmentID, versionOne).Scan(&retired); err != nil {
		t.Fatal(err)
	}
	if activeVersion != versionTwo || !retired {
		t.Fatalf("selected attachment version not activated: active=%s oldRetired=%t", activeVersion, retired)
	}
}

func TestDeletedConflictResolveRestoresWithNewIdentityAndTombstone(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "resolve-deleted@example.test")
	vid := newVault(t, h, token)
	itemID := "123e4567-e89b-12d3-a456-426614174011"
	attachmentID := "223e4567-e89b-12d3-a456-426614174011"
	contentVersion := "323e4567-e89b-12d3-a456-426614174011"
	if _, err := s.DB.Exec("INSERT INTO attachment_versions(vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms) VALUES(?,?,?,?,?,?,?,?,?)", vid, attachmentID, contentVersion, itemID, "test-object", bytes.Repeat([]byte{1}, 40), strings.Repeat("a", 64), 10, now()); err != nil {
		t.Fatal(err)
	}
	initial := incoming(itemID, 1, 0, "before delete")
	initial["attachmentRefs"] = []any{map[string]any{"attachmentId": attachmentID, "contentVersion": contentVersion}}
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{initial},
	}); status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("create item %d %v", status, out)
	}
	if status, out := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{{"uuid": itemID, "kind": 1, "op": "delete", "baseRevision": 1, "modifiedMs": 6000}},
	}); status != 200 || result(out)["status"] != "ok" {
		t.Fatalf("delete item %d %v", status, out)
	}
	var deletedRevision, deletedSeq int64
	if err := s.DB.QueryRow("SELECT revision,seq FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&deletedRevision, &deletedSeq); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DB.Exec("DELETE FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID); err != nil {
		t.Fatal(err)
	}
	migration, err := os.ReadFile(filepath.Join("..", "..", "..", "database", "0005_conflict_resolution.sql"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.DB.Exec(string(migration)); err != nil {
		t.Fatalf("reapply tombstone backfill: %v", err)
	}
	var backfilledRevision, backfilledSeq int64
	if err = s.DB.QueryRow("SELECT revision,seq FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&backfilledRevision, &backfilledSeq); err != nil {
		t.Fatal(err)
	}
	if backfilledRevision != deletedRevision || backfilledSeq != deletedSeq {
		t.Fatalf("tombstone backfill mismatch: revision=%d seq=%d", backfilledRevision, backfilledSeq)
	}
	if _, err := s.DB.Exec("DELETE FROM item_changes WHERE vault_id=? AND item_uuid=?", vid, itemID); err != nil {
		t.Fatal(err)
	}
	candidateID := randomHex(16)
	fingerprint := candidateID + candidateID
	status, registered := call(t, h, "POST", "/v1/vaults/"+vid+"/items/"+itemID+"/conflicts", token, map[string]any{
		"expectedRevision":     deletedRevision,
		"expectedDeletedSeq":   deletedSeq,
		"baseRevision":         1,
		"candidateId":          candidateID,
		"candidateFingerprint": fingerprint,
		"kind":                 1,
		"op":                   "upsert",
		"bodyB64":              b64([]byte("encrypted local recovery")),
		"modifiedMs":           7000,
	})
	if status != 200 {
		t.Fatalf("register deleted conflict %d %v", status, registered)
	}
	status, listed := call(t, h, "GET", "/v1/vaults/"+vid+"/conflicts", token, nil)
	if status != 200 {
		t.Fatalf("list conflict %d %v", status, listed)
	}
	group := listed["conflicts"].([]any)[0].(map[string]any)
	candidates := group["candidates"].([]any)
	candidateIDs := make([]string, 0, len(candidates))
	for _, raw := range candidates {
		candidateIDs = append(candidateIDs, raw.(map[string]any)["candidateId"].(string))
	}
	newItemID := "123e4567-e89b-12d3-a456-426614174012"
	status, resolved := call(t, h, "POST", "/v1/vaults/"+vid+"/conflicts/"+group["conflictId"].(string)+"/resolve", token, map[string]any{
		"generation":              group["generation"],
		"candidateIds":            candidateIDs,
		"winnerCandidateId":       candidateID,
		"expectedCurrentRevision": group["currentRevision"],
		"expectedDeletedSeq":      group["currentDeletedSeq"],
		"restoreItemUuid":         newItemID,
		"bodyB64":                 b64([]byte("reencrypted for new identity")),
		"attachmentRefs": []any{map[string]any{
			"attachmentId": attachmentID, "contentVersion": contentVersion,
			"restoreDeleted": true,
		}},
	})
	if status != 200 || resolved["itemUuid"] != newItemID {
		t.Fatalf("restore deleted candidate %d %v", status, resolved)
	}
	var originalCount, restoredCount, tombstones, itemCount int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&originalCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vault_sync_items WHERE vault_id=? AND item_uuid=?", vid, newItemID).Scan(&restoredCount); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&tombstones); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT item_count FROM vaults WHERE vault_id=?", vid).Scan(&itemCount); err != nil {
		t.Fatal(err)
	}
	if originalCount != 0 || restoredCount != 1 || tombstones != 1 || itemCount != 1 {
		t.Fatalf("unexpected restored identities original=%d restored=%d tombstone=%d count=%d", originalCount, restoredCount, tombstones, itemCount)
	}
	var activeCardID, activeVersion, versionOwner string
	if err := s.DB.QueryRow("SELECT card_uuid,content_version FROM attachments WHERE vault_id=? AND attach_uuid=?", vid, attachmentID).Scan(&activeCardID, &activeVersion); err != nil {
		t.Fatal(err)
	}
	if err := s.DB.QueryRow("SELECT card_uuid FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?", vid, attachmentID, contentVersion).Scan(&versionOwner); err != nil {
		t.Fatal(err)
	}
	if activeCardID != newItemID || activeVersion != contentVersion || versionOwner != newItemID {
		t.Fatalf("attachment identity was not restored atomically: active=%s version=%s owner=%s", activeCardID, activeVersion, versionOwner)
	}
	status, changes := call(t, h, "GET", fmt.Sprintf("/v1/vaults/%s/changes?since=%d", vid, deletedSeq), token, nil)
	events, ok := changes["changes"].([]any)
	if status != 200 || !ok || len(events) != 1 {
		t.Fatalf("restoration resolution event missing: %d %v", status, changes)
	}
	event := events[0].(map[string]any)
	if event["op"] != "resolve" || event["uuid"] != itemID || event["resolvedItemUuid"] != newItemID ||
		event["revision"] != float64(deletedRevision) || event["resolvedRevision"] != float64(1) ||
		event["winnerCandidateId"] != candidateID || event["winnerOp"] != "upsert" ||
		event["baseRevision"] != float64(1) ||
		event["bodyB64"] != b64([]byte("reencrypted for new identity")) || event["kind"] != float64(1) || event["deleted"] != nil {
		t.Fatalf("unexpected restoration resolution event: %v", event)
	}
	var tombstoneRevision, tombstoneSeq int64
	if err := s.DB.QueryRow("SELECT revision,seq FROM item_tombstones WHERE vault_id=? AND item_uuid=?", vid, itemID).Scan(&tombstoneRevision, &tombstoneSeq); err != nil {
		t.Fatal(err)
	}
	if tombstoneRevision != deletedRevision || tombstoneSeq != int64(event["seq"].(float64)) {
		t.Fatalf("restoration did not advance source tombstone: revision=%d seq=%d event=%v", tombstoneRevision, tombstoneSeq, event)
	}
	if _, err := s.DB.Exec("INSERT INTO vault_items(vault_id,item_uuid,kind,revision,body,body_sha256,body_bytes,modified_ms,created_ms,updated_ms) VALUES(?,?,1,1,?,?,?,8000,?,?)", vid, itemID, []byte("legacy resurrection"), digest([]byte("legacy resurrection")), len("legacy resurrection"), now(), now()); err != nil {
		t.Fatal(err)
	}
	status, stale := call(t, h, "POST", "/v1/vaults/"+vid+"/items", token, map[string]any{
		"items": []map[string]any{incoming(itemID, 1, 1, "resurrection attempt")},
	})
	if status != 409 || stale["error"] != "item_deleted" {
		t.Fatalf("legacy UUID reuse alongside a tombstone was not blocked: %d %v", status, stale)
	}
}
