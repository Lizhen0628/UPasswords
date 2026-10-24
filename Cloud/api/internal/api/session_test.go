package api

import "testing"

func TestSessionManagementAndAccountDeregistration(t *testing.T) {
	s, m := testServer(t)
	h := s.Handler()
	email := "sessions-" + randomHex(5) + "@example.com"
	firstToken, firstUserID := login(t, s, m, email)
	vid := newVault(t, h, firstToken)

	status, listed := call(t, h, "GET", "/v1/auth/sessions", firstToken, nil)
	sessions := listed["sessions"].([]any)
	if status != 200 || len(sessions) != 1 || sessions[0].(map[string]any)["current"] != true {
		t.Fatalf("initial session listing: %d %v", status, listed)
	}
	firstSessionID := sessions[0].(map[string]any)["id"].(string)
	if status, _ = call(t, h, "PATCH", "/v1/auth/session", firstToken, map[string]any{"deviceName": "Renamed Device"}); status != 200 {
		t.Fatalf("rename session returned %d", status)
	}
	status, listed = call(t, h, "GET", "/v1/auth/sessions", firstToken, nil)
	sessions = listed["sessions"].([]any)
	if status != 200 || sessions[0].(map[string]any)["deviceName"] != "Renamed Device" {
		t.Fatalf("renamed session missing: %d %v", status, listed)
	}

	if _, err := s.DB.Exec("UPDATE email_codes SET created_ms=created_ms-120000 WHERE email_hmc=?", s.mac("email:"+email)); err != nil {
		t.Fatal(err)
	}
	if status, _ = call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": email}); status != 202 {
		t.Fatalf("second device code request returned %d", status)
	}
	status, secondLogin := call(t, h, "POST", "/v1/auth/verify", "", map[string]any{
		"email": email, "code": m.get(email, "login"), "deviceName": "Second Device", "platform": "ios",
	})
	if status != 200 {
		t.Fatalf("second login returned %d: %v", status, secondLogin)
	}
	secondToken := secondLogin["token"].(string)
	status, listed = call(t, h, "GET", "/v1/auth/sessions", secondToken, nil)
	sessions = listed["sessions"].([]any)
	current := 0
	for _, raw := range sessions {
		session := raw.(map[string]any)
		if session["current"] == true {
			current++
			if session["deviceName"] != "Second Device" || session["platform"] != "ios" {
				t.Fatalf("second device metadata missing: %v", session)
			}
		}
	}
	if status != 200 || len(sessions) != 2 || current != 1 {
		t.Fatalf("multi-device session listing: %d %v", status, listed)
	}
	if status, _ = call(t, h, "DELETE", "/v1/auth/sessions/"+firstSessionID, secondToken, nil); status != 200 {
		t.Fatalf("revoke another session returned %d", status)
	}
	if status, _ = call(t, h, "GET", "/v1/vaults", firstToken, nil); status != 401 {
		t.Fatalf("revoked session returned %d", status)
	}
	if status, _ = call(t, h, "GET", "/v1/vaults", secondToken, nil); status != 200 {
		t.Fatalf("active session was revoked with another device: %d", status)
	}

	if status, _ = call(t, h, "POST", "/v1/auth/code", "", map[string]any{"email": email, "purpose": "sensitive"}); status != 202 {
		t.Fatalf("sensitive code request returned %d", status)
	}
	if status, _ = call(t, h, "DELETE", "/v1/account", secondToken, map[string]any{"code": m.get(email, "sensitive")}); status != 200 {
		t.Fatalf("account deregistration returned %d", status)
	}
	if status, _ = call(t, h, "GET", "/v1/vaults", secondToken, nil); status != 401 {
		t.Fatalf("deregistered session returned %d", status)
	}
	var vaultCount int
	if err := s.DB.QueryRow("SELECT COUNT(*) FROM vaults WHERE vault_id=?", vid).Scan(&vaultCount); err != nil || vaultCount != 0 {
		t.Fatalf("deregistered account retained vault rows: %d, %v", vaultCount, err)
	}
	if _, err := s.DB.Exec("UPDATE email_codes SET created_ms=created_ms-120000 WHERE email_hmc=?", s.mac("email:"+email)); err != nil {
		t.Fatal(err)
	}
	newToken, newUserID := login(t, s, m, email)
	if newUserID == firstUserID {
		t.Fatal("re-registration reused the deregistered identity")
	}
	status, listed = call(t, h, "GET", "/v1/vaults", newToken, nil)
	if status != 200 || len(listed["vaults"].([]any)) != 0 {
		t.Fatalf("re-registered account retained old vaults: %d %v", status, listed)
	}
}
