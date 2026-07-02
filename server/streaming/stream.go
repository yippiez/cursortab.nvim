// Package streaming carries a line-oriented completion stream from a provider
// transport to the engine. Stream is the single runtime object on that path:
// it assembles raw text chunks into lines, applies stop tokens, line limits,
// prefill, per-line transforms, and first-line validation, and finally hands
// the accumulated text back to the provider for parsing.
package streaming

import (
	"context"
	"strings"

	"cursortab/types"
)

const lineBufferSize = 100

// Result is the accumulated outcome of a finished stream. Text excludes
// prefill: it is exactly what the source emitted (up to stop tokens and line
// limits). Truncated reports whether the text was cut short before the model
// finished — by the transport's token limit, MaxLines, or cancellation.
type Result struct {
	Text      string
	Truncated bool
}

// Source produces raw text chunks, calling emit for each chunk as it arrives.
// It reports whether the transport truncated the output (e.g. a server-side
// token limit), and should return promptly when emit returns false or ctx is
// cancelled.
type Source func(ctx context.Context, emit func(text string) bool) (truncated bool, err error)

// Config declares the per-request behavior of a Stream.
type Config struct {
	Source Source

	// Stop tokens truncate the stream at their first occurrence, even when
	// split across source chunks.
	Stop []string
	// MaxLines stops the stream after this many source lines (0 = no limit).
	MaxLines int
	// Prefill lines are delivered to the consumer before any source text.
	// They are not transformed, validated, or counted against MaxLines, and
	// are excluded from Result.Text.
	Prefill string
	// Transform rewrites each source line; returning false drops the line.
	Transform func(line string) (string, bool)
	// Validate inspects the first delivered source line. An error cancels the
	// stream and is returned from Finish.
	Validate func(line string) error

	// Finish converts the accumulated result into the provider's parse
	// verdict once the stream ends.
	Finish func(Result) (*types.CompletionResponse, error)
}

// Stream runs a Source in a single goroutine and exposes the engine-facing
// stream lifecycle: Lines, Window, Cancel, Finish.
type Stream struct {
	cfg    Config
	lines  chan string
	cancel context.CancelFunc
	done   chan struct{}

	// Written by the run goroutine before done is closed.
	result Result
	err    error
}

// Start begins consuming cfg.Source and returns immediately.
func Start(ctx context.Context, cfg Config) *Stream {
	ctx, cancel := context.WithCancel(ctx)
	s := &Stream{
		cfg:    cfg,
		lines:  make(chan string, lineBufferSize),
		cancel: cancel,
		done:   make(chan struct{}),
	}
	go s.run(ctx)
	return s
}

// Lines returns the channel of delivered lines. It is closed when the stream
// ends for any reason.
func (s *Stream) Lines() <-chan string {
	return s.lines
}

// Cancel stops the source and closes Lines.
func (s *Stream) Cancel() {
	s.cancel()
}

// Finish waits for the stream to end and returns the provider's parse verdict
// for the accumulated text. Transport and validation errors are returned
// without invoking the provider.
func (s *Stream) Finish() (*types.CompletionResponse, error) {
	<-s.done
	if s.err != nil {
		return nil, s.err
	}
	return s.cfg.Finish(s.result)
}

func (s *Stream) run(ctx context.Context) {
	defer close(s.done)
	defer close(s.lines)
	defer s.cancel()

	a := &assembler{cfg: &s.cfg, ctx: ctx, out: s.lines}

	if !a.sendPrefill() {
		s.result = Result{Truncated: true}
		return
	}

	truncated, err := s.cfg.Source(ctx, a.consume)
	s.result, s.err = a.finalize(truncated, err)
}

type haltReason int

const (
	haltNone haltReason = iota
	haltStop
	haltMaxLines
	haltValidate
	haltCancelled
)

// assembler turns raw source chunks into delivered lines. It owns all
// line-level stream behavior: stop-token scanning across chunk boundaries,
// line limits, transforms, and first-line validation.
type assembler struct {
	cfg *Config
	ctx context.Context
	out chan<- string

	text      strings.Builder // all committed source text
	lineBuf   strings.Builder // current partial line
	pending   string          // holdback for stop tokens split across chunks
	lineCount int
	validated bool
	halt      haltReason
	err       error // validation error
}

