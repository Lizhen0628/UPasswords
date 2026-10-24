// Package api implements row-sync protocol version 2 under /v1 and its /v2 compatibility alias.
package api

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-sql-driver/mysql"
)

const (
	smallJSON = 64 << 10
	batchJSON = 8 << 20
	dayMS     = int64(86400000)
)

var idPattern = regexp.MustCompile("^[0-9a-f]{32}$")
var uuidPattern = regexp.MustCompile("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
var hashPattern = regexp.MustCompile("(?i)^[0-9a-f]{64}$")
var emailPattern = regexp.MustCompile(`^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z0-9-]+$`)

// Config holds validated settings. Credentials must never enter logs.
type Config struct {
	Address                                                           string
	DBUser, DBPassword, DBAddress, DBName, DBTLS, DBCA                string
	KEK                                                               []byte
	AdminToken                                                        string
	R2Endpoint, R2Bucket, R2AccessKey, R2SecretKey                    string
	SMTPHost, SMTPPort, SMTPFrom, SMTPReplyTo, SMTPUser, SMTPPassword string
	SMTPRegisterReplyTo, SMTPVerifyReplyTo                            string
	TrustedProxy                                                      string
	Limits                                                            map[string]int64
}

// LoadConfig fails closed on missing credentials or ambiguous TLS settings.
func LoadConfig() (Config, error) {
	c := Config{Address: env("HTTP_ADDR", ":8080"), DBAddress: env("DB_ADDRESS", "10.0.3.198:6033"), DBName: env("DB_NAME", "upasswords"), DBUser: os.Getenv("DB_USER"), DBPassword: os.Getenv("DB_PASSWORD"), DBTLS: env("DB_TLS", "verify"), DBCA: os.Getenv("DB_CA_FILE"), AdminToken: os.Getenv("ADMIN_TOKEN"), R2Endpoint: os.Getenv("R2_ENDPOINT"), R2Bucket: env("R2_BUCKET", "upasswords"), R2AccessKey: os.Getenv("R2_ACCESS_KEY_ID"), R2SecretKey: os.Getenv("R2_SECRET_ACCESS_KEY"), SMTPHost: env("SMTP_HOST", "smtp.163.com"), SMTPPort: env("SMTP_PORT", "465"), SMTPFrom: os.Getenv("SMTP_FROM"), SMTPReplyTo: env("SMTP_REPLY_TO", "register@upasswords.com"), SMTPUser: os.Getenv("SMTP_USER"), SMTPPassword: os.Getenv("SMTP_PASSWORD"), TrustedProxy: os.Getenv("TRUSTED_PROXY_IP"), Limits: map[string]int64{}}
	c.SMTPRegisterReplyTo = env("SMTP_REGISTER_REPLY_TO", "register@upasswords.com")
	c.SMTPVerifyReplyTo = env("SMTP_VERIFY_REPLY_TO", "verify@upasswords.com")
	u, err := url.Parse(c.R2Endpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return c, errors.New("R2_ENDPOINT must be an HTTPS URL")
	}
	var e error
	c.KEK, e = hex.DecodeString(os.Getenv("APP_KEK"))
	if e != nil || len(c.KEK) != 32 {
		return c, errors.New("APP_KEK must contain 64 hex characters")
	}
	if c.DBUser == "" || c.DBPassword == "" || c.AdminToken == "" || c.R2Endpoint == "" || c.R2AccessKey == "" || c.R2SecretKey == "" || c.SMTPUser == "" || c.SMTPPassword == "" || c.SMTPFrom == "" {
		return c, errors.New("missing database, object storage, admin or SMTP credentials")
	}
	if c.DBTLS != "verify" && c.DBTLS != "pinned" {
		return c, errors.New("DB_TLS must be verify or pinned")
	}
	for k, v := range defaults {
		n := v
		if raw := os.Getenv(k); raw != "" {
			n, e = strconv.ParseInt(raw, 10, 64)
			if e != nil || n <= 0 {
				return c, fmt.Errorf("invalid numeric setting %s", k)
			}
		}
		c.Limits[k] = n
	}
	if c.TrustedProxy != "" && net.ParseIP(c.TrustedProxy) == nil {
		return c, errors.New("TRUSTED_PROXY_IP must be an exact IP")
	}
	return c, nil
}

var defaults = map[string]int64{"VAULT_LIMIT_PER_USER": 10, "ITEM_BODY_MAX_BYTES": 2097152, "ITEMS_PER_VAULT_LIMIT": 50000, "ITEMS_BATCH_MAX": 200, "ATTACHMENT_MAX_BYTES": 20971520, "ATTACH_QUOTA_PER_VAULT": 524288000, "ATTACH_STAGING_MAX_OBJECTS": 8, "CHANGE_RETENTION_DAYS": 90, "REKEY_TTL_MS": 3600000, "SITES_ICON_MAX_BYTES": 65536, "CODE_TTL_SECONDS": 600, "CODE_RESEND_COOLDOWN_SECONDS": 60, "CODE_HOURLY_PER_EMAIL": 10, "CODE_HOURLY_PER_IP": 20, "CODE_MAX_ATTEMPTS": 5, "SESSION_TTL_DAYS": 90, "DEREGISTER_PURGE_DAYS": 30}

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}
func (c Config) limit(k string) int64 {
	if v := c.Limits[k]; v > 0 {
		return v
	}
	return defaults[k]
}

