package completionlog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cursortab/assert"
)

func TestLoggerWritesJSONL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "completions.jsonl")
	log, err := Open(path)
	assert.NoError(t, err, "open logger")

	err = log.Write(Event{
		Provider: "sweep",
		Model:    "sweep-next-edit-1.5B",
		File:     "main.go",
		Row:      10,
		Col:      4,
		Trigger:  "auto",
		Outcome:  "accepted",
		Proposed: "return nil",
		Before:   "return err",
		After:    "return nil",
	})
	assert.NoError(t, err, "write event")
	assert.NoError(t, log.Close(), "close logger")

	data, err := os.ReadFile(path)
	assert.NoError(t, err, "read log")
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	assert.Len(t, 1, lines, "line count")

	var event Event
	assert.NoError(t, json.Unmarshal([]byte(lines[0]), &event), "decode event")
	assert.Equal(t, "sweep", event.Provider, "provider")
	assert.Equal(t, "accepted", event.Outcome, "outcome")
	assert.False(t, event.TS.IsZero(), "timestamp set")
}
