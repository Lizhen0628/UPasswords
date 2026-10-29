package main

import (
	"context"
	"errors"
	backend "github.com/Lizhen0628/UPasswords/Cloud/api/internal/api"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	if e := run(); e != nil {
		slog.Error("service stopped", "reason", e.Error())
		os.Exit(1)
	}
}
func run() error {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(log)
	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		client := http.Client{Timeout: 3 * time.Second}
		resp, e := client.Get("http://127.0.0.1:8080/health/ready")
		if e != nil {
			return errors.New("readiness probe failed")
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			return errors.New("readiness probe failed")
		}
		return nil
	}
	c, e := backend.LoadConfig()
	if e != nil {
		return e
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if len(os.Args) > 1 && os.Args[1] == "backup-r2" {
		if len(os.Args) != 3 {
			return errors.New("usage: backup-r2 DIRECTORY")
		}
		return backend.BackupR2(ctx, backend.NewS3(c), os.Args[2])
	}
	db, e := backend.OpenDatabase(ctx, c)
	if e != nil {
		return e
	}
	defer db.Close()
	s := &backend.Server{DB: db, Config: c, Objects: backend.NewS3(c), Mailer: backend.SMTPMailer{Config: c}, Log: log, HTTP: &http.Client{Timeout: 15 * time.Second}}
	if len(os.Args) > 1 && os.Args[1] == "check" {
		return s.CheckDependencies(ctx)
	}
	if len(os.Args) > 1 && os.Args[1] == "schedule" {
		return s.ScheduleMaintenance(ctx)
	}
	if len(os.Args) > 1 && os.Args[1] == "maintain" {
		ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
		defer cancel()
		return s.Maintain(ctx)
	}
	server := http.Server{Addr: c.Address, Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 45 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	errs := make(chan error, 1)
	go func() { log.Info("api started", "address", c.Address); errs <- server.ListenAndServe() }()
	select {
	case e = <-errs:
		if !errors.Is(e, http.ErrServerClosed) {
			return e
		}
	case <-ctx.Done():
	}
	log.Info("api shutdown started")
	shutdown, cancelShutdown := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancelShutdown()
	if e = server.Shutdown(shutdown); e != nil {
		return e
	}
	log.Info("api shutdown completed")
	return nil
}
