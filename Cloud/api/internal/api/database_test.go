package api

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"testing"
	"time"
)

func makeDatabaseTestCertificate(t *testing.T, now time.Time) (*x509.Certificate, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(now.UnixNano()),
		Subject:               pkix.Name{CommonName: "test database"},
		NotBefore:             now.Add(-time.Minute),
		NotAfter:              now.Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	encoded := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return certificate, encoded
}

func TestParseDatabaseCertificatePinsSupportsRotationBundle(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	first, firstPEM := makeDatabaseTestCertificate(t, now)
	second, secondPEM := makeDatabaseTestCertificate(t, now)
	pins, err := parseDatabaseCertificatePins(bytes.Join([][]byte{firstPEM, secondPEM}, []byte("\n")))
	if err != nil {
		t.Fatal(err)
	}
	if len(pins) != 2 {
		t.Fatalf("got %d pins, want 2", len(pins))
	}
	if pins[0] != sha256.Sum256(first.RawSubjectPublicKeyInfo) || pins[1] != sha256.Sum256(second.RawSubjectPublicKeyInfo) {
		t.Fatal("certificate bundle produced incorrect public-key pins")
	}
}

func TestParseDatabaseCertificatePinsRejectsMalformedBundles(t *testing.T) {
	_, certificatePEM := makeDatabaseTestCertificate(t, time.Now().UTC())
	privateKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte("invalid")})
	malformedCertificatePEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte("invalid")})
	tooManyCertificates := bytes.Repeat(certificatePEM, maxDatabaseCertificatePins+1)
	for name, raw := range map[string][]byte{
		"empty":                 nil,
		"non-pem":               []byte("not a certificate"),
		"private-key":           privateKeyPEM,
		"malformed-certificate": malformedCertificatePEM,
		"trailing-data":         append(append([]byte(nil), certificatePEM...), []byte("unexpected")...),
		"too-many":              tooManyCertificates,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseDatabaseCertificatePins(raw); err == nil {
				t.Fatal("malformed certificate bundle was accepted")
			}
		})
	}
}

func TestVerifyDatabaseCertificateAcceptsAnyConfiguredPin(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	_, firstPEM := makeDatabaseTestCertificate(t, now)
	second, secondPEM := makeDatabaseTestCertificate(t, now)
	pins, err := parseDatabaseCertificatePins(append(firstPEM, secondPEM...))
	if err != nil {
		t.Fatal(err)
	}
	state := tls.ConnectionState{PeerCertificates: []*x509.Certificate{second}}
	if err := verifyDatabaseCertificate(state, pins, now); err != nil {
		t.Fatalf("second configured pin was rejected: %v", err)
	}
	unknown, _ := makeDatabaseTestCertificate(t, now)
	state.PeerCertificates[0] = unknown
	if err := verifyDatabaseCertificate(state, pins, now); !errors.Is(err, errDatabaseCertificateKeyMismatch) {
		t.Fatalf("unknown pin returned %v", err)
	}
}

func TestVerifyDatabaseCertificateRejectsExpiredAndMissingCertificates(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	certificate, certificatePEM := makeDatabaseTestCertificate(t, now)
	pins, err := parseDatabaseCertificatePins(certificatePEM)
	if err != nil {
		t.Fatal(err)
	}
	state := tls.ConnectionState{PeerCertificates: []*x509.Certificate{certificate}}
	if err := verifyDatabaseCertificate(state, pins, now.Add(2*time.Hour)); err == nil {
		t.Fatal("expired peer certificate was accepted")
	}
	if err := verifyDatabaseCertificate(tls.ConnectionState{}, pins, now); err == nil {
		t.Fatal("missing peer certificate was accepted")
	}
}

func TestDatabaseConnectionFailureReportsPinMismatchWithoutDriverDetails(t *testing.T) {
	err := fmt.Errorf("%w: private driver detail", errDatabaseCertificateKeyMismatch)
	got := databaseConnectionFailure(err).Error()
	if got != "database connection failed: certificate pin mismatch" {
		t.Fatalf("unexpected safe error: %q", got)
	}
	if got := databaseConnectionFailure(errors.New("private driver detail")).Error(); got != "database connection failed" {
		t.Fatalf("generic database error leaked details: %q", got)
	}
}
