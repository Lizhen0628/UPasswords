package api

import (
	"context"
	"github.com/go-chi/chi/v5"
	"net/http"
	"strconv"
	"time"
)

func param(r *http.Request, name string) string { return chi.URLParam(r, name) }
func intString(n int64) string                  { return strconv.FormatInt(n, 10) }

// Handler exposes stable v2 routes. Admin and session endpoints use separate authentication gates.
func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.NotFound(s.endpoint(func(w http.ResponseWriter, r *http.Request) error { return fail(404, "not_found") }))
	r.MethodNotAllowed(s.endpoint(func(w http.ResponseWriter, r *http.Request) error { return fail(405, "method_not_allowed") }))
	capability := s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		writeJSON(w, 200, map[string]any{"name": "upasswords-sync", "version": 2, "capabilities": []string{"auth.email_code", "auth.sessions", "vaults.registry", "vaults.row_sync", "vaults.attachments", "vaults.rekey", "sites.catalog", "breach.range", "stats.readonly"}})
		return nil
	})
	r.Get("/", capability)
	r.Get("/v2", capability)
	r.Get("/v2/", capability)
	r.Get("/health/live", s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		writeJSON(w, 200, map[string]bool{"ok": true})
		return nil
	}))
	r.Get("/health/ready", s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if e := s.DB.PingContext(ctx); e != nil {
			return fail(503, "not_ready")
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
		return nil
	}))
	r.Post("/v2/auth/code", s.endpoint(s.code))
	r.Post("/v2/auth/verify", s.endpoint(s.verify))
	r.Group(func(r chi.Router) {
		r.Use(s.authenticated)
		r.Get("/v2/auth/sessions", s.endpoint(s.sessions))
		r.Patch("/v2/auth/session", s.endpoint(s.renameSession))
		r.Delete("/v2/auth/session", s.endpoint(s.revokeSession))
		r.Delete("/v2/auth/sessions/{sessionID}", s.endpoint(s.revokeSession))
		r.Delete("/v2/account", s.endpoint(s.deregister))
		r.Get("/v2/vaults", s.endpoint(s.vaultList))
		r.Post("/v2/vaults", s.endpoint(s.vaultCreate))
		r.Get("/v2/vaults/{vaultID}", s.endpoint(s.vaultGet))
		r.Patch("/v2/vaults/{vaultID}", s.endpoint(s.vaultRename))
		r.Delete("/v2/vaults/{vaultID}", s.endpoint(s.vaultDelete))
		r.Get("/v2/vaults/{vaultID}/seq", s.endpoint(s.vaultSeq))
		r.Post("/v2/vaults/{vaultID}/transfer", s.endpoint(s.vaultTransfer))
		r.Get("/v2/vaults/{vaultID}/items", s.endpoint(s.itemsList))
		r.Post("/v2/vaults/{vaultID}/items", s.endpoint(s.itemsPost))
		r.Get("/v2/vaults/{vaultID}/changes", s.endpoint(s.changes))
		r.Put("/v2/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentPut))
		r.Get("/v2/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentGet))
		r.Delete("/v2/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentDelete))
		r.Post("/v2/vaults/{vaultID}/attachments/{attachmentID}/commit", s.endpoint(s.attachmentCommit))
		r.Post("/v2/vaults/{vaultID}/rekey/begin", s.endpoint(s.rekeyBegin))
		r.Post("/v2/vaults/{vaultID}/rekey/{rekeyID}/chunk", s.endpoint(s.rekeyChunk))
		r.Post("/v2/vaults/{vaultID}/rekey/{rekeyID}/commit", s.endpoint(s.rekeyCommit))
		r.Delete("/v2/vaults/{vaultID}/rekey/{rekeyID}", s.endpoint(s.rekeyAbort))
		r.Get("/v2/sites/lookup", s.endpoint(s.siteLookup))
		r.Get("/v2/sites/icon/{sha256}", s.endpoint(s.siteIcon))
		r.Get("/v2/breach/range/{prefix}", s.endpoint(s.breach))
	})
	r.Group(func(r chi.Router) {
		r.Use(s.admin)
		r.Post("/v2/admin/sites", s.endpoint(s.sitePut))
		r.Get("/v2/admin/stats", s.endpoint(s.stats))
	})
	return r
}
