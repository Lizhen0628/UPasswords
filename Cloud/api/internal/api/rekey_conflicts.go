package api

import (
	"database/sql"
	"errors"
	"net/http"
)

type rekeyConflictStage struct {
	ConflictID     string `json:"conflictId"`
	OldCandidateID string `json:"oldCandidateId"`
	CandidateID    string `json:"candidateId"`
	Fingerprint    string `json:"fingerprint"`
	BodyB64        string `json:"bodyB64"`
	SHA256         string `json:"sha256"`
}

// rekeyConflictChunk stages transformed conflict candidates under the active vault write lock.
func (s *Server) rekeyConflictChunk(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Candidates []rekeyConflictStage `json:"candidates"`
	}
	if err := body(w, r, batchJSON, &b); err != nil {
		return err
	}
	if len(b.Candidates) == 0 || len(b.Candidates) > rekeyConflictPageLimit ||
		int64(len(b.Candidates)) > s.Config.limit("ITEMS_BATCH_MAX") {
		return fail(400, "bad_request")
	}
	a := identity(r)
	vid := param(r, "vaultID")
	rid := param(r, "rekeyID")
	var staged int64
	err := s.transaction(r.Context(), func(t *sql.Tx) error {
		if _, err := loadVault(r.Context(), t, a.UserID, vid, true); err != nil {
			return err
		}
		if _, err := loadRekey(r, t, vid, rid); err != nil {
			return err
		}
		var total int64
		if err := t.QueryRowContext(r.Context(), "SELECT candidate_total FROM rekey_conflict_manifests WHERE rekey_id=? AND vault_id=? FOR UPDATE", rid, vid).Scan(&total); err != nil {
			return err
		}
		var liveCount int64
		if err := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=?", vid).Scan(&liveCount); err != nil {
			return err
		}
		if liveCount != total {
			return fail(409, "rekey_stale")
		}
		for _, candidate := range b.Candidates {
			if !idPattern.MatchString(candidate.ConflictID) || !idPattern.MatchString(candidate.OldCandidateID) ||
				!idPattern.MatchString(candidate.CandidateID) || !hashPattern.MatchString(candidate.Fingerprint) ||
				!equal(candidate.CandidateID, candidate.Fingerprint[:32]) {
				return fail(400, "bad_request")
			}
			var op int
			if err := t.QueryRowContext(r.Context(), "SELECT x.op FROM item_conflict_candidates x JOIN item_conflicts c ON c.conflict_id=x.conflict_id WHERE c.vault_id=? AND c.conflict_id=? AND x.candidate_id=?", vid, candidate.ConflictID, candidate.OldCandidateID).Scan(&op); errors.Is(err, sql.ErrNoRows) {
				return fail(409, "rekey_stale")
			} else if err != nil {
				return err
			}
			var body []byte
			var sha sql.NullString
			if op == 1 {
				decoded, err := decode64(candidate.BodyB64)
				if err != nil || len(decoded) == 0 || !hashPattern.MatchString(candidate.SHA256) || !equal(digest(decoded), candidate.SHA256) {
					return fail(400, "bad_request")
				}
				if int64(len(decoded)) > s.Config.limit("ITEM_BODY_MAX_BYTES") {
					return fail(413, "item_too_large")
				}
				body = decoded
				sha = sql.NullString{String: candidate.SHA256, Valid: true}
			} else if op != 2 || candidate.BodyB64 != "" || candidate.SHA256 != "" {
				return fail(400, "bad_request")
			}
			var collision int
			if err := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekey_conflict_staging WHERE rekey_id=? AND conflict_id=? AND new_candidate_id=? AND old_candidate_id<>?", rid, candidate.ConflictID, candidate.CandidateID, candidate.OldCandidateID).Scan(&collision); err != nil {
				return err
			}
			if collision > 0 {
				return fail(409, "rekey_candidate_collision")
			}
			if _, err := t.ExecContext(r.Context(), "INSERT INTO rekey_conflict_staging(rekey_id,vault_id,conflict_id,old_candidate_id,new_candidate_id,candidate_fingerprint,body,body_sha256) VALUES(?,?,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE new_candidate_id=VALUES(new_candidate_id),candidate_fingerprint=VALUES(candidate_fingerprint),body=VALUES(body),body_sha256=VALUES(body_sha256)", rid, vid, candidate.ConflictID, candidate.OldCandidateID, candidate.CandidateID, candidate.Fingerprint, nullableBytes(body), sha); err != nil {
				return err
			}
		}
		if err := t.QueryRowContext(r.Context(), "SELECT COUNT(*) FROM rekey_conflict_staging WHERE rekey_id=?", rid).Scan(&staged); err != nil {
			return err
		}
		if staged > total {
			return fail(400, "bad_request")
		}
		if _, err := t.ExecContext(r.Context(), "UPDATE rekey_conflict_manifests SET candidate_staged=? WHERE rekey_id=?", staged, rid); err != nil {
			return err
		}
		_, err := t.ExecContext(r.Context(), "UPDATE rekeys SET expires_ms=? WHERE rekey_id=?", now()+s.Config.limit("REKEY_TTL_MS"), rid)
		return err
	})
	if err != nil {
		return err
	}
	s.audit(r.Context(), "rekey_conflict_chunk", a.UserID, vid, map[string]int64{"candidates": staged})
	writeJSON(w, 200, map[string]int64{"candidateStaged": staged})
	return nil
}
