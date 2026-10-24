package api

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSiteCatalogIconStatsAndBreachProxy(t *testing.T) {
	s, m := testServer(t)
	token, _ := login(t, s, m, "catalog-"+randomHex(5)+"@example.com")
	h := s.Handler()

	if status, _ := call(t, h, "POST", "/v1/admin/sites", "", map[string]any{"sites": []any{}}); status != 401 {
		t.Fatalf("unauthenticated catalog write returned %d", status)
	}
	iconBytes := []byte("fake-icon-bytes")
	iconB64 := base64.StdEncoding.EncodeToString(iconBytes)
	status, catalog, _, _ := callWithHeaders(t, h, "POST", "/v1/admin/sites", map[string]string{
		"X-Admin-Token": s.Config.AdminToken,
	}, map[string]any{"sites": []any{map[string]any{
		"domains":  []string{"github.com", "gist.github.com"},
		"primary":  "github.com",
		"nameEn":   "GitHub",
		"nameZh":   "GitHub 中文",
		"iconB64":  iconB64,
		"iconMime": "image/png",
	}}})
	if status != 200 || catalog["upserted"] != float64(1) {
		t.Fatalf("catalog upsert: %d %v", status, catalog)
	}

	status, lookup := call(t, h, "GET", "/v1/sites/lookup?domain=gist.github.com", token, nil)
	if status != 200 || lookup["primaryDomain"] != "github.com" || lookup["nameEn"] != "GitHub" {
		t.Fatalf("catalog lookup: %d %v", status, lookup)
	}
	icon := lookup["icon"].(map[string]any)
	if icon["b64"] != iconB64 || icon["bytes"] != float64(len(iconBytes)) {
		t.Fatalf("catalog icon metadata: %v", icon)
	}
	sha := icon["sha256"].(string)
	status, _, headers, body := callWithHeaders(t, h, "GET", "/v1/sites/icon/"+sha, map[string]string{
		"Authorization": "Bearer " + token,
	}, nil)
	if status != 200 || string(body) != string(iconBytes) || headers.Get("ETag") != "\""+sha+"\"" || !strings.Contains(headers.Get("Cache-Control"), "immutable") {
		t.Fatalf("catalog icon response: %d, headers=%v, body=%q", status, headers, body)
	}
	if status, _ = call(t, h, "GET", "/v1/sites/lookup?domain=missing.example", token, nil); status != 404 {
		t.Fatalf("catalog miss returned %d", status)
	}
	if status, _ = call(t, h, "GET", "/v1/sites/lookup?domain=not_a_domain", token, nil); status != 400 {
		t.Fatalf("invalid domain returned %d", status)
	}

	if status, _ = call(t, h, "GET", "/v1/admin/stats", "", nil); status != 401 {
		t.Fatalf("unauthenticated stats returned %d", status)
	}
	status, stats, _, _ := callWithHeaders(t, h, "GET", "/v1/admin/stats", map[string]string{
		"X-Admin-Token": s.Config.AdminToken,
	}, nil)
	if status != 200 || stats["users"].(map[string]any)["active"].(float64) < 1 || stats["sessions"].(float64) < 1 {
		t.Fatalf("admin stats: %d %v", status, stats)
	}

	upstreamStatus := http.StatusOK
	upstreamHits := 0
	s.HTTP = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		if r.URL.Path != "/range/0ABCD" || r.Header.Get("Add-Padding") != "true" {
			t.Errorf("unexpected breach request: %s, Add-Padding=%q", r.URL, r.Header.Get("Add-Padding"))
		}
		return &http.Response{
			StatusCode: upstreamStatus,
			Body:       io.NopCloser(strings.NewReader("CDEF1:5\nCDEF2:42\r\n")),
			Header:     make(http.Header),
			Request:    r,
		}, nil
	})}
	if status, _ = call(t, h, "GET", "/v1/breach/range/0abcd", "", nil); status != 401 {
		t.Fatalf("unauthenticated breach lookup returned %d", status)
	}
	status, _, _, breachBody := callWithHeaders(t, h, "GET", "/v1/breach/range/0abcd", map[string]string{
		"Authorization": "Bearer " + token,
	}, nil)
	if status != 200 || !strings.Contains(string(breachBody), "CDEF2:42") || upstreamHits != 1 {
		t.Fatalf("breach proxy: %d %q, upstream hits=%d", status, breachBody, upstreamHits)
	}
	if status, _ = call(t, h, "GET", "/v1/breach/range/XYZ", token, nil); status != 400 {
		t.Fatalf("invalid breach prefix returned %d", status)
	}
	upstreamStatus = http.StatusServiceUnavailable
	if status, _ = call(t, h, "GET", "/v1/breach/range/0abcd", token, nil); status != 502 {
		t.Fatalf("upstream failure returned %d", status)
	}
}

