package api

import (
	"bytes"
	"database/sql"
	"encoding/base64"
	"strconv"
	"strings"
	"testing"
)

func TestRekeyRewrapsEveryAttachmentContentVersion(t *testing.T) {
	s, mail := testServer(t)
	token, _ := login(t, s, mail, "rekey-attachments-"+randomHex(5)+"@example.com")
	h := s.Handler()
	vaultID := newVault(t, h, token)
	attachmentID := "32345678-1234-4234-8234-123456789abc"
	cardID := "52345678-1234-4234-8234-123456789abc"
	legacyVersion := legacyAttachmentVersion
	versions := []string{
		legacyVersion,
		"42345678-1234-4234-8234-123456789abc",
		"62345678-1234-4234-8234-123456789abc",
	}
	created := now()
	oldWrapper := []byte("old-wrapped-data-encryption-key-value")
	newWrappers := make(map[string][]byte, len(versions))
	for index, version := range versions {
		old := append([]byte(nil), oldWrapper...)
		old[0] = byte(index + 1)
		newWrapper := append([]byte(nil), oldWrapper...)
		newWrapper[0] = byte(index + 11)
		newWrappers[version] = newWrapper
		objectKey := "vaults/" + vaultID + "/attachments/" + attachmentID + "/" + version + "/" + digest([]byte(version))
		if _, err := s.DB.Exec("INSERT INTO attachment_versions(vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms) VALUES(?,?,?,?,?,?,?,?,?)", vaultID, attachmentID, version, cardID, objectKey, old, digest([]byte(version)), 1, created); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.DB.Exec("INSERT INTO attachments(vault_id,attach_uuid,content_version,card_uuid,object_key,dek_wrapped,sha256,bytes,created_ms) VALUES(?,?,?,?,?,?,?,?,?)", vaultID, attachmentID, versions[2], cardID, "vaults/"+vaultID+"/attachments/"+attachmentID+"/"+versions[2]+"/"+digest([]byte(versions[2])), oldWrapper, digest([]byte("current")), 1, created); err != nil {
		t.Fatal(err)
	}
	base := "/v1/vaults/" + vaultID
	code, out := call(t, h, "POST", base+"/rekey/begin", token, map[string]any{
		"envelope": fakeEnvelope(), "itemCount": 0, "dekCount": len(versions),
	})
	if code != 201 {
		t.Fatalf("begin: %d %v", code, out)
	}
	rekeyPath := base + "/rekey/" + out["rekeyId"].(string)
	dekWraps := make([]map[string]string, 0, len(versions))
	for _, version := range versions {
		dekWraps = append(dekWraps, map[string]string{
			"uuid": attachmentID, "contentVersion": version, "dekB64": b64(newWrappers[version]),
		})
	}
	code, out = call(t, h, "POST", rekeyPath+"/chunk", token, map[string]any{"dekWraps": dekWraps})
	if code != 200 || out["dekStaged"] != float64(len(versions)) {
		t.Fatalf("stage wrappers: %d %v", code, out)
	}
	if code, out = call(t, h, "POST", rekeyPath+"/commit", token, map[string]any{}); code != 200 {
		t.Fatalf("commit: %d %v", code, out)
	}
	for _, version := range versions {
		var wrapper []byte
		if err := s.DB.QueryRow("SELECT dek_wrapped FROM attachment_versions WHERE vault_id=? AND attach_uuid=? AND content_version=?", vaultID, attachmentID, version).Scan(&wrapper); err != nil {
			t.Fatal(err)
		}
		if string(wrapper) != string(newWrappers[version]) {
			t.Fatalf("attachment version %s retained its old wrapper", version)
		}
	}
	var currentWrapper []byte
	if err := s.DB.QueryRow("SELECT dek_wrapped FROM attachments WHERE vault_id=? AND attach_uuid=?", vaultID, attachmentID).Scan(&currentWrapper); err != nil {
		t.Fatal(err)
	}
	if string(currentWrapper) != string(newWrappers[versions[2]]) {
		t.Fatal("active attachment wrapper was not synchronized")
	}
	var staged int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM rekey_attachment_staging").Scan(&staged); err != nil || staged != 0 {
		t.Fatalf("committed rekey retained staged wrappers: %d, %v", staged, err)
	}
}

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
	var conflictStages, conflictManifests int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM rekey_conflict_staging WHERE rekey_id=?", rid).Scan(&conflictStages); err != nil || conflictStages != 0 {
		t.Fatalf("abort left conflict staging rows: %d, %v", conflictStages, err)
	}
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM rekey_conflict_manifests WHERE rekey_id=?", rid).Scan(&conflictManifests); err != nil || conflictManifests != 0 {
		t.Fatalf("abort left conflict manifests: %d, %v", conflictManifests, err)
	}
	code, detail := call(t, h, "GET", base, token, nil)
	if code != 200 || detail["envelope"] != original["envelope"] || detail["passwordVersion"] != original["passwordVersion"] {
		t.Fatalf("abort changed active envelope/version: %d %v", code, detail)
	}
	if code, out = call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(id, 1, 0, "after-abort")}}); code != 200 || result(out)["status"] != "ok" {
		t.Fatalf("abort did not release write lock: %d %v", code, out)
	}
}

