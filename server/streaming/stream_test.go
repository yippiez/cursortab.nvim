package streaming

import (
	"context"
	"errors"
	"strings"
	"testing"

	"cursortab/assert"
	"cursortab/types"
)

// chunkSource emits the given chunks in order and ends the stream naturally.
func chunkSource(chunks ...string) Source {
	return func(ctx context.Context, emit func(string) bool) (bool, error) {
		for _, c := range chunks {
			if !emit(c) {
				return false, nil
			}
		}
		return false, nil
	}
}

// start runs a stream that records the Result passed to Finish.
func start(t *testing.T, cfg Config) (*Stream, *Result) {
	t.Helper()
	recorded := &Result{}
	if cfg.Finish == nil {
		cfg.Finish = func(r Result) (*types.CompletionResponse, error) {
			*recorded = r
			return &types.CompletionResponse{}, nil
		}
	}
	return Start(context.Background(), cfg), recorded
}

func drain(s *Stream) []string {
	var lines []string
	for line := range s.Lines() {
		lines = append(lines, line)
	}
	return lines
}

func TestStream_AssemblesLinesAcrossChunks(t *testing.T) {
	s, result := start(t, Config{
		Source: chunkSource("hel", "lo\nwor", "ld\n"),
	})

	assert.Equal(t, []string{"hello", "world"}, drain(s), "lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.Equal(t, "hello\nworld\n", result.Text, "accumulated text")
	assert.False(t, result.Truncated, "truncated")
}

func TestStream_FlushesTrailingPartialLine(t *testing.T) {
	s, result := start(t, Config{
		Source: chunkSource("one\ntwo"),
	})

	assert.Equal(t, []string{"one", "two"}, drain(s), "lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.Equal(t, "one\ntwo", result.Text, "accumulated text")
}

func TestStream_StopToken(t *testing.T) {
	s, result := start(t, Config{
		Source: chunkSource("keep\npartial<|end|>dropped\n"),
		Stop:   []string{"<|end|>"},
	})

	assert.Equal(t, []string{"keep", "partial"}, drain(s), "lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.Equal(t, "keep\npartial", result.Text, "text truncated at stop token")
	assert.False(t, result.Truncated, "a stop token is an intentional end, not truncation")
}

func TestStream_StopTokenSplitAcrossChunks(t *testing.T) {
	s, result := start(t, Config{
		Source: chunkSource("line\n<|e", "nd|>dropped"),
		Stop:   []string{"<|end|>"},
	})

	assert.Equal(t, []string{"line"}, drain(s), "lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.Equal(t, "line\n", result.Text, "text truncated at split stop token")
	assert.False(t, result.Truncated, "truncated")
}

func TestStream_StopTokenInHoldbackAtStreamEnd(t *testing.T) {
	s, result := start(t, Config{
		Source: chunkSource("ab<|end|>"),
		Stop:   []string{"<|end|>"},
	})

	assert.Equal(t, []string{"ab"}, drain(s), "lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.Equal(t, "ab", result.Text, "text truncated at held-back stop token")
	assert.False(t, result.Truncated, "truncated")
}

func TestStream_MaxLines(t *testing.T) {
	s, result := start(t, Config{
		Source:   chunkSource("a\nb\nc\nd\n"),
		MaxLines: 2,
	})

	assert.Equal(t, []string{"a", "b"}, drain(s), "lines capped at MaxLines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.True(t, result.Truncated, "MaxLines cut the stream short")
}

func TestStream_SourceTruncationPropagates(t *testing.T) {
	s, result := start(t, Config{
		Source: func(ctx context.Context, emit func(string) bool) (bool, error) {
			emit("cut off mid\n")
			return true, nil // server hit its token limit
		},
	})

	assert.Equal(t, []string{"cut off mid"}, drain(s), "lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.True(t, result.Truncated, "transport truncation propagates")
}

func TestStream_PrefillDeliveredFirstAndExcludedFromResult(t *testing.T) {
	s, result := start(t, Config{
		Source:   chunkSource("generated\n"),
		Prefill:  "first\nsecond\n",
		MaxLines: 3,
	})

	assert.Equal(t, []string{"first", "second", "generated"}, drain(s), "prefill lines precede source lines")
	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.Equal(t, "generated\n", result.Text, "prefill excluded from result text")
}

func TestStream_PrefillNotCountedAgainstMaxLines(t *testing.T) {
	s, _ := start(t, Config{
		Source:   chunkSource("a\nb\n"),
		Prefill:  "p1\np2\n",
		MaxLines: 2,
	})

	assert.Equal(t, []string{"p1", "p2", "a", "b"}, drain(s), "MaxLines counts only source lines")
}

func TestStream_TransformRewritesAndDropsLines(t *testing.T) {
	s, _ := start(t, Config{
		Source: chunkSource("keep\nDROP\nother\n"),
		Transform: func(line string) (string, bool) {
			if line == "DROP" {
				return "", false
			}
			return strings.ToUpper(line), true
		},
	})

	assert.Equal(t, []string{"KEEP", "OTHER"}, drain(s), "transformed lines")
}

func TestStream_ValidateFailureCancelsAndSurfacesError(t *testing.T) {
	wantErr := errors.New("bad first line")
	s, _ := start(t, Config{
		Source: chunkSource("bad\ngood\n"),
		Validate: func(line string) error {
			if line == "bad" {
				return wantErr
			}
			return nil
		},
	})

	assert.Equal(t, []string(nil), drain(s), "no lines delivered after validation failure")
	_, err := s.Finish()
	assert.Equal(t, wantErr, err, "Finish returns the validation error")
}

func TestStream_ValidateOnlyChecksFirstLine(t *testing.T) {
	calls := 0
	s, _ := start(t, Config{
		Source: chunkSource("first\nsecond\n"),
		Validate: func(line string) error {
			calls++
			return nil
		},
	})

	assert.Equal(t, []string{"first", "second"}, drain(s), "lines")
	assert.Equal(t, 1, calls, "validator runs once")
}

func TestStream_SourceErrorSurfacesFromFinish(t *testing.T) {
	wantErr := errors.New("connection refused")
	s, _ := start(t, Config{
		Source: func(ctx context.Context, emit func(string) bool) (bool, error) {
			return false, wantErr
		},
	})

	assert.Equal(t, []string(nil), drain(s), "no lines on transport error")
	_, err := s.Finish()
	assert.Equal(t, wantErr, err, "Finish returns the transport error")
}

func TestStream_CancelStopsSourceAndClosesLines(t *testing.T) {
	sourceDone := make(chan struct{})
	s, result := start(t, Config{
		Source: func(ctx context.Context, emit func(string) bool) (bool, error) {
			emit("line\n")
			<-ctx.Done()
			close(sourceDone)
			return false, ctx.Err()
		},
	})

	line := <-s.Lines()
	assert.Equal(t, "line", line, "first line")
	s.Cancel()
	<-sourceDone
	drain(s)

	_, err := s.Finish()
	assert.NoError(t, err, "finish")
	assert.True(t, result.Truncated, "cancellation truncates the result")
}
