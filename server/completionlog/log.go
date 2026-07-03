package completionlog

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Event is one append-only JSONL row describing the final outcome of a shown
// completion proposal.
type Event struct {
	TS        time.Time `json:"ts"`
	Provider  string    `json:"provider"`
	Model     string    `json:"model,omitempty"`
	File      string    `json:"file,omitempty"`
	Row       int       `json:"row"`
	Col       int       `json:"col"`
	Trigger   string    `json:"trigger"`
	Outcome   string    `json:"outcome"`
	Proposed  string    `json:"proposed,omitempty"`
	Before    string    `json:"before,omitempty"`
	After     string    `json:"after,omitempty"`
	LatencyMS int64     `json:"latency_ms,omitempty"`
}

// Logger appends completion events to a JSONL file. It is safe for concurrent
// use; write failures are returned to the caller but never panic.
type Logger struct {
	mu   sync.Mutex
	file *os.File
}

func Open(path string) (*Logger, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	return &Logger{file: file}, nil
}

func (l *Logger) Write(event Event) error {
	if l == nil {
		return nil
	}
	if event.TS.IsZero() {
		event.TS = time.Now().UTC()
	}
	data, err := json.Marshal(event)
	if err != nil {
		return err
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if _, err := l.file.Write(append(data, '\n')); err != nil {
		return err
	}
	return nil
}

func (l *Logger) Close() error {
	if l == nil {
		return nil
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.file.Close()
}