func (a *assembler) sendPrefill() bool {
	if a.cfg.Prefill == "" {
		return true
	}
	for _, line := range strings.Split(strings.TrimSuffix(a.cfg.Prefill, "\n"), "\n") {
		if !a.send(line) {
			return false
		}
	}
	return true
}

// consume ingests one source chunk. It returns false once the stream should
// stop (stop token, line limit, validation failure, or cancellation).
func (a *assembler) consume(chunk string) bool {
	a.pending += chunk

	if idx, ok := a.findStop(a.pending); ok {
		a.commit(a.pending[:idx])
		a.pending = ""
		if a.halt == haltNone {
			a.halt = haltStop
		}
		return false
	}

	// Hold back enough bytes to catch a stop token split across chunks.
	commitLen := len(a.pending) - a.holdback()
	if commitLen > 0 {
		a.commit(a.pending[:commitLen])
		a.pending = a.pending[commitLen:]
	}
	return a.halt == haltNone
}

// finalize settles the stream outcome after the source returns.
func (a *assembler) finalize(truncated bool, err error) (Result, error) {
	if a.halt == haltNone {
		if a.ctx.Err() != nil {
			a.halt = haltCancelled
		} else if err != nil {
			return a.result(true), err
		} else if a.pending != "" {
			// Natural end of stream: settle the holdback.
			if idx, ok := a.findStop(a.pending); ok {
				a.commit(a.pending[:idx])
				if a.halt == haltNone {
					a.halt = haltStop
				}
			} else {
				a.commit(a.pending)
			}
			a.pending = ""
		}
	}

	// Deliver the trailing partial line unless the stream was cut short.
	if a.halt == haltNone || a.halt == haltStop {
		a.flushLine()
	}

	switch a.halt {
	case haltValidate:
		return a.result(true), a.err
	case haltMaxLines, haltCancelled:
		return a.result(true), nil
	case haltStop:
		return a.result(false), nil
	}
	return a.result(truncated), nil
}

func (a *assembler) result(truncated bool) Result {
	return Result{Text: a.text.String(), Truncated: truncated}
}

// commit accumulates text and delivers each completed line.
func (a *assembler) commit(text string) {
	for _, ch := range text {
		if a.halt != haltNone {
			return
		}
		a.text.WriteRune(ch)
		if ch != '\n' {
			a.lineBuf.WriteRune(ch)
			continue
		}
		a.completeLine()
	}
}

func (a *assembler) completeLine() {
	line := a.lineBuf.String()
	a.lineBuf.Reset()
	a.lineCount++
	if !a.deliver(line) {
		return
	}
	if a.cfg.MaxLines > 0 && a.lineCount >= a.cfg.MaxLines {
		a.halt = haltMaxLines
	}
}

// flushLine delivers the trailing partial line at the end of a stream.
func (a *assembler) flushLine() {
	if a.lineBuf.Len() == 0 {
		return
	}
	line := a.lineBuf.String()
	a.lineBuf.Reset()
	a.deliver(line)
}

// deliver applies the transform and first-line validation, then sends the
// line to the consumer.
func (a *assembler) deliver(rawLine string) bool {
	line := rawLine
	if a.cfg.Transform != nil {
		var emit bool
		if line, emit = a.cfg.Transform(rawLine); !emit {
			return true
		}
	}
	if a.cfg.Validate != nil && !a.validated {
		if err := a.cfg.Validate(line); err != nil {
			a.err = err
			a.halt = haltValidate
			return false
		}
		a.validated = true
	}
	return a.send(line)
}

func (a *assembler) send(line string) bool {
	select {
	case a.out <- line:
		return true
	case <-a.ctx.Done():
		a.halt = haltCancelled
		return false
	}
}

func (a *assembler) findStop(text string) (int, bool) {
	stopIdx := -1
	for _, token := range a.cfg.Stop {
		if token == "" {
			continue
		}
		idx := strings.Index(text, token)
		if idx != -1 && (stopIdx == -1 || idx < stopIdx) {
			stopIdx = idx
		}
	}
	return stopIdx, stopIdx != -1
}

func (a *assembler) holdback() int {
	longest := 0
	for _, token := range a.cfg.Stop {
		if len(token) > longest {
			longest = len(token)
		}
	}
	if longest == 0 {
		return 0
	}
	return longest - 1
}
