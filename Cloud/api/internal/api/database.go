// MariaDB 连接与 TLS 校验；连接配置来自部署环境，不在源码保存凭据。
package api

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/pem"
	"errors"
	"github.com/go-sql-driver/mysql"
	"os"
	"time"
)

// OpenDatabase creates one bounded process-wide pool with certificate verification by default.
func OpenDatabase(ctx context.Context, c Config) (*sql.DB, error) {
	config := mysql.NewConfig()
	config.User = c.DBUser
	config.Passwd = c.DBPassword
	config.Net = "tcp"
	config.Addr = c.DBAddress
	config.DBName = c.DBName
	config.Timeout = 5 * time.Second
	config.ReadTimeout = 30 * time.Second
	config.WriteTimeout = 30 * time.Second
	config.MultiStatements = false
	config.InterpolateParams = false
	config.ParseTime = true
	config.Collation = "utf8mb4_unicode_ci"
	if c.DBTLS == "pinned" {
		raw, e := os.ReadFile(c.DBCA)
		if e != nil {
			return nil, errors.New("cannot read pinned database certificate")
		}
		block, _ := pem.Decode(raw)
		if block == nil {
			return nil, errors.New("invalid pinned certificate")
		}
		cert, e := x509.ParseCertificate(block.Bytes)
		if e != nil {
			return nil, e
		}
		want := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
		verify := func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) < 1 {
				return errors.New("database certificate absent")
			}
			peer := cs.PeerCertificates[0]
			ts := time.Now()
			if ts.Before(peer.NotBefore) || ts.After(peer.NotAfter) {
				return errors.New("database certificate expired")
			}
			got := sha256.Sum256(peer.RawSubjectPublicKeyInfo)
			if subtle.ConstantTimeCompare(want[:], got[:]) != 1 {
				return errors.New("database certificate key mismatch")
			}
			return nil
		}
		// The existing MariaDB automatic certificate has no hostname SAN. VerifyConnection enforces an exact out-of-band public-key pin instead.
		if e = mysql.RegisterTLSConfig("upw-pinned", &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true, VerifyConnection: verify}); e != nil {
			return nil, e
		}
		config.TLSConfig = "upw-pinned"
	} else if c.DBTLS == "verify" {
		config.TLSConfig = "true"
		if c.DBCA != "" {
			pem, e := os.ReadFile(c.DBCA)
			if e != nil {
				return nil, errors.New("cannot read database CA")
			}
			roots := x509.NewCertPool()
			if !roots.AppendCertsFromPEM(pem) {
				return nil, errors.New("invalid database CA")
			}
			if e = mysql.RegisterTLSConfig("upw-verified", &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}); e != nil {
				return nil, e
			}
			config.TLSConfig = "upw-verified"
		}
	} else {
		return nil, errors.New("invalid database TLS mode")
	}
	connector, e := mysql.NewConnector(config)
	if e != nil {
		return nil, e
	}
	db := sql.OpenDB(connector)
	db.SetMaxOpenConns(16)
	db.SetMaxIdleConns(8)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	if e = db.PingContext(ctx); e != nil {
		db.Close()
		return nil, errors.New("database connection failed")
	}
	return db, nil
}
