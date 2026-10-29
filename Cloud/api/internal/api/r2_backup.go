package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const r2BackupRetention = 30 * 24 * time.Hour

type r2BackupEntry struct {
	Key       string     `json:"key"`
	ETag      string     `json:"etag"`
	Size      int64      `json:"size"`
	Modified  time.Time  `json:"modified"`
	DeletedAt *time.Time `json:"deletedAt,omitempty"`
}

// BackupR2 incrementally copies encrypted objects and keeps deleted or replaced
// versions for the configured recovery window. A failed run never publishes a
// manifest that claims the backup is complete.
func BackupR2(ctx context.Context, objects ObjectStore, directory string) error {
	if directory == "" {
		return errors.New("R2 backup directory is required")
	}
	objectsDirectory := filepath.Join(directory, "objects")
	if err := os.MkdirAll(objectsDirectory, 0o700); err != nil {
		return fmt.Errorf("create R2 backup directory: %w", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return fmt.Errorf("protect R2 backup directory: %w", err)
	}
	if err := os.Chmod(objectsDirectory, 0o700); err != nil {
		return fmt.Errorf("protect R2 objects directory: %w", err)
	}
	manifestPath := filepath.Join(directory, "manifest.json")
	previous, err := readR2BackupManifest(manifestPath)
	if err != nil {
		return err
	}

	current := make(map[string]r2BackupEntry)
	cursor := ""
	for {
		page, next, err := objects.List(ctx, "", cursor)
		if err != nil {
			return fmt.Errorf("list R2 objects: %w", err)
		}
		for _, object := range page {
			if _, exists := current[object.Key]; exists {
				return fmt.Errorf("R2 listing returned duplicate key %q", object.Key)
			}
			if object.ETag == "" {
				return errors.New("R2 listing omitted an object ETag")
			}
			entry := r2BackupEntry{
				Key: object.Key, ETag: object.ETag, Size: object.Size, Modified: object.Modified,
			}
			current[object.Key] = entry
			objectPath, err := r2ObjectPath(directory, object.Key, object)
			if err != nil {
				return err
			}
			if hasR2BackupVersion(previous, entry) {
				if _, err := os.Stat(objectPath); err == nil {
					continue
				} else if !errors.Is(err, os.ErrNotExist) {
					return fmt.Errorf("inspect R2 backup object %q: %w", object.Key, err)
				}
			}
			if err := copyR2Object(ctx, objects, object, objectPath); err != nil {
				return err
			}
		}
		if next == "" {
			break
		}
		if next == cursor {
			return errors.New("R2 listing made no progress")
		}
		cursor = next
	}

	now := time.Now().UTC()
	entries := make([]r2BackupEntry, 0, len(previous)+len(current))
	removeAfterPublish := make([]string, 0)
	for _, old := range previous {
		if found, exists := current[old.Key]; exists && sameR2Version(found, old) {
			old.DeletedAt = nil
			entries = append(entries, old)
			continue
		}
		if old.DeletedAt == nil {
			deletedAt := now
			old.DeletedAt = &deletedAt
		}
		if now.Sub(*old.DeletedAt) >= r2BackupRetention {
			object := Object{Key: old.Key, ETag: old.ETag, Size: old.Size, Modified: old.Modified}
			objectPath, err := r2ObjectPath(directory, old.Key, object)
			if err != nil {
				return err
			}
			removeAfterPublish = append(removeAfterPublish, objectPath)
			continue
		}
		entries = append(entries, old)
	}
	for _, entry := range current {
		if hasR2BackupVersion(previous, entry) {
			continue
		}
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Key != entries[j].Key {
			return entries[i].Key < entries[j].Key
		}
		return entries[i].Modified.Before(entries[j].Modified)
	})
	if err := writeR2BackupManifest(manifestPath, entries); err != nil {
		return err
	}
	for _, objectPath := range removeAfterPublish {
		if err := os.Remove(objectPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("remove expired R2 backup object: %w", err)
		}
	}
	return nil
}

func readR2BackupManifest(manifestPath string) ([]r2BackupEntry, error) {
	data, err := os.ReadFile(manifestPath)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read R2 backup manifest: %w", err)
	}
	var entries []r2BackupEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("read R2 backup manifest: %w", err)
	}
	for _, entry := range entries {
		if _, err := r2ObjectPath(filepath.Dir(manifestPath), entry.Key, Object{
			Key: entry.Key, ETag: entry.ETag, Size: entry.Size, Modified: entry.Modified,
		}); err != nil {
			return nil, fmt.Errorf("validate R2 backup manifest: %w", err)
		}
	}
	return entries, nil
}

func writeR2BackupManifest(manifestPath string, entries []r2BackupEntry) error {
	data, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return fmt.Errorf("encode R2 backup manifest: %w", err)
	}
	tmp := manifestPath + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("write R2 backup manifest: %w", err)
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("protect R2 backup manifest: %w", err)
	}
	if err := os.Rename(tmp, manifestPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish R2 backup manifest: %w", err)
	}
	return nil
}

func hasR2BackupVersion(entries []r2BackupEntry, candidate r2BackupEntry) bool {
	for _, entry := range entries {
		if sameR2Version(entry, candidate) {
			return true
		}
	}
	return false
}

func sameR2Version(left, right r2BackupEntry) bool {
	return left.Key == right.Key && left.ETag == right.ETag && left.Size == right.Size && left.Modified.Equal(right.Modified)
}

func copyR2Object(ctx context.Context, objects ObjectStore, expected Object, objectPath string) error {
	body, actual, err := objects.Get(ctx, expected.Key)
	if err != nil {
		return fmt.Errorf("read R2 object %q: %w", expected.Key, err)
	}
	defer body.Close()
	if actual.ETag != expected.ETag || actual.Size != expected.Size {
		return fmt.Errorf("R2 object %q changed while being backed up", expected.Key)
	}
	if err := os.MkdirAll(filepath.Dir(objectPath), 0o700); err != nil {
		return fmt.Errorf("create R2 object directory: %w", err)
	}
	if err := os.Chmod(filepath.Dir(objectPath), 0o700); err != nil {
		return fmt.Errorf("protect R2 object directory: %w", err)
	}
	tmp := objectPath + ".tmp"
	file, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create R2 object backup: %w", err)
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("protect R2 object backup: %w", err)
	}
	copiedBytes, err := io.Copy(file, body)
	if err != nil {
		_ = file.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("copy R2 object %q: %w", expected.Key, err)
	}
	if copiedBytes != expected.Size {
		_ = file.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("R2 object %q size changed while being backed up", expected.Key)
	}
	if err = file.Close(); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("close R2 object backup: %w", err)
	}
	if err = os.Rename(tmp, objectPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("publish R2 object backup: %w", err)
	}
	return nil
}

func r2ObjectPath(directory, key string, object Object) (string, error) {
	if key == "" || strings.ContainsRune(key, '\x00') {
		return "", errors.New("R2 object has an invalid key")
	}
	clean := path.Clean(key)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") || strings.HasPrefix(clean, "/") {
		return "", errors.New("R2 object escapes backup directory")
	}
	keyHash := sha256.Sum256([]byte(key))
	version := object.Modified.UTC().Format("20060102T150405.000000000Z")
	etagHash := sha256.Sum256([]byte(object.ETag))
	filename := fmt.Sprintf("%s-%d-%s.blob", version, object.Size, hex.EncodeToString(etagHash[:8]))
	return filepath.Join(directory, "objects", hex.EncodeToString(keyHash[:]), filename), nil
}
