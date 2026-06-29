package engine

import (
	"testing"

	"cursortab/assert"
	"cursortab/text"
	"cursortab/types"
)

// TestFileChanged_ReanchorsBaseline verifies that when the file is reported as
// changed on disk underneath the editor, the engine re-baselines its per-file
// state to the reloaded content instead of treating the external change as a
// pending user edit.
func TestFileChanged_ReanchorsBaseline(t *testing.T) {
	buf := newMockBuffer()
	// Stale checkpoint from before the external change.
	buf.originalLines = []string{"old 1", "old 2", "old 3"}
	buf.diffHistories = []*types.DiffEntry{{Original: "old 1", Updated: "edited 1", StartLine: 1}}
	// Buffer now holds the freshly reloaded (externally changed) content.
	buf.lines = []string{"new 1", "new 2", "new 3", "new 4"}

	prov := newMockProvider()
	clock := newMockClock()
	eng := createTestEngine(buf, prov, clock)
	eng.lastBufferLines = []string{"old 1", "old 2", "old 3"}

	eng.handleEvent(Event{Type: EventFileChanged})

	assert.Equal(t, 1, buf.clearDiffHistoryCalls, "diff history baseline re-anchored once")
	assert.Equal(t, 0, len(buf.diffHistories), "stale diff history dropped")
	assert.Equal(t, buf.lines, buf.originalLines, "checkpoint re-anchored to reloaded content")
	assert.Equal(t, buf.lines, eng.lastBufferLines, "action-classification baseline re-anchored")
}

// TestFileChanged_DropsDisplayedCompletion verifies that a completion shown
// before an external file change is cleared, since its line numbers and content
// no longer match the reloaded buffer.
func TestFileChanged_DropsDisplayedCompletion(t *testing.T) {
	buf := newMockBuffer()
	buf.lines = []string{"reloaded line 1", "reloaded line 2"}
	prov := newMockProvider()
	clock := newMockClock()
	eng := createTestEngine(buf, prov, clock)

	eng.state = stateHasCompletion
	showDisplayedCompletionForTest(
		eng,
		&types.Completion{StartLine: 1, EndLineInc: 1, Lines: []string{"stale completion"}},
		[]string{"stale original"},
		[]*text.Group{},
	)

	eng.handleEvent(Event{Type: EventFileChanged})

	assert.Equal(t, stateIdle, eng.state, "engine returns to idle after external change")
	assert.False(t, eng.display.hasCompletion(), "stale completion dropped")
	assert.True(t, buf.clearUICalls > 0, "UI cleared")
}

// TestFileChanged_FromIdle verifies the event is handled (re-baselines) even when
// no completion is showing.
func TestFileChanged_FromIdle(t *testing.T) {
	buf := newMockBuffer()
	buf.originalLines = []string{"old"}
	buf.lines = []string{"new"}
	prov := newMockProvider()
	clock := newMockClock()
	eng := createTestEngine(buf, prov, clock)

	eng.handleEvent(Event{Type: EventFileChanged})

	assert.Equal(t, stateIdle, eng.state, "stays idle")
	assert.Equal(t, 1, buf.clearDiffHistoryCalls, "baseline re-anchored from idle")
}
