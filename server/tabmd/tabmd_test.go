package tabmd

import (
	"cursortab/assert"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRead_Present(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, DocName), []byte("  hello world  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	assert.Equal(t, "hello world", Read(dir), "trims surrounding whitespace")
}

func TestRead_EmptyWorkspacePath(t *testing.T) {
	assert.Equal(t, "", Read(""), "empty workspace path yields empty")
}

func TestRead_Missing(t *testing.T) {
	assert.Equal(t, "", Read(t.TempDir()), "missing file yields empty")
}

func TestRead_CapsToMaxBytes(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, DocName), []byte(strings.Repeat("a", MaxBytes+100)), 0o644); err != nil {
		t.Fatal(err)
	}
	assert.Equal(t, MaxBytes, len(Read(dir)), "caps content to MaxBytes")
}
