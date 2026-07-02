// Package policy makes context assembly data-driven. A Genome is a small
// program describing which context materials a completion request collects,
// in what order, and with what limits. Genomes are persisted per user and can
// be evolved from completion outcomes (accept, reject, ignore).
package policy

import "cursortab/ctx"

// MaterialName identifies a context material in genome data.
type MaterialName string

const (
	MaterialDiagnostics MaterialName = "diagnostics"
	MaterialTreesitter  MaterialName = "treesitter"
	MaterialGitDiff     MaterialName = "git_diff"
	MaterialTabMd       MaterialName = "tab_md"
	MaterialRecentFiles MaterialName = "recent_files"
	MaterialEditHistory MaterialName = "edit_history"
	MaterialUserActions MaterialName = "user_actions"
)

// Limit parameter names understood by genes. Each maps to one
// ctx.CollectionLimits field.
const (
	ParamMaxSiblings        = "max_siblings"
	ParamMaxDiffBytes       = "max_diff_bytes"
	ParamMaxChangedSymbols  = "max_changed_symbols"
	ParamMaxRecentSnapshots = "max_recent_snapshots"
	ParamMaxDiffTokens      = "max_diff_tokens"
	ParamMaxUserActions     = "max_user_actions"
)

// Gene is one instruction in the genome program: include (or skip) a material,
// optionally overriding its collection limits. Params absent from the map
// inherit the engine's base limits.
type Gene struct {
	Material MaterialName   `json:"material"`
	Enabled  bool           `json:"enabled"`
	Params   map[string]int `json:"params,omitempty"`
}

// Genome is an ordered gene sequence. Order is the collection order.
type Genome struct {
	Genes []Gene `json:"genes"`
}

// DefaultGenome includes every material with no limit overrides, reproducing
// the engine's built-in collection behavior exactly.
func DefaultGenome() Genome {
	return Genome{Genes: []Gene{
		{Material: MaterialDiagnostics, Enabled: true},
		{Material: MaterialTreesitter, Enabled: true},
		{Material: MaterialGitDiff, Enabled: true},
		{Material: MaterialTabMd, Enabled: true},
		{Material: MaterialRecentFiles, Enabled: true},
		{Material: MaterialEditHistory, Enabled: true},
		{Material: MaterialUserActions, Enabled: true},
	}}
}

// Plan expresses the genome against the materials a provider supports and the
// engine's base limits. Genes for unsupported materials are skipped, disabled
// genes drop their material, and gene params override the matching limits.
// Supported materials the genome cannot express (unknown to this package) are
// appended so new upstream materials are never silently dropped.
func (g Genome) Plan(supported ctx.Materials, base ctx.CollectionLimits) (ctx.Materials, ctx.CollectionLimits) {
	limits := base
	planned := make(ctx.Materials, 0, len(supported))
	used := make([]bool, len(supported))

	for _, gene := range g.Genes {
		idx := findMaterial(supported, used, gene.Material)
		if idx < 0 {
			continue
		}
		used[idx] = true
		if !gene.Enabled {
			continue
		}
		planned = append(planned, supported[idx])
		for name, value := range gene.Params {
			applyParam(&limits, name, value)
		}
	}

	for i := range supported {
		if used[i] {
			continue
		}
		if _, known := materialNameOf(supported[i]); known {
			continue
		}
		planned = append(planned, supported[i])
	}

	return planned, limits
}

// findMaterial returns the index of the first unused supported material with
// the given name, or -1.
func findMaterial(supported ctx.Materials, used []bool, name MaterialName) int {
	for i := range supported {
		if used[i] {
			continue
		}
		if n, ok := materialNameOf(supported[i]); ok && n == name {
			return i
		}
	}
	return -1
}

func materialNameOf(m any) (MaterialName, bool) {
	switch m.(type) {
	case ctx.Diagnostics:
		return MaterialDiagnostics, true
	case ctx.Treesitter:
		return MaterialTreesitter, true
	case ctx.GitDiff:
		return MaterialGitDiff, true
	case ctx.TabMd:
		return MaterialTabMd, true
	case ctx.RecentFiles:
		return MaterialRecentFiles, true
	case ctx.EditHistory:
		return MaterialEditHistory, true
	case ctx.UserActions:
		return MaterialUserActions, true
	}
	return "", false
}

func applyParam(limits *ctx.CollectionLimits, name string, value int) {
	switch name {
	case ParamMaxSiblings:
		limits.MaxSiblings = value
	case ParamMaxDiffBytes:
		limits.MaxDiffBytes = value
	case ParamMaxChangedSymbols:
		limits.MaxChangedSymbols = value
	case ParamMaxRecentSnapshots:
		limits.MaxRecentSnapshots = value
	case ParamMaxDiffTokens:
		limits.MaxDiffTokens = value
	case ParamMaxUserActions:
		limits.MaxUserActions = value
	}
}

// clone returns a deep copy safe to mutate independently.
func (g Genome) clone() Genome {
	genes := make([]Gene, len(g.Genes))
	for i, gene := range g.Genes {
		genes[i] = gene
		if gene.Params != nil {
			params := make(map[string]int, len(gene.Params))
			for k, v := range gene.Params {
				params[k] = v
			}
			genes[i].Params = params
		}
	}
	return Genome{Genes: genes}
}

func (g Genome) equal(other Genome) bool {
	if len(g.Genes) != len(other.Genes) {
		return false
	}
	for i, gene := range g.Genes {
		o := other.Genes[i]
		if gene.Material != o.Material || gene.Enabled != o.Enabled || len(gene.Params) != len(o.Params) {
			return false
		}
		for k, v := range gene.Params {
			ov, ok := o.Params[k]
			if !ok || ov != v {
				return false
			}
		}
	}
	return true
}
