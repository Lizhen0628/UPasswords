// 公开站点目录和泄露前缀代理；查询域名和哈希前缀不写入请求日志。
package api

import (
	"database/sql"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
)

var domainPattern = regexp.MustCompile("^[a-z0-9.-]+$")
var prefixPattern = regexp.MustCompile("(?i)^[0-9a-f]{5}$")

// domain normalizes an input hostname or URL for public catalog lookup; it is not a general public-suffix parser.
func domain(v string) string {
	v = strings.TrimSpace(lower(v))
	if strings.Contains(v, "://") {
		u, e := url.Parse(v)
		if e != nil {
			return ""
		}
		v = u.Hostname()
	} else {
		v = strings.SplitN(v, "/", 2)[0]
		v = strings.SplitN(v, ":", 2)[0]
	}
	v = strings.TrimRight(v, ".")
	if len(v) < 1 || len(v) > 253 || !domainPattern.MatchString(v) {
		return ""
	}
	return v
}

// siteLookup resolves public catalog metadata without logging the queried domain.
func (s *Server) siteLookup(w http.ResponseWriter, r *http.Request) error {
	d := domain(r.URL.Query().Get("domain"))
	if d == "" {
		return fail(400, "invalid_domain")
	}
	var id int64
	var nameEN string
	var nameZH, home, sha sql.NullString
	var primary bool
	e := s.DB.QueryRowContext(r.Context(), "SELECT w.site_id,w.name_en,w.name_zh,w.home_url,w.icon_sha256,d.is_primary FROM website_domains d JOIN websites w ON w.site_id=d.site_id WHERE d.domain=? AND w.status=1", d).Scan(&id, &nameEN, &nameZH, &home, &sha, &primary)
	if errors.Is(e, sql.ErrNoRows) {
		return fail(404, "not_found")
	}
	if e != nil {
		return e
	}
	pd := d
	if !primary {
		e = s.DB.QueryRowContext(r.Context(), "SELECT domain FROM website_domains WHERE site_id=? AND is_primary=1 LIMIT 1", id).Scan(&pd)
		if e != nil && !errors.Is(e, sql.ErrNoRows) {
			return e
		}
	}
	var icon any
	if sha.Valid {
		stream, obj, e := s.Objects.Get(r.Context(), "sites/icons/"+sha.String)
		if e == nil {
			raw, e := io.ReadAll(io.LimitReader(stream, s.Config.limit("SITES_ICON_MAX_BYTES")+1))
			stream.Close()
			if e != nil {
				return e
			}
			if int64(len(raw)) > s.Config.limit("SITES_ICON_MAX_BYTES") || int64(len(raw)) != obj.Size {
				return errors.New("invalid stored icon size")
			}
			icon = map[string]any{"sha256": sha.String, "bytes": len(raw), "b64": b64(raw)}
		} else {
			var a *apiError
			if !errors.As(e, &a) || a.Status != 404 {
				return e
			}
		}
	}
	writeJSON(w, 200, map[string]any{"siteId": id, "domain": d, "primaryDomain": pd, "nameZh": stringOrNil(nameZH), "nameEn": nameEN, "homeUrl": stringOrNil(home), "icon": icon})
	return nil
}

// siteIcon streams a digest-addressed public icon with content caching headers.
func (s *Server) siteIcon(w http.ResponseWriter, r *http.Request) error {
	sha := lower(param(r, "sha256"))
	if !hashPattern.MatchString(sha) {
		return fail(404, "not_found")
	}
	stream, obj, e := s.Objects.Get(r.Context(), "sites/icons/"+sha)
	if e != nil {
		return e
	}
	defer stream.Close()
	mime := obj.ContentType
	if mime != "image/png" && mime != "image/jpeg" && mime != "image/webp" && mime != "image/x-icon" {
		mime = "application/octet-stream"
	}
	w.Header().Set("Content-Type", mime)
	w.Header().Set("ETag", "\""+sha+"\"")
	w.Header().Set("Cache-Control", "private, max-age=2592000, immutable")
	_, e = io.Copy(w, stream)
	return e
}

