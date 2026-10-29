// API 路由与授权边界；公共 API 仅使用 /v1 路径。
package api

import (
	"context"
	"github.com/go-chi/chi/v5"
	"net/http"
	"strconv"
	"time"
)

// param reads a chi route parameter; callers still validate identity syntax and account ownership.
func param(r *http.Request, name string) string { return chi.URLParam(r, name) }

// intString formats an integer in base ten for headers and query metadata.
func intString(n int64) string { return strconv.FormatInt(n, 10) }

const (
	syncProtocolHeader  = "X-UPW-Sync-Protocol"
	syncProtocolVersion = 5
)

// requireSyncProtocol rejects clients that cannot safely consume current sync contracts.
func (s *Server) requireSyncProtocol(next http.Handler) http.Handler {
	reject := s.endpoint(func(http.ResponseWriter, *http.Request) error {
		return fail(http.StatusUpgradeRequired, "client_upgrade_required")
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		version, err := strconv.Atoi(r.Header.Get(syncProtocolHeader))
		if err != nil || version < syncProtocolVersion {
			reject.ServeHTTP(w, r)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Handler exposes the canonical v1 API routes.
func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.NotFound(s.endpoint(func(w http.ResponseWriter, r *http.Request) error { return fail(404, "not_found") }))
	r.MethodNotAllowed(s.endpoint(func(w http.ResponseWriter, r *http.Request) error { return fail(405, "method_not_allowed") }))
	capability := s.endpoint(func(w http.ResponseWriter, r *http.Request) error {
		writeJSON(w, 200, map[string]any{"name": "upasswords-sync", "version": syncProtocolVersion, "capabilities": []string{"auth.email_code", "auth.sessions", "vaults.registry", "vaults.row_sync", "vaults.attachments", "vaults.conflicts", "vaults.rekey", "sites.catalog", "breach.range", "stats.readonly"}})
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
	for _, prefix := range []string{"/v1"} {
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
				syncRoutes := r.With(s.requireSyncProtocol)
				syncRoutes.Get("/vaults/{vaultID}/seq", s.endpoint(s.vaultSeq))
				r.Post("/vaults/{vaultID}/transfer", s.endpoint(s.vaultTransfer))
				syncRoutes.Get("/vaults/{vaultID}/items", s.endpoint(s.itemsList))
				syncRoutes.Post("/vaults/{vaultID}/items", s.endpoint(s.itemsPost))
				syncRoutes.Get("/vaults/{vaultID}/changes", s.endpoint(s.changes))
				syncRoutes.Get("/vaults/{vaultID}/conflicts", s.endpoint(s.conflictsList))
				syncRoutes.Get("/vaults/{vaultID}/conflict-history", s.endpoint(s.conflictHistoryList))
				syncRoutes.Post("/vaults/{vaultID}/items/{itemID}/conflicts", s.endpoint(s.conflictRegister))
				syncRoutes.Post("/vaults/{vaultID}/conflicts/{conflictID}/resolve", s.endpoint(s.conflictResolve))
				syncRoutes.Get("/vaults/{vaultID}/attachments", s.endpoint(s.attachmentManifest))
				syncRoutes.Get("/vaults/{vaultID}/attachment-versions", s.endpoint(s.attachmentVersions))
				syncRoutes.Put("/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentPut))
				syncRoutes.Get("/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentGet))
				syncRoutes.Delete("/vaults/{vaultID}/attachments/{attachmentID}", s.endpoint(s.attachmentDelete))
				syncRoutes.Post("/vaults/{vaultID}/attachments/{attachmentID}/commit", s.endpoint(s.attachmentCommit))
				syncRoutes.Post("/vaults/{vaultID}/rekey/begin", s.endpoint(s.rekeyBegin))
				syncRoutes.Get("/vaults/{vaultID}/rekey/{rekeyID}/conflicts", s.endpoint(s.rekeyConflictCandidates))
				syncRoutes.Post("/vaults/{vaultID}/rekey/{rekeyID}/conflicts", s.endpoint(s.rekeyConflictChunk))
				syncRoutes.Post("/vaults/{vaultID}/rekey/{rekeyID}/chunk", s.endpoint(s.rekeyChunk))
				syncRoutes.Post("/vaults/{vaultID}/rekey/{rekeyID}/commit", s.endpoint(s.rekeyCommit))
				syncRoutes.Delete("/vaults/{vaultID}/rekey/{rekeyID}", s.endpoint(s.rekeyAbort))
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
