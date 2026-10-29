package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"testing"
	"time"
)

type r2BackupTestObject struct {
	object Object
	data   []byte
}

type r2BackupTestStore struct {
	objects  map[string]r2BackupTestObject
	pageSize int
	getCalls map[string]int
	failGet  string
}

func (store *r2BackupTestStore) Put(_ context.Context, key string, data []byte, contentType string) error {
	store.objects[key] = r2BackupTestObject{
		object: Object{Key: key, ETag: key + "-etag", Size: int64(len(data)), ContentType: contentType, Modified: time.Now().UTC()},
		data:   append([]byte(nil), data...),
	}
	return nil
}

func (store *r2BackupTestStore) Get(_ context.Context, key string) (io.ReadCloser, Object, error) {
	store.getCalls[key]++
	if key == store.failGet {
		return nil, Object{}, errors.New("injected object read failure")
	}
	value, exists := store.objects[key]
	if !exists {
		return nil, Object{}, errors.New("object not found")
	}
	return io.NopCloser(bytes.NewReader(value.data)), value.object, nil
}

func (store *r2BackupTestStore) Delete(_ context.Context, key string) error {
	delete(store.objects, key)
	return nil
}

func (store *r2BackupTestStore) List(_ context.Context, prefix, cursor string) ([]Object, string, error) {
	keys := make([]string, 0, len(store.objects))
	for key := range store.objects {
		if bytes.HasPrefix([]byte(key), []byte(prefix)) {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	start := 0
	if cursor != "" {
		parsed, err := strconv.Atoi(cursor)
		if err != nil {
			return nil, "", err
		}
		start = parsed
	}
	end := min(start+store.pageSize, len(keys))
	page := make([]Object, 0, end-start)
	for _, key := range keys[start:end] {
		page = append(page, store.objects[key].object)
	}
	if end == len(keys) {
		return page, "", nil
	}
	return page, strconv.Itoa(end), nil
}

func TestBackupR2PaginatesAndReusesUnchangedVersions(t *testing.T) {
	now := time.Date(2026, 10, 28, 12, 0, 0, 0, time.UTC)
	store := &r2BackupTestStore{
		objects: map[string]r2BackupTestObject{
			"attachments/a": {object: Object{Key: "attachments/a", ETag: "a-v1", Size: 1, Modified: now}, data: []byte("a")},
			"attachments/b": {object: Object{Key: "attachments/b", ETag: "b-v1", Size: 1, Modified: now}, data: []byte("b")},
			"icons/c":       {object: Object{Key: "icons/c", ETag: "c-v1", Size: 1, Modified: now}, data: []byte("c")},
		},
		pageSize: 1,
		getCalls: make(map[string]int),
	}
	directory := t.TempDir()

	if err := BackupR2(context.Background(), store, directory); err != nil {
		t.Fatal(err)
	}
	if got := len(store.getCalls); got != 3 {
		t.Fatalf("first run downloaded %d objects, want 3", got)
	}
	for key := range store.objects {
		if store.getCalls[key] != 1 {
			t.Fatalf("object %q was not fetched exactly once", key)
		}
	}

	if err := BackupR2(context.Background(), store, directory); err != nil {
		t.Fatal(err)
	}
	for key := range store.objects {
		if store.getCalls[key] != 1 {
			t.Fatalf("unchanged object %q was downloaded again", key)
		}
	}

	newObject := Object{Key: "attachments/new", ETag: "new-v1", Size: 3, Modified: now.Add(time.Minute)}
	store.objects[newObject.Key] = r2BackupTestObject{object: newObject, data: []byte("new")}
	changedObject := Object{Key: "attachments/a", ETag: "a-v2", Size: 1, Modified: now}
	previousChangedObjectCalls := store.getCalls[changedObject.Key]
	store.objects[changedObject.Key] = r2BackupTestObject{object: changedObject, data: []byte("A")}
	if err := BackupR2(context.Background(), store, directory); err != nil {
		t.Fatal(err)
	}
	if store.getCalls[newObject.Key] != 1 || store.getCalls[changedObject.Key] != previousChangedObjectCalls+1 {
		t.Fatalf("new and changed R2 versions were not downloaded once: calls=%v", store.getCalls)
	}

	data, err := os.ReadFile(filepath.Join(directory, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest []r2BackupEntry
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest) != 5 {
		t.Fatalf("manifest has %d current and retained versions, want 5", len(manifest))
	}
	var retainedOldVersion bool
	for _, entry := range manifest {
		if entry.Key == "attachments/a" && entry.Size == 1 && entry.DeletedAt != nil {
			retainedOldVersion = true
		}
	}
	if !retainedOldVersion {
		t.Fatal("replaced object version was not retained for recovery")
	}
}

func TestBackupR2RejectsPathTraversalWithoutPublishingManifest(t *testing.T) {
	store := &r2BackupTestStore{
		objects: map[string]r2BackupTestObject{
			"../outside": {object: Object{Key: "../outside", ETag: "x", Size: 1, Modified: time.Now()}, data: []byte("x")},
		},
		pageSize: 10,
		getCalls: make(map[string]int),
	}
	directory := t.TempDir()

	if err := BackupR2(context.Background(), store, directory); err == nil {
		t.Fatal("path traversal key was accepted")
	}
	if _, err := os.Stat(filepath.Join(directory, "manifest.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("manifest was published after path validation failed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(directory), "outside")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("object escaped backup directory: %v", err)
	}
}

func TestBackupR2DoesNotPublishManifestAfterDownloadFailure(t *testing.T) {
	store := &r2BackupTestStore{
		objects: map[string]r2BackupTestObject{
			"a": {object: Object{Key: "a", ETag: "a-v1", Size: 1, Modified: time.Now()}, data: []byte("a")},
			"b": {object: Object{Key: "b", ETag: "b-v1", Size: 1, Modified: time.Now()}, data: []byte("b")},
		},
		pageSize: 10,
		getCalls: make(map[string]int),
		failGet:  "b",
	}
	directory := t.TempDir()

	if err := BackupR2(context.Background(), store, directory); err == nil {
		t.Fatal("injected download failure was ignored")
	}
	if _, err := os.Stat(filepath.Join(directory, "manifest.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("manifest was published after an incomplete download: %v", err)
	}
}
