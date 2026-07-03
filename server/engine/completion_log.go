package engine

import (
	"cursortab/completionlog"
	"cursortab/logger"
	"cursortab/text"
	"cursortab/types"
)

func (e *Engine) logDisplayedCompletionOutcome(outcome string) {
	if e.config.CompletionLogger == nil || !e.display.hasCompletion() {
		return
	}
	completion := e.display.current()
	if completion == nil {
		return
	}
	e.writeCompletionLog(completionlog.Event{
		Provider: e.config.ProviderName,
		Model:    e.config.ProviderModel,
		File:     e.buffer.Path(),
		Row:      e.buffer.Row(),
		Col:      e.buffer.Col(),
		Trigger:  e.completionTrigger(),
		Outcome:  outcome,
		Proposed: text.JoinLines(completion.Lines),
		Before:   text.JoinLines(e.display.oldLines()),
		After:    text.JoinLines(completion.Lines),
	})
}

func (e *Engine) logSuppressedStage(stage *text.Stage) {
	if e.config.CompletionLogger == nil || stage == nil {
		return
	}
	e.writeCompletionLog(completionlog.Event{
		Provider: e.config.ProviderName,
		Model:    e.config.ProviderModel,
		File:     e.buffer.Path(),
		Row:      e.buffer.Row(),
		Col:      e.buffer.Col(),
		Trigger:  e.completionTrigger(),
		Outcome:  "suppressed",
		Proposed: text.JoinLines(stage.Lines),
		Before:   text.JoinLines(e.displayOriginalLines(stage.BufferStart, stage.BufferEnd)),
		After:    text.JoinLines(stage.Lines),
	})
}

func (e *Engine) writeCompletionLog(event completionlog.Event) {
	if err := e.config.CompletionLogger.Write(event); err != nil {
		logger.Warn("completion log write failed: %v", err)
	}
}

func (e *Engine) completionTrigger() string {
	if e.stagedCompletion != nil && e.stagedCompletion.Manual {
		return "manual"
	}
	switch e.lastCompletionSource {
	case types.CompletionSourceTyping:
		return "typing"
	case types.CompletionSourceIdle:
		return "idle"
	default:
		return "unknown"
	}
}
