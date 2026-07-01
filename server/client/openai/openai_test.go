package openai

import (
	"context"
	"cursortab/assert"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestDoCompletion_Success(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "POST", r.Method, "HTTP method")
		assert.Equal(t, "application/json", r.Header.Get("Content-Type"), "Content-Type header")

		body, _ := io.ReadAll(r.Body)
		var req CompletionRequest
		json.Unmarshal(body, &req)

		assert.False(t, req.Stream, "Stream should be false")

		resp := CompletionResponse{
			ID:    "test-id",
			Model: req.Model,
			Choices: []struct {
				Index        int    `json:"index"`
				Text         string `json:"text"`
				Logprobs     any    `json:"logprobs"`
				FinishReason string `json:"finish_reason"`
			}{
				{Index: 0, Text: "completion text", FinishReason: "stop"},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	ctx := context.Background()

	resp, err := client.DoCompletion(ctx, &CompletionRequest{
		Model:  "test-model",
		Prompt: "hello",
	})

	assert.NoError(t, err, "DoCompletion")
	assert.Equal(t, "test-id", resp.ID, "ID")
	assert.Equal(t, 1, len(resp.Choices), "Choices length")
	assert.Equal(t, "completion text", resp.Choices[0].Text, "Text")
}

func TestDoCompletion_DoesNotMutateRequestStream(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := CompletionResponse{
			Choices: []struct {
				Index        int    `json:"index"`
				Text         string `json:"text"`
				Logprobs     any    `json:"logprobs"`
				FinishReason string `json:"finish_reason"`
			}{{Index: 0, Text: "completion text", FinishReason: "stop"}},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	req := &CompletionRequest{Model: "test-model", Prompt: "hello", Stream: true}

	_, err := client.DoCompletion(context.Background(), req)

	assert.NoError(t, err, "DoCompletion")
	assert.True(t, req.Stream, "caller request stream flag should stay unchanged")
}

func TestDoCompletion_HTTPError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("server error"))
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	ctx := context.Background()

	_, err := client.DoCompletion(ctx, &CompletionRequest{
		Model:  "test-model",
		Prompt: "hello",
	})

	assert.Error(t, err, "Expected error for HTTP 500")
	assert.True(t, strings.Contains(err.Error(), "500"), "Error should mention status code")
}

func TestDoCompletion_InvalidJSON(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("not json"))
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	ctx := context.Background()

	_, err := client.DoCompletion(ctx, &CompletionRequest{
		Model:  "test-model",
		Prompt: "hello",
	})

	assert.Error(t, err, "Expected error for invalid JSON")
}

func TestDoCompletion_WithAPIKey(t *testing.T) {
	var capturedAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedAuth = r.Header.Get("Authorization")
		resp := CompletionResponse{
			ID: "test-id",
			Choices: []struct {
				Index        int    `json:"index"`
				Text         string `json:"text"`
				Logprobs     any    `json:"logprobs"`
				FinishReason string `json:"finish_reason"`
			}{
				{Index: 0, Text: "completion", FinishReason: "stop"},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "sk-test-api-key")
	ctx := context.Background()

	_, err := client.DoCompletion(ctx, &CompletionRequest{
		Model:  "test-model",
		Prompt: "hello",
	})

	assert.NoError(t, err, "DoCompletion")
	assert.Equal(t, "Bearer sk-test-api-key", capturedAuth, "Authorization header")
}

func TestDoCompletion_WithoutAPIKey(t *testing.T) {
	var hasAuthHeader bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hasAuthHeader = r.Header.Get("Authorization") != ""
		resp := CompletionResponse{
			ID: "test-id",
			Choices: []struct {
				Index        int    `json:"index"`
				Text         string `json:"text"`
				Logprobs     any    `json:"logprobs"`
				FinishReason string `json:"finish_reason"`
			}{
				{Index: 0, Text: "completion", FinishReason: "stop"},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	ctx := context.Background()

	_, err := client.DoCompletion(ctx, &CompletionRequest{
		Model:  "test-model",
		Prompt: "hello",
	})

	assert.NoError(t, err, "DoCompletion")
	assert.False(t, hasAuthHeader, "Authorization header should not be set")
}

// sseServer returns an httptest server that writes the given SSE payload
// lines verbatim, flushing after each.
func sseServer(t *testing.T, payload ...string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, ok := w.(http.Flusher)
		assert.True(t, ok, "ResponseWriter should support Flusher")
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		for _, line := range payload {
			w.Write([]byte(line + "\n\n"))
			flusher.Flush()
		}
	}))
}

func collectChunks(t *testing.T, client *Client, req *CompletionRequest) ([]string, string, error) {
	t.Helper()
	var chunks []string
	finishReason, err := client.StreamCompletion(context.Background(), req, func(text string) bool {
		chunks = append(chunks, text)
		return true
	})
	return chunks, finishReason, err
}