// sitePut validates administrator-supplied catalog entries and bounds downloaded icon payloads.
func (s *Server) sitePut(w http.ResponseWriter, r *http.Request) error {
	var b struct {
		Sites []struct {
			NameEN                     string `json:"nameEn"`
			NameZH                     string `json:"nameZh"`
			HomeURL                    string `json:"homeUrl"`
			Domains                    []string
			Primary, IconB64, IconMime string
		}
	}
	if e := body(w, r, batchJSON, &b); e != nil {
		return e
	}
	if len(b.Sites) == 0 || len(b.Sites) > 2000 {
		return fail(400, "bad_request")
	}
	for _, site := range b.Sites {
		site.NameEN = strings.TrimSpace(site.NameEN)
		if site.NameEN == "" || len([]rune(site.NameEN)) > 255 || len([]rune(site.NameZH)) > 255 || len(site.HomeURL) > 512 {
			return fail(400, "bad_request")
		}
		ds := []string{}
		seen := map[string]bool{}
		for _, d := range site.Domains {
			d = domain(d)
			if d != "" && !seen[d] {
				ds = append(ds, d)
				seen[d] = true
			}
		}
		if len(ds) == 0 || len(ds) > 100 {
			return fail(400, "bad_request")
		}
		p := domain(site.Primary)
		if !seen[p] {
			p = ds[0]
		}
		var sha, mime, size, iconTime any
		if site.IconB64 != "" {
			raw, e := decode64(site.IconB64)
			if e != nil || len(raw) == 0 || int64(len(raw)) > s.Config.limit("SITES_ICON_MAX_BYTES") {
				return fail(400, "invalid_icon")
			}
			mime = site.IconMime
			if mime == "" {
				mime = "image/png"
			}
			if mime != "image/png" && mime != "image/jpeg" && mime != "image/webp" && mime != "image/x-icon" {
				return fail(400, "invalid_icon")
			}
			sha = digest(raw)
			size = len(raw)
			iconTime = now()
			if e = s.Objects.Put(r.Context(), "sites/icons/"+sha.(string), raw, mime.(string)); e != nil {
				return e
			}
		}
		e := s.transaction(r.Context(), func(t *sql.Tx) error {
			var id int64
			for _, d := range ds {
				e := t.QueryRowContext(r.Context(), "SELECT site_id FROM website_domains WHERE domain=?", d).Scan(&id)
				if e == nil {
					break
				}
				if !errors.Is(e, sql.ErrNoRows) {
					return e
				}
			}
			if id == 0 {
				res, e := t.ExecContext(r.Context(), "INSERT INTO websites(name_zh,name_en,home_url,icon_sha256,icon_mime,icon_bytes,icon_updated_ms,status,created_ms,updated_ms) VALUES(?,?,?,?,?,?,?,1,?,?)", nullable(site.NameZH), site.NameEN, nullable(site.HomeURL), sha, mime, size, iconTime, now(), now())
				if e != nil {
					return e
				}
				id, e = res.LastInsertId()
				if e != nil {
					return e
				}
			} else {
				if _, e := t.ExecContext(r.Context(), "UPDATE websites SET name_zh=?,name_en=?,home_url=COALESCE(?,home_url),icon_sha256=COALESCE(?,icon_sha256),icon_mime=COALESCE(?,icon_mime),icon_bytes=COALESCE(?,icon_bytes),icon_updated_ms=COALESCE(?,icon_updated_ms),updated_ms=? WHERE site_id=?", nullable(site.NameZH), site.NameEN, nullable(site.HomeURL), sha, mime, size, iconTime, now(), id); e != nil {
					return e
				}
			}
			if _, e := t.ExecContext(r.Context(), "UPDATE website_domains SET is_primary=0 WHERE site_id=?", id); e != nil {
				return e
			}
			for _, d := range ds {
				if _, e := t.ExecContext(r.Context(), "INSERT INTO website_domains(domain,site_id,is_primary) VALUES(?,?,?) ON DUPLICATE KEY UPDATE site_id=VALUES(site_id),is_primary=VALUES(is_primary)", d, id, d == p); e != nil {
					return e
				}
			}
			return nil
		})
		if e != nil {
			return e
		}
	}
	s.audit(r.Context(), "admin_sites_upsert", "", "", map[string]int{"n": len(b.Sites)})
	writeJSON(w, 200, map[string]any{"ok": true, "upserted": len(b.Sites)})
	return nil
}

// breach forwards only a validated five-character SHA-1 prefix to the range service; neither password nor full hash is accepted.
func (s *Server) breach(w http.ResponseWriter, r *http.Request) error {
	p := param(r, "prefix")
	if !prefixPattern.MatchString(p) {
		return fail(400, "bad_request")
	}
	req, e := http.NewRequestWithContext(r.Context(), http.MethodGet, "https://api.pwnedpasswords.com/range/"+strings.ToUpper(p), nil)
	if e != nil {
		return e
	}
	req.Header.Set("Add-Padding", "true")
	resp, e := s.HTTP.Do(req)
	if e != nil {
		return fail(502, "upstream_unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fail(502, "upstream_unavailable")
	}
	raw, e := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if e != nil {
		return fail(502, "upstream_unavailable")
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, e = w.Write(raw)
	return e
}