// Server owns shared pools and explicitly injected external services.
type Server struct {
	DB      *sql.DB
	Config  Config
	Objects ObjectStore
	Mailer  Mailer
	Log     *slog.Logger
	HTTP    *http.Client
}

// apiError carries a stable public error code, HTTP status and optional retry delay; internal errors are redacted.
type apiError struct {
	Status int
	Code   string
	Retry  int
}

func (e *apiError) Error() string        { return e.Code }
func fail(status int, code string) error { return &apiError{Status: status, Code: code} }

// endpoint is a handler that returns errors for centralized response and logging.
type endpoint func(http.ResponseWriter, *http.Request) error

// endpoint adapts returned errors to the public error shape and logs route templates, status and duration only.
func (s *Server) endpoint(fn endpoint) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		rw := &statusWriter{ResponseWriter: w, status: 200}
		rw.Header().Set("Cache-Control", "no-store")
		rw.Header().Set("X-Content-Type-Options", "nosniff")
		defer func() {
			if recover() != nil {
				s.Log.Error("request panic recovered")
				writeJSON(rw, 500, map[string]string{"error": "internal"})
			}
			s.Log.Info("request", "method", r.Method, "route", chi.RouteContext(r.Context()).RoutePattern(), "status", rw.status, "elapsedMs", time.Since(started).Milliseconds())
		}()
		if e := fn(rw, r); e != nil {
			var a *apiError
			if !errors.As(e, &a) {
				s.Log.Error("request failed", "kind", fmt.Sprintf("%T", e))
				a = &apiError{Status: 500, Code: "internal"}
			}
			if a.Retry > 0 {
				rw.Header().Set("Retry-After", strconv.Itoa(a.Retry))
			}
			writeJSON(rw, a.Status, map[string]string{"error": a.Code})
		}
	}
}

// statusWriter captures the response status used by the request summary log.
type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (w *statusWriter) WriteHeader(status int) {
	if w.wrote {
		return
	}
	w.status = status
	w.wrote = true
	w.ResponseWriter.WriteHeader(status)
}
func (w *statusWriter) Write(b []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(200)
	}
	return w.ResponseWriter.Write(b)
}

// writeJSON writes the selected status and JSON response; callers must supply only the permitted public projection.
func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// body enforces an actual byte bound and a single JSON object, including chunked requests.
func body(w http.ResponseWriter, r *http.Request, max int64, v any) error {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	raw, e := io.ReadAll(r.Body)
	if e != nil {
		var limit *http.MaxBytesError
		if errors.As(e, &limit) {
			return fail(413, "too_large")
		}
		return fail(400, "bad_request")
	}
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '{' {
		return fail(400, "bad_request")
	}
	if e = json.Unmarshal(raw, v); e != nil {
		return fail(400, "bad_request")
	}
	return nil
}

// decode64 validates and decodes a standard Base64 payload before ciphertext size checks.
func decode64(v string) ([]byte, error) {
	b, e := base64.StdEncoding.DecodeString(v)
	if e != nil {
		return nil, fail(400, "bad_request")
	}
	return b, nil
}
func b64(v []byte) string { return base64.StdEncoding.EncodeToString(v) }

// randomHex returns a cryptographically random identifier containing n random bytes encoded as hex.
func randomHex(n int) string {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		panic("secure randomness unavailable")
	}
	return hex.EncodeToString(b)
}

// now returns Unix time in milliseconds, matching the cross-client wire contract.
func now() int64 { return time.Now().UnixMilli() }

// digest returns a lowercase SHA-256 hex digest; hashing does not make low-entropy secrets safe to log.
func digest(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }

// mac computes a keyed digest under the application KEK for private lookup identifiers.
func (s *Server) mac(v string) string {
	h := hmac.New(sha256.New, s.Config.KEK)
	_, _ = h.Write([]byte(v))
	return hex.EncodeToString(h.Sum(nil))
}

// seal wraps application-owned metadata with APP_KEK; client vault ciphertext remains independently encrypted.
func (s *Server) seal(b []byte) (string, error) {
	block, e := aes.NewCipher(s.Config.KEK)
	if e != nil {
		return "", e
	}
	g, e := cipher.NewGCM(block)
	if e != nil {
		return "", e
	}
	n := make([]byte, g.NonceSize())
	if _, e = rand.Read(n); e != nil {
		return "", e
	}
	return "v1." + b64(g.Seal(n, n, b, nil)), nil
}

