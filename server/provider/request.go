package provider

import (
	sourcectx "cursortab/ctx"
	"cursortab/types"
	"cursortab/utils"
)

// RequestWindow is the source window shared by Build, Parse, and streaming.
type RequestWindow struct {
	Lines      []string
	Start      int
	CursorLine int
	MaxLines   int
}

// RequestState is the shared fact source for one provider call.
type RequestState struct {
	Input  sourcectx.CompletionInput
	Window RequestWindow
}

// prepareRequestState derives the source frame shared by Build, Parse, and
// stream windowing.
func prepareRequestState(input sourcectx.CompletionInput, config *types.ProviderConfig) *RequestState {
	current := input.Current
	state := &RequestState{Input: input}
	cursorLine := current.Cursor.Row - 1
	var syntaxRanges []*types.LineRange
	if material, ok := sourcectx.Find[sourcectx.Treesitter](input.Materials); ok && material.Data != nil {
		syntaxRanges = material.Data.SyntaxRanges
	}
	contextSize := 0
	if config != nil {
		contextSize = config.ProviderContextSize
		if contextSize == 0 {
			contextSize = config.ProviderMaxTokens
		}
	}
	trimmedLines, newCursorLine, _, trimOffset, didTrim := utils.TrimContentAroundCursor(
		current.File.Lines,
		cursorLine,
		current.Cursor.Col,
		contextSize,
		syntaxRanges,
	)
	state.Window.Lines = trimmedLines
	state.Window.CursorLine = newCursorLine
	state.Window.Start = trimOffset

	if didTrim {
		state.Window.MaxLines = len(trimmedLines)
	}
	if current.ViewportHeight > 0 {
		if state.Window.MaxLines == 0 || current.ViewportHeight < state.Window.MaxLines {
			state.Window.MaxLines = current.ViewportHeight
		}
	}

	return state
}