func TestStreamCompletion_EmitsChunks(t *testing.T) {
	server := sseServer(t,
		`data: {"id":"1","choices":[{"text":"line 1\n","index":0}]}`,
		`data: {"id":"2","choices":[{"text":"line 2\n","index":0}]}`,
		`data: [DONE]`,
	)
	defer server.Close()

	client := NewClient(server.URL, "", "")
	chunks, _, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.NoError(t, err, "stream error")
	assert.Equal(t, []string{"line 1\n", "line 2\n"}, chunks, "chunks")
}

func TestStreamCompletion_SetsStreamHeaders(t *testing.T) {
	var accept string
	var reqBody []byte
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		accept = r.Header.Get("Accept")
		reqBody, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	_, _, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.NoError(t, err, "stream error")
	assert.Equal(t, "text/event-stream", accept, "Accept header")

	var sent CompletionRequest
	assert.NoError(t, json.Unmarshal(reqBody, &sent), "request body")
	assert.True(t, sent.Stream, "stream flag on the wire")
}

func TestStreamCompletion_CapturesFinishReason(t *testing.T) {
	server := sseServer(t,
		`data: {"id":"1","choices":[{"text":"done\n","index":0,"finish_reason":"stop"}]}`,
		`data: [DONE]`,
	)
	defer server.Close()

	client := NewClient(server.URL, "", "")
	_, finishReason, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.NoError(t, err, "stream error")
	assert.Equal(t, "stop", finishReason, "finish reason")
}

func TestStreamCompletion_EmitFalseStopsStream(t *testing.T) {
	server := sseServer(t,
		`data: {"id":"1","choices":[{"text":"first","index":0}]}`,
		`data: {"id":"2","choices":[{"text":"second","index":0}]}`,
		`data: [DONE]`,
	)
	defer server.Close()

	client := NewClient(server.URL, "", "")
	var chunks []string
	_, err := client.StreamCompletion(context.Background(), &CompletionRequest{Model: "test-model", Prompt: "hello"}, func(text string) bool {
		chunks = append(chunks, text)
		return false
	})

	assert.NoError(t, err, "stream error")
	assert.Equal(t, []string{"first"}, chunks, "stream stops after emit returns false")
}

func TestStreamCompletion_DoesNotMutateRequestStream(t *testing.T) {
	server := sseServer(t,
		`data: {"id":"1","choices":[{"text":"line\n","index":0}]}`,
		`data: [DONE]`,
	)
	defer server.Close()

	client := NewClient(server.URL, "", "")
	req := &CompletionRequest{Model: "test-model", Prompt: "hello", Stream: false}
	_, _, err := collectChunks(t, client, req)

	assert.NoError(t, err, "stream error")
	assert.False(t, req.Stream, "caller request stream flag should stay unchanged")
}

func TestStreamCompletion_HTTPError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		w.Write([]byte("error"))
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "")
	chunks, _, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.Error(t, err, "stream HTTP error should be returned")
	assert.Equal(t, 0, len(chunks), "no chunks on HTTP error")
}

func TestStreamCompletion_ReturnsInvalidJSONError(t *testing.T) {
	server := sseServer(t,
		"data: not json",
		`data: {"id":"1","choices":[{"text":"valid\n","index":0}]}`,
		`data: [DONE]`,
	)
	defer server.Close()

	client := NewClient(server.URL, "", "")
	chunks, _, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.Error(t, err, "invalid JSON error")
	assert.Equal(t, 0, len(chunks), "no chunks after JSON error")
}

func TestStreamCompletion_SkipsComments(t *testing.T) {
	server := sseServer(t,
		": this is a comment",
		`data: {"id":"1","choices":[{"text":"text\n","index":0}]}`,
		`data: [DONE]`,
	)
	defer server.Close()

	client := NewClient(server.URL, "", "")
	chunks, _, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.NoError(t, err, "stream error")
	assert.Equal(t, []string{"text\n"}, chunks, "chunks (comments skipped)")
}

func TestStreamCompletion_ContextCancelStopsStream(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		flusher, _ := w.(http.Flusher)
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("data: {\"id\":\"1\",\"choices\":[{\"text\":\"x\",\"index\":0}]}\n\n"))
		flusher.Flush()
		close(started)
		<-release
	}))
	defer server.Close()
	defer close(release)

	ctx, cancel := context.WithCancel(context.Background())
	client := NewClient(server.URL, "", "")

	done := make(chan error, 1)
	go func() {
		_, err := client.StreamCompletion(ctx, &CompletionRequest{Model: "test-model", Prompt: "hello"}, func(string) bool { return true })
		done <- err
	}()

	<-started
	cancel()

	select {
	case err := <-done:
		if err != nil {
			assert.True(t, ctx.Err() != nil, "only cancellation errors expected")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("StreamCompletion did not return after cancel")
	}
}

func TestStreamCompletion_WithAPIKey(t *testing.T) {
	var capturedAuth string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		capturedAuth = r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer server.Close()

	client := NewClient(server.URL, "", "sk-line-stream-key")
	_, _, err := collectChunks(t, client, &CompletionRequest{Model: "test-model", Prompt: "hello"})

	assert.NoError(t, err, "stream error")
	assert.Equal(t, "Bearer sk-line-stream-key", capturedAuth, "Authorization header")
}