func TestRekeyMigratesOpenAndRetainedConflictCandidates(t *testing.T) {
	s, mail := testServer(t)
	token, _ := login(t, s, mail, "rekey-conflicts-"+randomHex(5)+"@example.com")
	h := s.Handler()
	vaultID := newVault(t, h, token)
	base := "/v1/vaults/" + vaultID
	largeCiphertext := strings.Repeat("a", 2<<20)
	itemIDs := []string{
		"12345678-1234-4234-8234-123456789001",
		"12345678-1234-4234-8234-123456789002",
	}
	type conflictFixture struct {
		id      string
		localID string
		itemID  string
	}
	fixtures := make([]conflictFixture, 0, len(itemIDs))
	for index, itemID := range itemIDs {
		if code, out := call(t, h, "POST", base+"/items", token, map[string]any{
			"items": []any{incoming(itemID, 1, 0, largeCiphertext)},
		}); code != 200 || result(out)["status"] != "ok" {
			t.Fatalf("create item %d: %d %v", index, code, out)
		}
		if code, out := call(t, h, "POST", base+"/items", token, map[string]any{
			"items": []any{incoming(itemID, 1, 0, "stale ciphertext")},
		}); code != 200 || result(out)["status"] != "conflict" {
			t.Fatalf("create conflict %d: %d %v", index, code, out)
		}
		localID := randomHex(16)
		fingerprint := localID + strings.Repeat("b", 32)
		code, registered := call(t, h, "POST", base+"/items/"+itemID+"/conflicts", token, map[string]any{
			"expectedRevision": 1, "baseRevision": 0, "candidateId": localID,
			"candidateFingerprint": fingerprint, "kind": 1, "op": "upsert",
			"bodyB64": b64([]byte(largeCiphertext)), "modifiedMs": 2000 + index,
		})
		if code != 200 || registered["candidateCount"] != float64(2) {
			t.Fatalf("register conflict %d: %d %v", index, code, registered)
		}
		fixtures = append(fixtures, conflictFixture{
			id: registered["conflictId"].(string), localID: localID, itemID: itemID,
		})
	}

	status, listed := call(t, h, "GET", base+"/conflicts", token, nil)
	if status != 200 {
		t.Fatalf("list open conflicts: %d %v", status, listed)
	}
	var resolvedConflictID string
	for _, raw := range listed["conflicts"].([]any) {
		group := raw.(map[string]any)
		if group["itemUuid"] != fixtures[0].itemID {
			continue
		}
		candidateIDs := make([]string, 0, len(group["candidates"].([]any)))
		for _, candidate := range group["candidates"].([]any) {
			candidateIDs = append(candidateIDs, candidate.(map[string]any)["candidateId"].(string))
		}
		code, out := call(t, h, "POST", base+"/conflicts/"+fixtures[0].id+"/resolve", token, map[string]any{
			"generation": group["generation"], "candidateIds": candidateIDs,
			"winnerCandidateId":       fixtures[0].localID,
			"expectedCurrentRevision": group["currentRevision"],
			"expectedDeletedSeq":      group["currentDeletedSeq"],
		})
		if code != 200 || out["status"] != "resolved" {
			t.Fatalf("resolve retained conflict: %d %v", code, out)
		}
		resolvedConflictID = fixtures[0].id
	}
	if resolvedConflictID == "" {
		t.Fatal("expected a conflict to resolve")
	}

	code, begun := call(t, h, "POST", base+"/rekey/begin", token, map[string]any{
		"envelope": fakeEnvelope(), "itemCount": len(itemIDs), "dekCount": 0,
	})
	if code != 201 || begun["conflictCount"] != float64(4) {
		t.Fatalf("begin rekey: %d %v", code, begun)
	}
	rekeyID := begun["rekeyId"].(string)
	rekeyPath := base + "/rekey/" + rekeyID
	rows, err := s.DB.Query("SELECT item_uuid,body FROM vault_sync_items WHERE vault_id=? ORDER BY item_uuid", vaultID)
	if err != nil {
		t.Fatal(err)
	}
	items := make([]map[string]string, 0, len(itemIDs))
	for rows.Next() {
		var itemID string
		var oldBody []byte
		if err = rows.Scan(&itemID, &oldBody); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		newBody := bytes.Repeat([]byte("n"), len(oldBody))
		items = append(items, map[string]string{
			"uuid": itemID, "bodyB64": b64(newBody), "sha256": digest(newBody),
		})
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		t.Fatal(err)
	}
	rows.Close()
	if len(items) != len(itemIDs) {
		t.Fatalf("expected %d live rows, got %d", len(itemIDs), len(items))
	}
	if code, out := call(t, h, "POST", rekeyPath+"/chunk", token, map[string]any{"items": items}); code != 200 || out["itemStaged"] != float64(len(items)) {
		t.Fatalf("stage item ciphertexts: %d %v", code, out)
	}
	if code, out := call(t, h, "POST", rekeyPath+"/commit", token, map[string]any{}); code != 409 || out["error"] != "rekey_incomplete" {
		t.Fatalf("commit without candidate staging: %d %v", code, out)
	}
	if code, current := call(t, h, "GET", base, token, nil); code != 200 || current["passwordVersion"] != float64(1) {
		t.Fatalf("incomplete rekey changed live password version: %d %v", code, current)
	}

	type candidateMapping struct {
		conflictID  string
		newID       string
		fingerprint string
		body        []byte
	}
	mappings := make(map[string]candidateMapping, 4)
	for offset := 0; offset < 4; {
		pagePath := rekeyPath + "/conflicts?offset=" + strconv.Itoa(offset) + "&limit=200"
		code, page := call(t, h, "GET", pagePath, token, nil)
		if code != 200 || page["totalCandidates"] != float64(4) || page["offset"] != float64(offset) {
			t.Fatalf("read rekey candidates at %d: %d %v", offset, code, page)
		}
		candidates := page["candidates"].([]any)
		if len(candidates) != 2 {
			t.Fatalf("2 MiB candidates should fill each byte-bounded page, got %d", len(candidates))
		}
		staged := make([]map[string]string, 0, len(candidates))
		for index, raw := range candidates {
			candidate := raw.(map[string]any)
			oldID := candidate["candidateId"].(string)
			conflictID := candidate["conflictId"].(string)
			oldBody, err := base64.StdEncoding.DecodeString(candidate["bodyB64"].(string))
			if err != nil {
				t.Fatal(err)
			}
			newID := randomHex(16)
			fingerprint := newID + strings.Repeat("c", 32)
			newBody := bytes.Repeat([]byte{byte(offset + index + 1)}, len(oldBody))
			mappings[conflictID+":"+oldID] = candidateMapping{
				conflictID: conflictID, newID: newID,
				fingerprint: fingerprint, body: newBody,
			}
			staged = append(staged, map[string]string{
				"conflictId": conflictID, "oldCandidateId": oldID,
				"candidateId": newID, "fingerprint": fingerprint,
				"bodyB64": b64(newBody), "sha256": digest(newBody),
			})
		}
		if offset == 0 {
			collisionID := randomHex(16)
			collisionFingerprint := collisionID + strings.Repeat("d", 32)
			collisions := make([]map[string]string, len(staged))
			for index, candidate := range staged {
				copyCandidate := make(map[string]string, len(candidate))
				for key, value := range candidate {
					copyCandidate[key] = value
				}
				copyCandidate["candidateId"] = collisionID
				copyCandidate["fingerprint"] = collisionFingerprint
				collisions[index] = copyCandidate
			}
			if code, out := call(t, h, "POST", rekeyPath+"/conflicts", token, map[string]any{"candidates": collisions}); code != 409 || out["error"] != "rekey_candidate_collision" {
				t.Fatalf("candidate collision accepted: %d %v", code, out)
			}
			var stagedCount int
			if err := s.DB.QueryRow("SELECT COUNT(*) FROM rekey_conflict_staging WHERE rekey_id=?", rekeyID).Scan(&stagedCount); err != nil || stagedCount != 0 {
				t.Fatalf("collision partially staged candidates: %d, %v", stagedCount, err)
			}
		}
		if code, out := call(t, h, "POST", rekeyPath+"/conflicts", token, map[string]any{"candidates": staged}); code != 200 || out["candidateStaged"] != float64(offset+len(staged)) {
			t.Fatalf("stage conflict page at %d: %d %v", offset, code, out)
		}
		offset += len(candidates)
	}
	if len(mappings) != 4 {
		t.Fatalf("expected four candidate mappings, got %d", len(mappings))
	}
	if code, out := call(t, h, "POST", rekeyPath+"/commit", token, map[string]any{}); code != 200 {
		t.Fatalf("commit rekey: %d %v", code, out)
	}

	var resolvedStatus, selectedID string
	if err := s.DB.QueryRow("SELECT status,selected_candidate_id FROM item_conflicts WHERE conflict_id=?", resolvedConflictID).Scan(&resolvedStatus, &selectedID); err != nil {
		t.Fatal(err)
	}
	winner := mappings[resolvedConflictID+":"+fixtures[0].localID]
	if resolvedStatus != "resolved" || selectedID != winner.newID {
		t.Fatalf("resolved candidate reference was not migrated: status=%s selected=%s want=%s", resolvedStatus, selectedID, winner.newID)
	}
	var winnerEventID string
	if err := s.DB.QueryRow("SELECT winner_candidate_id FROM item_changes WHERE vault_id=? AND conflict_id=? AND op=4", vaultID, resolvedConflictID).Scan(&winnerEventID); err != nil {
		t.Fatal(err)
	}
	if winnerEventID != winner.newID {
		t.Fatalf("resolution event candidate reference=%s want=%s", winnerEventID, winner.newID)
	}
	rows, err = s.DB.Query("SELECT c.conflict_id,x.candidate_id,x.candidate_fingerprint,x.body,x.body_sha256 FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=?", vaultID)
	if err != nil {
		t.Fatal(err)
	}
	seen := 0
	for rows.Next() {
		var conflictID, candidateID, fingerprint string
		var body []byte
		var sha sql.NullString
		if err = rows.Scan(&conflictID, &candidateID, &fingerprint, &body, &sha); err != nil {
			rows.Close()
			t.Fatal(err)
		}
		var mapping candidateMapping
		found := false
		for _, expected := range mappings {
			if expected.conflictID == conflictID && expected.newID == candidateID {
				mapping = expected
				found = true
				break
			}
		}
		if !found || fingerprint != mapping.fingerprint || !bytes.Equal(body, mapping.body) || !sha.Valid || sha.String != digest(mapping.body) {
			rows.Close()
			t.Fatalf("candidate ciphertext or identity mismatch: conflict=%s candidate=%s", conflictID, candidateID)
		}
		seen++
	}
	if err = rows.Err(); err != nil {
		rows.Close()
		t.Fatal(err)
	}
	rows.Close()
	if seen != 4 {
		t.Fatalf("expected four migrated open/retained candidates, got %d", seen)
	}
	var openStatus string
	if err := s.DB.QueryRow("SELECT status FROM item_conflicts WHERE conflict_id=?", fixtures[1].id).Scan(&openStatus); err != nil || openStatus != "open" {
		t.Fatalf("open conflict changed during rekey: status=%s err=%v", openStatus, err)
	}
}
