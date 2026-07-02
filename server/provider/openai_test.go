package provider

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"cursortab/assert"
	"cursortab/client/openai"
	sourcectx "cursortab/ctx"
	"cursortab/engine"
	"cursortab/types"
)

// fakeStreamFlow is a minimal OpenAIStreamFlow leaf for exercising the full
// StartStream stack: Build -> HTTP SSE -> streaming -> Finish -> Parse.
type fakeStreamFlow struct {
	openAI     OpenAI
	streamArgs OpenAIStreamArgs
	parsed     *openai.CompletionResult
	response   *types.CompletionResponse
}

func (f *fakeStreamFlow) Build(state *RequestState) (*openai.CompletionRequest, error) {
	return f.openAI.Request("prompt", nil), nil
}

func (f *fakeStreamFlow) Call(ctx context.Context, req *openai.CompletionRequest) (*openai.CompletionResult, error) {
	return nil, errors.New("batch call not expected in stream test")
}

func (f *fakeStreamFlow) Parse(state *RequestState, result *openai.CompletionResult) (*types.CompletionResponse, error) {
	f.parsed = result
	return f.response, nil
}

func (f *fakeStreamFlow) StreamArgs(state *RequestState) OpenAIStreamArgs {
	return f.streamArgs
}

func sseCompletionServer(t *testing.T, texts ...string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		assert.True(t, ok, "ResponseWriter should support Flusher")
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		for _, text := range texts {
			escaped := strings.ReplaceAll(text, "\n", `\n`)
			w.Write([]byte(`data: {"id":"1","choices":[{"text":"` + escaped + `","index":0}]}` + "\n\n"))
			flusher.Flush()
		}
		w.Write([]byte("data: [DONE]\n\n"))
		flusher.Flush()
	}))
}

func streamInput(lines []string) sourcectx.CompletionInput {
	return sourcectx.CompletionInput{
		Current: sourcectx.CurrentSnapshot{
			File:   sourcectx.FileSnapshot{Path: "main.go", Lines: lines},
			Cursor: sourcectx.CursorPosition{Row: 1, Col: 0},
		},
	}
}

func TestStartStream_DeliversLinesAndParsesAccumulatedText(t *testing.T) {
	server := sseCompletionServer(t, "alpha\nbe", "ta\n")
	defer server.Close()

	config := &types.ProviderConfig{ProviderURL: server.URL, ProviderModel: "m"}
	oldLines := []string{"old alpha", "old beta"}
	flow := &fakeStreamFlow{
		openAI:     NewOpenAI("test", config),
		streamArgs: OpenAIStreamArgs{Window: engine.Window{Start: 3, OldLines: oldLines}},
		response: &types.CompletionResponse{
			Completion: &types.Completion{StartLine: 4, EndLineInc: 5, Lines: []string{"alpha", "beta"}},
		},
	}

	stream, window, err := flow.openAI.StartStream(context.Background(), streamInput(oldLines), config, flow)
	assert.NoError(t, err, "StartStream")

	var lines []string
	for line := range stream.Lines() {
		lines = append(lines, line)
	}
	assert.Equal(t, []string{"alpha", "beta"}, lines, "streamed lines")

	assert.Equal(t, engine.Window{Start: 3, OldLines: oldLines}, window, "stream window")

	resp, err := stream.Finish()
	assert.NoError(t, err, "Finish")
	assert.Equal(t, flow.response, resp, "Finish returns the leaf parse verdict")
	assert.Equal(t, "alpha\nbeta\n", flow.parsed.Text, "Parse sees the accumulated text")
}

func TestStartStream_AppliesPrefillAndTransform(t *testing.T) {
	server := sseCompletionServer(t, "<|marker|>\ngenerated\n")
	defer server.Close()

	config := &types.ProviderConfig{ProviderURL: server.URL, ProviderModel: "m"}
	flow := &fakeStreamFlow{
		openAI: NewOpenAI("test", config),
		streamArgs: OpenAIStreamArgs{
			Prefill: "prefilled\n",
			LineTransform: func(line string) (string, bool) {
				if strings.Contains(line, "<|marker|>") {
					return "", false
				}
				return line, true
			},
		},
		response: &types.CompletionResponse{},
	}

	stream, _, err := flow.openAI.StartStream(context.Background(), streamInput([]string{"x"}), config, flow)
	assert.NoError(t, err, "StartStream")

	var lines []string
	for line := range stream.Lines() {
		lines = append(lines, line)
	}
	assert.Equal(t, []string{"prefilled", "generated"}, lines, "prefill first, marker line dropped")

	_, err = stream.Finish()
	assert.NoError(t, err, "Finish")
	assert.Equal(t, "<|marker|>\ngenerated\n", flow.parsed.Text, "Parse sees raw source text including dropped lines")
}

func TestStartStream_TransportErrorSurfacesFromFinish(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer server.Close()

	config := &types.ProviderConfig{ProviderURL: server.URL, ProviderModel: "m"}
	flow := &fakeStreamFlow{
		openAI:   NewOpenAI("test", config),
		response: &types.CompletionResponse{},
	}

	stream, _, err := flow.openAI.StartStream(context.Background(), streamInput([]string{"x"}), config, flow)
	assert.NoError(t, err, "StartStream")

	for range stream.Lines() {
		t.Fatal("no lines expected on transport error")
	}
	_, err = stream.Finish()
	assert.Error(t, err, "Finish surfaces the transport error")
	assert.Nil(t, flow.parsed, "Parse must not run on transport error")
}