func TestSyncDeletePurgeAndKeysetPagination(t *testing.T) {
	s, m := testServer(t)
	token, _ := login(t, s, m, "pagination-"+randomHex(5)+"@example.com")
	h := s.Handler()
	vid := newVault(t, h, token)
	base := "/v1/vaults/" + vid
	ids := []string{
		"72345678-1234-4234-8234-123456789abc",
		"82345678-1234-4234-8234-123456789abc",
		"92345678-1234-4234-8234-123456789abc",
	}
	items := make([]any, 0, len(ids))
	for _, id := range ids {
		items = append(items, incoming(id, 1, 0, "cipher-"+id))
	}
	if status, _ := call(t, h, "POST", base+"/items", token, map[string]any{"items": items}); status != 200 {
		t.Fatalf("insert rows returned %d", status)
	}

	seen := map[string]bool{}
	path := base + "/items?limit=1"
	for {
		status, page := call(t, h, "GET", path, token, nil)
		if status != 200 {
			t.Fatalf("list page returned %d: %v", status, page)
		}
		rows := page["items"].([]any)
		if len(rows) != 1 {
			t.Fatalf("page size %d, want 1", len(rows))
		}
		seen[rows[0].(map[string]any)["uuid"].(string)] = true
		next, ok := page["nextCursor"].(map[string]any)
		if !ok {
			break
		}
		path = base + "/items?limit=1&cursorMs=" + intString(int64(next["ms"].(float64))) + "&cursorUuid=" + next["uuid"].(string)
	}
	if len(seen) != len(ids) {
		t.Fatalf("keyset pagination returned %d of %d rows", len(seen), len(ids))
	}

	deletedID := ids[0]
	status, resultBody := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{map[string]any{
		"uuid": deletedID, "kind": 1, "op": "delete", "baseRevision": 1, "modifiedMs": 2000,
	}}})
	if status != 200 || result(resultBody)["status"] != "ok" {
		t.Fatalf("row delete: %d %v", status, resultBody)
	}
	status, changes := call(t, h, "GET", base+"/changes?since=0", token, nil)
	if status != 200 {
		t.Fatalf("change feed returned %d", status)
	}
	purged := false
	for _, raw := range changes["changes"].([]any) {
		change := raw.(map[string]any)
		if change["uuid"] == deletedID && change["op"] == "purge" && change["deleted"] == true {
			purged = true
		}
	}
	if !purged {
		t.Fatalf("delete purge marker missing: %v", changes["changes"])
	}
	status, late := call(t, h, "POST", base+"/items", token, map[string]any{"items": []any{incoming(deletedID, 1, 1, "stale")}})
	if status != 200 || result(late)["status"] != "not_found" {
		t.Fatalf("stale row was not rejected after purge: %d %v", status, late)
	}
}

func callWithHeaders(t *testing.T, h http.Handler, method, path string, headers map[string]string, value any) (int, map[string]any, http.Header, []byte) {
	t.Helper()
	var body io.Reader
	if value != nil {
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		body = strings.NewReader(string(raw))
	}
	r := httptest.NewRequest(method, path, body)
	r.Header.Set("Content-Type", "application/json")
	for key, header := range headers {
		r.Header.Set(key, header)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	result := map[string]any{}
	if w.Body.Len() > 0 && strings.Contains(w.Header().Get("Content-Type"), "application/json") {
		if err := json.Unmarshal(w.Body.Bytes(), &result); err != nil {
			t.Fatalf("decode response (%d): %v", w.Code, err)
		}
	}
	return w.Code, result, w.Header(), w.Body.Bytes()
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) {
	return f(r)
}
