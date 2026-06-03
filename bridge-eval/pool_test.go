package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPoolRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pool.tsv")

	l1 := "obfs4 1.2.3.4:443 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA cert=abc+/def iat-mode=0"
	l2 := "obfs4 5.6.7.8:80 BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB cert=zzz iat-mode=1"
	in := map[string]*poolEntry{
		"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA": {line: l1, lastAlive: 1717000000, fails: 0, source: "fetch"},
		"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB": {line: l2, lastAlive: 0, fails: 3, source: "fetch"},
	}
	if err := savePool(path, in); err != nil {
		t.Fatalf("savePool: %v", err)
	}
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
		t.Fatalf("pool file perms: %v mode=%v", err, fi.Mode().Perm())
	}

	out := loadPool(path)
	if len(out) != 2 {
		t.Fatalf("loaded %d entries, want 2", len(out))
	}
	a := out["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]
	if a == nil || a.line != l1 || a.lastAlive != 1717000000 || a.fails != 0 {
		t.Fatalf("entry A round-trip mismatch: %+v", a)
	}
	b := out["BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"]
	if b == nil || b.fails != 3 || b.lastAlive != 0 {
		t.Fatalf("entry B round-trip mismatch: %+v", b)
	}
}

func TestLoadPoolMissingFileIsEmpty(t *testing.T) {
	if got := loadPool(filepath.Join(t.TempDir(), "nope.tsv")); len(got) != 0 {
		t.Fatalf("missing file should yield empty pool, got %d", len(got))
	}
}

func TestLoadPoolSkipsGarbage(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "p.tsv")
	os.WriteFile(path, []byte("# comment\n\nnot a bridge line\nobfs4 9.9.9.9:443 CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC cert=q iat-mode=0\t0\t0\tfetch\n"), 0o600)
	got := loadPool(path)
	if len(got) != 1 {
		t.Fatalf("want 1 valid entry, got %d", len(got))
	}
}
