package provider

import (
	"context"

	sourcectx "cursortab/ctx"
	"cursortab/types"
)

// CompletionFlow is the provider-local Build -> Call -> Parse pipeline.
//
// RequestPayload and RawResult are generic because each provider has its own
// protocol shape. OpenAI providers use *openai.CompletionRequest and
// *openai.CompletionResult. Mercury, Windsurf, and Copilot use package-local
// request/result types. The shared runner requires one relation: Build produces
// exactly the value Call accepts, and Call produces exactly the value Parse
// accepts.
type CompletionFlow[RequestPayload any, RawResult any] interface {
	Build(*RequestState) (RequestPayload, error)
	Call(context.Context, RequestPayload) (RawResult, error)
	Parse(*RequestState, RawResult) (*types.CompletionResponse, error)
}

func StartBatch[RequestPayload any, RawResult any](
	reqCtx context.Context,
	input sourcectx.CompletionInput,
	config *types.ProviderConfig,
	flow CompletionFlow[RequestPayload, RawResult],
) (*types.CompletionResponse, error) {
	state := prepareRequestState(input, config)
	payload, err := flow.Build(state)
	if err != nil {
		return nil, err
	}
	raw, err := flow.Call(reqCtx, payload)
	if err != nil {
		return nil, err
	}
	response, err := flow.Parse(state, raw)
	return response, err
}
