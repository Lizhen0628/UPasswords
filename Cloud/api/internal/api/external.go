package api

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"net/smtp"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/smithy-go"
)

// Object is metadata for an encrypted blob or public catalog icon.
type Object struct {
	Key, ContentType string
	Size             int64
	Modified         time.Time
}

// ObjectStore abstracts R2 via its standard S3 API for isolated integration tests.
type ObjectStore interface {
	Put(context.Context, string, []byte, string) error
	Get(context.Context, string) (io.ReadCloser, Object, error)
	Delete(context.Context, string) error
	List(context.Context, string, string) ([]Object, string, error)
}
type S3Store struct {
	Client *s3.Client
	Bucket string
}

func NewS3(c Config) *S3Store {
	return &S3Store{Client: s3.NewFromConfig(aws.Config{Region: "auto", Credentials: credentials.NewStaticCredentialsProvider(c.R2AccessKey, c.R2SecretKey, "")}, func(o *s3.Options) { o.BaseEndpoint = aws.String(c.R2Endpoint) }), Bucket: c.R2Bucket}
}
func (s *S3Store) Put(ctx context.Context, key string, b []byte, mime string) error {
	_, e := s.Client.PutObject(ctx, &s3.PutObjectInput{Bucket: &s.Bucket, Key: &key, Body: bytes.NewReader(b), ContentType: &mime})
	return e
}
func (s *S3Store) Get(ctx context.Context, key string) (io.ReadCloser, Object, error) {
	v, e := s.Client.GetObject(ctx, &s3.GetObjectInput{Bucket: &s.Bucket, Key: &key})
	if e != nil {
		var a smithy.APIError
		if errors.As(e, &a) && (a.ErrorCode() == "NoSuchKey" || a.ErrorCode() == "NotFound") {
			return nil, Object{}, fail(404, "not_found")
		}
		return nil, Object{}, e
	}
	return v.Body, Object{Key: key, Size: aws.ToInt64(v.ContentLength), ContentType: aws.ToString(v.ContentType), Modified: aws.ToTime(v.LastModified)}, nil
}
func (s *S3Store) Delete(ctx context.Context, key string) error {
	_, e := s.Client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &s.Bucket, Key: &key})
	return e
}
func (s *S3Store) List(ctx context.Context, prefix, cursor string) ([]Object, string, error) {
	in := &s3.ListObjectsV2Input{Bucket: &s.Bucket, Prefix: &prefix}
	if cursor != "" {
		in.ContinuationToken = &cursor
	}
	v, e := s.Client.ListObjectsV2(ctx, in)
	if e != nil {
		return nil, "", e
	}
	out := []Object{}
	for _, o := range v.Contents {
		out = append(out, Object{Key: aws.ToString(o.Key), Size: aws.ToInt64(o.Size), Modified: aws.ToTime(o.LastModified)})
	}
	return out, aws.ToString(v.NextContinuationToken), nil
}
func (s *Server) deletePrefix(ctx context.Context, prefix string) error {
	cursor := ""
	for {
		objects, next, e := s.Objects.List(ctx, prefix, cursor)
		if e != nil {
			return e
		}
		for _, o := range objects {
			if e = s.Objects.Delete(ctx, o.Key); e != nil {
				return e
			}
		}
		if next == "" {
			return nil
		}
		if next == cursor {
			return errors.New("object listing made no progress")
		}
		cursor = next
	}
}

// Mailer sends verification mail; production has no mock-code environment switch.
type Mailer interface {
	Send(context.Context, string, string, string, bool) error
}
type SMTPMailer struct{ Config Config }

func (m SMTPMailer) Send(ctx context.Context, to, code, purpose string, zh bool) error {
	c := m.Config
	d := net.Dialer{Timeout: 10 * time.Second}
	tlsDial := tls.Dialer{NetDialer: &d, Config: &tls.Config{ServerName: c.SMTPHost, MinVersion: tls.VersionTLS12}}
	conn, e := tlsDial.DialContext(ctx, "tcp", net.JoinHostPort(c.SMTPHost, c.SMTPPort))
	if e != nil {
		return e
	}
	defer conn.Close()
	deadline := time.Now().Add(15 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	if e = conn.SetDeadline(deadline); e != nil {
		return e
	}
	client, e := smtp.NewClient(conn, c.SMTPHost)
	if e != nil {
		return e
	}
	defer client.Close()
	if e = client.Auth(smtp.PlainAuth("", c.SMTPUser, c.SMTPPassword, c.SMTPHost)); e != nil {
		return e
	}
	if e = client.Mail(c.SMTPFrom); e != nil {
		return e
	}
	if e = client.Rcpt(to); e != nil {
		return e
	}
	w, e := client.Data()
	if e != nil {
		return e
	}
	if _, e = io.WriteString(w, verificationMessage(c, to, code, purpose, zh)); e != nil {
		return e
	}
	if e = w.Close(); e != nil {
		return e
	}
	return client.Quit()
}
func verificationMessage(c Config, to, code, purpose string, zh bool) string {
	subject := "UPasswords sign-in code"
	text := "Your UPasswords verification code: " + code + "\nThis code expires in 10 minutes.\nIf you did not request it, please ignore this email."
	if purpose == "sensitive" {
		subject = "UPasswords security code"
	}
	if zh {
		subject = "UPasswords 登录验证码"
		if purpose == "sensitive" {
			subject = "UPasswords 安全操作验证码"
		}
		text = "您的 UPasswords 验证码：" + code + "\n验证码 10 分钟内有效，请勿泄露给任何人。\n若非本人操作，请忽略本邮件。"
	}
	// All dynamic addresses come from strict validation/config; forbid header injection as a second boundary.
	clean := func(v string) string { return strings.NewReplacer("\r", "", "\n", "").Replace(v) }
	return fmt.Sprintf("From: %s\r\nReply-To: %s\r\nTo: %s\r\nSubject: =?UTF-8?B?%s?=\r\nDate: %s\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n%s\r\n", clean(c.SMTPFrom), clean(mailReplyTo(c, purpose)), clean(to), base64.StdEncoding.EncodeToString([]byte(subject)), time.Now().Format(time.RFC1123Z), base64.StdEncoding.EncodeToString([]byte(text)))
}

// mailReplyTo routes replies by registration or verification purpose.
func mailReplyTo(c Config, purpose string) string {
	if purpose == "register" && c.SMTPRegisterReplyTo != "" {
		return c.SMTPRegisterReplyTo
	}
	if c.SMTPVerifyReplyTo != "" {
		return c.SMTPVerifyReplyTo
	}
	return c.SMTPReplyTo
}
