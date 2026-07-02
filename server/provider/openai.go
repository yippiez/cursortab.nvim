package provider

import (
	"context"
	"fmt"
	"net/http"

	"cursortab/client/openai"
	sourcectx "cursortab/ctx"
	"cursortab/engine"
	"cursortab/logger"
	"cursortab/streaming"
	"cursortab/types"
)

// OpenAI supplies the Call stage for providers that use the OpenAI completions
// API. Leaf providers embed it, build their own prompt in Build, and parse the
// resulting openai.CompletionResult in Parse.
type OpenAI struct {
	config *types.ProviderConfig
	name   string
	client *openai.Client
}

func NewOpenAI(name string, config *types.ProviderConfig) OpenAI {
	return OpenAI{
		config: config,
		name:   name,
		client: openai.NewClient(config.ProviderURL, config.CompletionPath, config.APIKey),
	}
}

func (o OpenAI) ProviderConfig() *types.ProviderConfig {
	return o.config
}

// Call maps one OpenAI completion response to the RawResult used by OpenAI
// based CompletionFlow implementations.
func (o OpenAI) Call(ctx context.Context, req *openai.CompletionRequest) (*openai.CompletionResult, error) {
	resp, err := o.client.DoCompletion(ctx, req)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", o.name, err)
	}

	result := &openai.CompletionResult{}
	if len(resp.Choices) > 0 {
		result = &openai.CompletionResult{
			Text:      resp.Choices[0].Text,
			Truncated: resp.Choices[0].FinishReason == "length",
		}
	}
	logOpenAIResponse(o.name, result)
	return result, nil
}

// SetHTTPTransport is used by eval cassette record/replay.
func (o OpenAI) SetHTTPTransport(rt http.RoundTripper) {
	o.client.SetHTTPTransport(rt)
}

func (o OpenAI) LogRequest(req *openai.CompletionRequest, maxLines int) {
	logger.Debug("%s provider request:\n  URL: %s%s\n  Model: %s\n  Temperature: %.2f\n  MaxTokens: %d\n  MaxLines: %d\n  Prompt length: %d chars\n  Prompt:\n%s",
		o.name,
		o.config.ProviderURL,
		o.config.CompletionPath,
		req.Model,
		req.Temperature,
		req.MaxTokens,
		maxLines,
		len(req.Prompt),
		req.Prompt)
}

// Request fills the config-derived OpenAI fields shared by every OpenAI leaf.
// Prompt, suffix, and stop tokens remain leaf protocol facts.
func (o OpenAI) Request(prompt string, stop []string) *openai.CompletionRequest {
	return &openai.CompletionRequest{
		Model:       o.config.ProviderModel,
		Prompt:      prompt,
		Temperature: o.config.ProviderTemperature,
		MaxTokens:   o.config.ProviderMaxTokens,
		TopK:        o.config.ProviderTopK,
		Stop:        stop,
		N:           1,
		Echo:        false,
	}
}

func logOpenAIResponse(name string, result *openai.CompletionResult) {
	logger.Debug("%s provider response:\n  Text length: %d chars\n  Truncated: %v\n  Text:\n%s",
		name,
		len(result.Text),
		result.Truncated,
		result.Text)
}

// OpenAIStreamArgs is the leaf-selected stream behavior for one built request.
// Sweep uses prefill and first-line validation. Zeta uses first-line
// validation. Zeta2 uses a cursor-marker line transform and its own stream
// window. Engine sees only the CompletionStream returned by StartStream.
type OpenAIStreamArgs struct {
	Window             engine.Window
	Prefill            string
	FirstLineValidator func(string) error
	LineTransform      func(string) (string, bool)
}

type OpenAIStreamFlow interface {
	CompletionFlow[*openai.CompletionRequest, *openai.CompletionResult]
	StreamArgs(*RequestState) OpenAIStreamArgs
}

// StartStream builds the leaf request and runs it through a streaming.Stream,
// which owns the line-level runtime. The leaf's Parse runs in Finish on the
// accumulated text, exactly as in the batch path.
func (o OpenAI) StartStream(ctx context.Context, input sourcectx.CompletionInput, config *types.ProviderConfig, flow OpenAIStreamFlow) (engine.CompletionStream, engine.Window, error) {
	state := prepareRequestState(input, config)
	req, err := flow.Build(state)
	if err != nil {
		return nil, engine.Window{}, err
	}
	args := flow.StreamArgs(state)

	stream := streaming.Start(ctx, streaming.Config{
		Source: func(ctx context.Context, emit func(string) bool) (bool, error) {
			return o.client.StreamCompletion(ctx, req, emit)
		},
		Stop:      req.Stop,
		MaxLines:  state.Window.MaxLines,
		Prefill:   args.Prefill,
		Transform: args.LineTransform,
		Validate:  args.FirstLineValidator,
		Finish: func(r streaming.Result) (*types.CompletionResponse, error) {
			result := &openai.CompletionResult{
				Text:      r.Text,
				Truncated: r.Truncated,
			}
			logOpenAIResponse(o.name, result)
			return flow.Parse(state, result)
		},
	})
	return stream, args.Window, nil
}
