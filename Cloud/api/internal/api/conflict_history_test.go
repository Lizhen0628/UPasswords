package api

import (
	"fmt"
	"testing"
)

func TestConflictHistoryPagesRetainedCandidatesAtFixedSnapshot(t *testing.T) {
	s, mail := testServer(t)
	h := s.Handler()
	token, _ := login(t, s, mail, "conflict-history@example.test")
	vid := newVault(t, h, token)
	baseTime := now()
	itemID := "123e4567-e89b-12d3-a456-426614174099"

	addResolved := func(resolvedMS, expiresMS int64) (string, string, string, string) {
		t.Helper()
		conflictID := randomHex(16)
		candidateID := randomHex(16)
		selectedID := candidateID
		unselectedID := randomHex(16)
		_, err := s.DB.Exec(`
			INSERT INTO item_conflicts(
				conflict_id,vault_id,item_uuid,base_revision,current_revision,current_deleted_seq,
				generation,status,created_ms,updated_ms,resolved_ms,expires_ms,
				selected_candidate_id,resolved_item_uuid
			) VALUES(?,?,?,?,?,0,1,'resolved',?,?,?,?,?,NULL)`,
			conflictID, vid, itemID, 1, 2,
			resolvedMS-1, resolvedMS, resolvedMS, expiresMS, selectedID)
		if err != nil {
			t.Fatal(err)
		}
		body := []byte("retained encrypted candidate")
		_, err = s.DB.Exec(`
			INSERT INTO item_conflict_candidates(
				candidate_id,conflict_id,kind,op,revision,body,body_sha256,candidate_fingerprint,
				modified_ms,source_session_id,source_device_name,source_platform,committed_ms,
				disposition,expires_ms
			) VALUES(?,?,1,1,2,?,?,NULL,?,NULL,'Laptop','macos',?,'retained',?)`,
			candidateID, conflictID, body, digest(body), resolvedMS-2, resolvedMS-1, expiresMS)
		if err != nil {
			t.Fatal(err)
		}
		_, err = s.DB.Exec(`
			INSERT INTO item_conflict_candidates(
				candidate_id,conflict_id,kind,op,revision,body,body_sha256,candidate_fingerprint,
				modified_ms,source_session_id,source_device_name,source_platform,committed_ms,
				disposition,expires_ms
			) VALUES(?,?,1,2,2,NULL,NULL,NULL,?,NULL,'Phone','ios',?,'retained',?)`,
			unselectedID, conflictID, resolvedMS-1, resolvedMS, expiresMS)
		if err != nil {
			t.Fatal(err)
		}
		return conflictID, candidateID, selectedID, unselectedID
	}

	firstConflictID, firstCandidateID, firstSelectedID, firstUnselectedID := addResolved(
		baseTime-2_000,
		baseTime+30*dayMS)
	secondConflictID, secondCandidateID, secondSelectedID, secondUnselectedID := addResolved(
		baseTime-1_000,
		baseTime+30*dayMS)
	_, _, _, _ = addResolved(baseTime-40*dayMS, baseTime-10*dayMS)

	status, first := call(
		t,
		h,
		"GET",
		fmt.Sprintf("/v1/vaults/%s/conflict-history?limit=1", vid),
		token,
		nil)
	if status != 200 {
		t.Fatalf("list first conflict history page %d %v", status, first)
	}
	firstRows, ok := first["candidates"].([]any)
	if !ok || len(firstRows) != 1 || first["totalCandidates"] != float64(4) {
		t.Fatalf("unexpected first conflict history page %v", first)
	}
	firstRow := firstRows[0].(map[string]any)
	firstCandidate := firstRow["candidate"].(map[string]any)
	if firstRow["conflictId"] != firstConflictID || firstCandidate["candidateId"] != firstCandidateID ||
		firstRow["selectedCandidateId"] != firstSelectedID {
		t.Fatalf("selected candidate metadata or history order changed: %v", firstRow)
	}
	cursor, ok := first["nextCursor"].(string)
	if !ok || cursor == "" {
		t.Fatalf("missing history cursor: %v", first)
	}
	snapshotMS := int64(first["snapshotMs"].(float64))
	addResolved(snapshotMS+1, snapshotMS+30*dayMS)

	status, second := call(
		t,
		h,
		"GET",
		fmt.Sprintf("/v1/vaults/%s/conflict-history?limit=1&cursor=%s", vid, cursor),
		token,
		nil)
	if status != 200 {
		t.Fatalf("list second conflict history page %d %v", status, second)
	}
	secondRows, ok := second["candidates"].([]any)
	if !ok || len(secondRows) != 1 || second["snapshotMs"] != first["snapshotMs"] ||
		second["totalCandidates"] != first["totalCandidates"] {
		t.Fatalf("unexpected second conflict history page %v", second)
	}
	secondRow := secondRows[0].(map[string]any)
	secondCandidate := secondRow["candidate"].(map[string]any)
	secondCursor, ok := second["nextCursor"].(string)
	if secondRow["conflictId"] != firstConflictID || secondCandidate["candidateId"] != firstUnselectedID ||
		!ok || secondCursor == "" {
		t.Fatalf("unselected retained candidate missing from history: %v", secondRow)
	}

	status, third := call(
		t,
		h,
		"GET",
		fmt.Sprintf("/v1/vaults/%s/conflict-history?limit=1&cursor=%s", vid, secondCursor),
		token,
		nil)
	if status != 200 {
		t.Fatalf("list third conflict history page %d %v", status, third)
	}
	thirdRows, ok := third["candidates"].([]any)
	if !ok || len(thirdRows) != 1 || third["snapshotMs"] != first["snapshotMs"] ||
		third["totalCandidates"] != first["totalCandidates"] {
		t.Fatalf("unexpected third conflict history page %v", third)
	}
	thirdRow := thirdRows[0].(map[string]any)
	thirdCandidate := thirdRow["candidate"].(map[string]any)
	thirdCursor, ok := third["nextCursor"].(string)
	if thirdRow["conflictId"] != secondConflictID || thirdCandidate["candidateId"] != secondCandidateID ||
		thirdRow["selectedCandidateId"] != secondSelectedID || !ok || thirdCursor == "" {
		t.Fatalf("unexpected third conflict history candidate: %v", thirdRow)
	}

	status, fourth := call(
		t,
		h,
		"GET",
		fmt.Sprintf("/v1/vaults/%s/conflict-history?limit=1&cursor=%s", vid, thirdCursor),
		token,
		nil)
	if status != 200 {
		t.Fatalf("list fourth conflict history page %d %v", status, fourth)
	}
	fourthRows, ok := fourth["candidates"].([]any)
	if !ok || len(fourthRows) != 1 || fourth["snapshotMs"] != first["snapshotMs"] ||
		fourth["totalCandidates"] != first["totalCandidates"] || fourth["nextCursor"] != nil {
		t.Fatalf("unexpected fourth conflict history page %v", fourth)
	}
	fourthRow := fourthRows[0].(map[string]any)
	fourthCandidate := fourthRow["candidate"].(map[string]any)
	if fourthRow["conflictId"] != secondConflictID || fourthCandidate["candidateId"] != secondUnselectedID ||
		fourthCandidate["op"] != "delete" {
		t.Fatalf("late resolution entered history or unselected delete was omitted: %v", fourthRow)
	}

	status, malformed := call(
		t,
		h,
		"GET",
		fmt.Sprintf("/v1/vaults/%s/conflict-history?cursor=invalid", vid),
		token,
		nil)
	if status != 400 || malformed["error"] != "bad_request" {
		t.Fatalf("malformed cursor accepted: %d %v", status, malformed)
	}
}
