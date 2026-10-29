// MariaDB 连接与 TLS 校验；连接配置来自部署环境，不在源码保存凭据。
package api

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"database/sql"
	"encoding/pem"
	"errors"
	"os"
	"time"

	"github.com/go-sql-driver/mysql"
)

const maxDatabaseCertificatePins = 4

var errDatabaseCertificateKeyMismatch = errors.New("database certificate key mismatch")

func parseDatabaseCertificatePins(raw []byte) ([][sha256.Size]byte, error) {
	pins := make([][sha256.Size]byte, 0, 2)
	remaining := bytes.TrimSpace(raw)
	for len(remaining) > 0 {
		if !bytes.HasPrefix(remaining, []byte("-----BEGIN CERTIFICATE-----")) {
			return nil, errors.New("invalid pinned certificate bundle")
		}
		block, rest := pem.Decode(remaining)
		if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 {
			return nil, errors.New("invalid pinned certificate bundle")
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, errors.New("invalid pinned certificate bundle")
		}
		pins = append(pins, sha256.Sum256(certificate.RawSubjectPublicKeyInfo))
		if len(pins) > maxDatabaseCertificatePins {
			return nil, errors.New("too many pinned database certificates")
		}
		remaining = bytes.TrimSpace(rest)
	}
	if len(pins) == 0 {
		return nil, errors.New("invalid pinned certificate bundle")
	}
	return pins, nil
}

func verifyDatabaseCertificate(
	state tls.ConnectionState, pins [][sha256.Size]byte, now time.Time,
) error {
	if len(state.PeerCertificates) == 0 {
		return errors.New("database certificate absent")
	}
	peer := state.PeerCertificates[0]
	if now.Before(peer.NotBefore) || now.After(peer.NotAfter) {
		return errors.New("database certificate expired")
	}
	got := sha256.Sum256(peer.RawSubjectPublicKeyInfo)
	matched := 0
	for _, pin := range pins {
		matched |= subtle.ConstantTimeCompare(pin[:], got[:])
	}
	if matched != 1 {
		return errDatabaseCertificateKeyMismatch
	}
	return nil
}

func databaseConnectionFailure(err error) error {
	if errors.Is(err, errDatabaseCertificateKeyMismatch) {
		return errors.New("database connection failed: certificate pin mismatch")
	}
	return errors.New("database connection failed")
}

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
		pins, e := parseDatabaseCertificatePins(raw)
		if e != nil {
			return nil, e
		}
		verify := func(cs tls.ConnectionState) error {
			return verifyDatabaseCertificate(cs, pins, time.Now())
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
		return nil, databaseConnectionFailure(e)
	}
	return db, nil
}
