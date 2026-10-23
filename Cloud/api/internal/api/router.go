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

	// Handler exposes v1 routes and keeps v2 as a compatibility alias for installed clients.
func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.NotFound(s.endpoint(func(w http.ResponseWriter, r *http.Request) error { return fail(404, "not_found") }))
	r.MethodNotAllowed(s.endpoint(func(w http.ResponseWriter, r *http.Request) error { return fail(405, "method_not_allowed") }))
	capability := s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		writeJSON(w, 200, map[string]any{"name": "upasswords-sync", "version": 2, "capabilities": []string{"auth.email_code", "auth.sessions", "vaults.registry", "vaults.row_sync", "vaults.attachments", "vaults.rekey", "sites.catalog", "breach.range", "stats.readonly"}})
		return nil
	})
	r.Get("/", capability)
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
	for _, prefix := range []string{"/v1", "/v2"} {
		r.Route(prefix, func(r chi.Router) {
			r.Get("/", capability)
			r.Post("/auth/code", s.endpoint(s.code))
			r.Post("/auth/verify", s.endpoint(s.verify))
			r.Group(func(r chi.Router) {
				r.Use(s.authenticated)
				r.Get("/auth/sessions", s.endpoint(s.sessions))
				r.Patch("/auth/session", s.endpoint(s.renameSession))
				r.Delete("/auth/session", s.endpoint(s.revokeSession))
				r.Delete("/auth/sessions/{sessionID}", s.endpoint(s.revokeSession))
				r.Delete("/account", s.endpoint(s.deregister))
				r.Get("/vaults", s.endpoint(s.vaultList))
				r.Post("/vaults", s.endpoint(s.vaultCreate))
				r.Get("/vaults/{vaultID}", s.endpoint(s.vaultGet))
				r.Patch("/vaults/{vaultID}", s.endpoint(s.vaultRename))
				r.Delete("/vaults/{vaultID}", s.endpoint(s.vaultDelete))
				r.Get("/vaults/{vaultID}/seq", s.endpoint(s.vaultSeq))
				r.Post("/vaults/{vaultID}/transfer", s.endpoint(s.vaultTransfer))
				r.Get("/vaults/{vaultID}/items", s.endpoint(s.itemsList))
				r.Post("/vaults/{vaultID}/items", s.endpoint(s.itemsPost))
				r.Get("/vaults/{vaultID}/changes", s.endpoint(s.changes))
				r.Put("/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentPut))
				r.Get("/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentGet))
				r.Delete("/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentDelete))
				r.Post("/vaults/{vaultID}/attachments/{attachmentID}/commit", s.endpoint(s.attachmentCommit))
				r.Post("/vaults/{vaultID}/rekey/begin", s.endpoint(s.rekeyBegin))
				r.Post("/vaults/{vaultID}/rekey/{rekeyID}/chunk", s.endpoint(s.rekeyChunk))
				r.Post("/vaults/{vaultID}/rekey/{rekeyID}/commit", s.endpoint(s.rekeyCommit))
				r.Delete("/vaults/{vaultID}/rekey/{rekeyID}", s.endpoint(s.rekeyAbort))
				r.Get("/sites/lookup", s.endpoint(s.siteLookup))
				r.Get("/sites/icon/{sha256}", s.endpoint(s.siteIcon))
				r.Get("/breach/range/{prefix}", s.endpoint(s.breach))
			})
			r.Group(func(r chi.Router) {
				r.Use(s.admin)
				r.Post("/admin/sites", s.endpoint(s.sitePut))
				r.Get("/admin/stats", s.endpoint(s.stats))
			})
		})
	}
	return r
}
