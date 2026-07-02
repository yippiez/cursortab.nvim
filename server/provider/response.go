package provider

import (
	"strings"

	"cursortab/types"
)

func EmptyResponse() *types.CompletionResponse {
	return &types.CompletionResponse{}
}

// BuildCompletion applies the provider's parsed replacement unless it is a
// no-op against the current buffer lines.
func BuildCompletion(state *RequestState, startLine, endLineInc int, lines []string) *types.CompletionResponse {
	currentLines := state.Input.Current.File.Lines
	if endLineInc <= len(currentLines) && isNoOpReplacement(lines, currentLines[startLine-1:endLineInc]) {
		return EmptyResponse()
	}

	completion := &types.Completion{
		StartLine:  startLine,
		EndLineInc: endLineInc,
		Lines:      lines,
	}

	return &types.CompletionResponse{
		Completion:   completion,
		CursorTarget: nil,
	}
}

func isNoOpReplacement(newLines, oldLines []string) bool {
	newText := strings.TrimRight(strings.Join(newLines, "\n"), " \t\n\r")
	oldText := strings.TrimRight(strings.Join(oldLines, "\n"), " \t\n\r")
	return newText == oldText
}
