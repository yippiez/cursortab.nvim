// Package openai is the transport client for OpenAI-compatible completion
// APIs. It owns request/response wire formats, HTTP calls, and SSE decoding;
// line-level stream behavior lives in cursortab/streaming.
package openai

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"

	"cursortab/logger"
)

// CompletionRequest matches the OpenAI Completion API format
type CompletionRequest struct {
	Model       string   `json:"model"`
	Prompt      string   `json:"prompt"`
	Suffix      string   `json:"suffix,omitempty"`
	Temperature float64  `json:"temperature"`
	MaxTokens   int      `json:"max_tokens"`
	TopK        int      `json:"top_k,omitempty"`
	Stop        []string `json:"stop,omitempty"`
	N           int      `json:"n"`
	Echo        bool     `json:"echo"`
	Stream      bool     `json:"stream"`
}

// CompletionResponse matches the OpenAI Completion API response format
type CompletionResponse struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	Model   string `json:"model"`
	Choices []struct {
		Index        int    `json:"index"`
		Text         string `json:"text"`
		Logprobs     any    `json:"logprobs"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	} `json:"usage"`
}

// StreamChunk represents a single SSE chunk from streaming response
type StreamChunk struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	Model   string `json:"model"`
	Choices []struct {
		Index        int    `json:"index"`
		Text         string `json:"text"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
}

// CompletionResult is the raw text result shared by batch and streaming calls.
type CompletionResult struct {
	Text         string
	FinishReason string
	StoppedEarly bool
}

// DefaultCompletionPath is the default API endpoint path
const DefaultCompletionPath = "/v1/completions"

// Client is a reusable OpenAI-compatible API client
type Client struct {
	HTTPClient     *http.Client
	URL            string
	CompletionPath string
	APIKey         string
}

// NewClient creates a new OpenAI-compatible client
func NewClient(url, completionPath, apiKey string) *Client {
	return &Client{
		HTTPClient:     &http.Client{},
		URL:            url,
		CompletionPath: completionPath,
		APIKey:         apiKey,
	}
}

// SetHTTPTransport replaces the transport used for all outgoing requests.
// Used by the eval harness to intercept calls via a cassette transport.
func (c *Client) SetHTTPTransport(rt http.RoundTripper) {
	if c.HTTPClient == nil {
		c.HTTPClient = &http.Client{}
	}
	c.HTTPClient.Transport = rt
}

// DoCompletion sends a non-streaming completion request
func (c *Client) DoCompletion(ctx context.Context, req *CompletionRequest) (*CompletionResponse, error) {
	defer logger.Trace("openai.DoCompletion")()
	req = completionRequestWithStream(req, false)

	body, err := c.doRequest(ctx, req)
	if err != nil {
		return nil, err
	}

	var resp CompletionResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("failed to decode response: %w", err)
	}

	return &resp, nil
}

// StreamCompletion sends a streaming completion request and invokes emit for
// each text chunk as it arrives. It blocks until the stream ends, emit
// returns false, or ctx is cancelled, and returns the finish reason reported
// by the server.
func (c *Client) StreamCompletion(ctx context.Context, req *CompletionRequest, emit func(text string) bool) (string, error) {
	defer logger.Trace("openai.StreamCompletion")()
	req = completionRequestWithStream(req, true)

	body, err := encodeRequest(req)
	if err != nil {
		return "", fmt.Errorf("marshal stream request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.URL+c.CompletionPath, body)
	if err != nil {
		return "", fmt.Errorf("create stream request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	if c.APIKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTPClient.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("send stream request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("stream request failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	return decodeSSE(ctx, resp.Body, emit)
}

// decodeSSE reads SSE events from body and emits each chunk's text.
func decodeSSE(ctx context.Context, body io.Reader, emit func(string) bool) (string, error) {
	var finishReason string

	scanner := bufio.NewScanner(body)
	for scanner.Scan() {
		if ctx.Err() != nil {
			return finishReason, nil
		}

		line := scanner.Text()

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, ":") {
			continue
		}

		// Check for end of stream
		if line == "data: [DONE]" {
			break
		}

		// Parse SSE data line
		if !strings.HasPrefix(line, "data: ") {
			continue
		}

		jsonData := strings.TrimPrefix(line, "data: ")
		var chunk StreamChunk
		if err := json.Unmarshal([]byte(jsonData), &chunk); err != nil {
			return finishReason, fmt.Errorf("parse stream chunk: %w", err)
		}

		if len(chunk.Choices) == 0 {
			continue
		}
		if chunk.Choices[0].FinishReason != "" {
			finishReason = chunk.Choices[0].FinishReason
		}
		if !emit(chunk.Choices[0].Text) {
			return finishReason, nil
		}
	}

	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		return finishReason, fmt.Errorf("read stream: %w", err)
	}
	return finishReason, nil
}

func completionRequestWithStream(req *CompletionRequest, stream bool) *CompletionRequest {
	cloned := *req
	cloned.Stream = stream
	if req.Stop != nil {
		cloned.Stop = append([]string(nil), req.Stop...)
	}
	return &cloned
}

// encodeRequest marshals a request without HTML escaping.
func encodeRequest(req *CompletionRequest) (*bytes.Buffer, error) {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(req); err != nil {
		return nil, err
	}
	return &buf, nil
}

// doRequest sends an HTTP request and returns the response body
func (c *Client) doRequest(ctx context.Context, req *CompletionRequest) ([]byte, error) {
	body, err := encodeRequest(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	httpReq, err := http.NewRequestWithContext(ctx, "POST", c.URL+c.CompletionPath, body)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	if c.APIKey != "" {
		httpReq.Header.Set("Authorization", "Bearer "+c.APIKey)
	}

	resp, err := c.HTTPClient.Do(httpReq)
	if err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("request failed with status %d: %s", resp.StatusCode, string(respBody))
	}

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	return respBody, nil
}