// open authenticates application-encrypted metadata; changing APP_KEK would invalidate existing stored values.
func (s *Server) open(v sql.NullString) ([]byte, error) {
	if !v.Valid {
		return nil, nil
	}
	if !strings.HasPrefix(v.String, "v1.") {
		return nil, errors.New("unsupported envelope encryption")
	}
	b, e := decode64(v.String[3:])
	if e != nil {
		return nil, e
	}
	block, e := aes.NewCipher(s.Config.KEK)
	if e != nil {
		return nil, e
	}
	g, e := cipher.NewGCM(block)
	if e != nil {
		return nil, e
	}
	if len(b) < g.NonceSize()+g.Overhead() {
		return nil, errors.New("invalid encrypted envelope")
	}
	return g.Open(nil, b[:g.NonceSize()], b[g.NonceSize():], nil)
}
func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

// uuid validates a canonical UUID shape and normalizes storage to lowercase; clients restore uppercase for row AAD.
func uuid(v string) (string, error) {
	if !uuidPattern.MatchString(v) {
		return "", fail(400, "bad_request")
	}
	return strings.ToLower(v), nil
}

// validEnvelope checks only envelope size and magic; the client authenticates and unwraps it.
func validEnvelope(b []byte) bool {
	return len(b) >= 100 && len(b) <= 4096 && bytes.Equal(b[:8], []byte("UPWKEY1\x00"))
}

// email normalizes and validates an account address before keyed lookup.
func email(v string) (string, error) {
	v = strings.ToLower(strings.TrimSpace(v))
	if len(v) > 254 || !emailPattern.MatchString(v) {
		return "", fail(400, "invalid_email")
	}
	return v, nil
}

// vaultName validates a user-visible registry name; it is never used as a filesystem path.
func vaultName(v string) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" || len([]rune(v)) > 64 || strings.HasPrefix(v, ".") || strings.ContainsAny(v, "\\/:*?\"<>|") {
		return "", fail(400, "invalid_name")
	}
	for _, ch := range v {
		if ch < 32 {
			return "", fail(400, "invalid_name")
		}
	}
	for _, suffix := range []string{".upw", ".upwkey", ".old"} {
		if strings.HasSuffix(strings.ToLower(v), suffix) {
			return "", fail(400, "invalid_name")
		}
	}
	return v, nil
}

// deviceName trims and bounds a device display name; it does not establish device identity.
func deviceName(v string) string {
	v = strings.Map(func(r rune) rune {
		if r < 32 {
			return -1
		}
		return r
	}, strings.TrimSpace(v))
	r := []rune(v)
	if len(r) > 64 {
		r = r[:64]
	}
	return string(r)
}

// platform restricts device metadata to the supported platform vocabulary.
func platform(v string) string {
	switch v {
	case "macos", "ios", "autofill", "ext-safari", "ext-chrome", "ext-edge", "ext-firefox":
		return v
	}
	return "other"
}

// ip trusts the forwarded address only from the configured proxy peer; other requests use the socket address.
func (s *Server) ip(r *http.Request) string {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == s.Config.TrustedProxy && host != "" {
		if ip := net.ParseIP(r.Header.Get("X-Real-IP")); ip != nil {
			return ip.String()
		}
	}
	return host
}

// transaction commits only after the callback succeeds and otherwise rolls back; external I/O cannot be rolled back by SQL.
func (s *Server) transaction(ctx context.Context, fn func(*sql.Tx) error) error {
	t, e := s.DB.BeginTx(ctx, nil)
	if e != nil {
		return e
	}
	defer func() {
		if e := t.Rollback(); e != nil && !errors.Is(e, sql.ErrTxDone) {
			s.Log.Warn("transaction rollback failed")
		}
	}()
	if e = fn(t); e != nil {
		return e
	}
	return t.Commit()
}
func duplicate(e error) bool { var m *mysql.MySQLError; return errors.As(e, &m) && m.Number == 1062 }

// audit records action identifiers and permitted metadata only; failure must not disclose request bodies or credentials.
func (s *Server) audit(ctx context.Context, action, uid, vid string, detail any) {
	b, e := json.Marshal(detail)
	if e != nil {
		s.Log.Error("audit encoding failed")
		return
	}
	_, e = s.DB.ExecContext(ctx, "INSERT INTO audit_log (user_id,vault_id,action,detail,ts_ms) VALUES (?,?,?,?,?)", nullable(uid), nullable(vid), action, string(b), now())
	if e != nil {
		s.Log.Error("audit write failed", "action", action)
	}
}
func nullable(v string) any {
	if v == "" {
		return nil
	}
	return v
}
func stringOrNil(v sql.NullString) any {
	if v.Valid {
		return v.String
	}
	return nil
}
func intOrNil(v sql.NullInt64) any {
	if v.Valid {
		return v.Int64
	}
	return nil
}

// requireAffected rejects an unexpected empty mutation result rather than reporting a write that did not occur.
func requireAffected(res sql.Result, e error) error {
	if e != nil {
		return e
	}
	n, e := res.RowsAffected()
	if e != nil {
		return e
	}
	if n == 0 {
		return fail(404, "not_found")
	}
	return nil
}
