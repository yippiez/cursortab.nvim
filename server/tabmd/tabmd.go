// Package tabmd reads an optional project-level TAB.md doc to inject into the
// completion prompt as static context, so the model knows project conventions
// (custom CLIs, helper functions, naming rules) that aren't visible in nearby
// files.
//
// It is collected as a context material (ctx.TabMd) and injected by the sweep
// prompt builder (as a context/docs section) and the fim repo-level block (as
// a TAB.md pseudo-file).
package tabmd

import (
	"os"
	"path/filepath"
	"strings"
)

// DocName is the project doc filename looked up at the workspace root.
const DocName = "TAB.md"

// MaxBytes caps how much of TAB.md is injected, to bound prompt size.
const MaxBytes = 4096

// Read returns the contents of <workspacePath>/TAB.md (trimmed and capped to
// MaxBytes), or "" if it is absent or empty. workspacePath is the editor cwd
// the daemon already receives on every completion request.
func Read(workspacePath string) string {
	if workspacePath == "" {
		return ""
	}
	b, err := os.ReadFile(filepath.Join(workspacePath, DocName))
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(b))
	if len(s) > MaxBytes {
		s = s[:MaxBytes]
	}
	return s
}
