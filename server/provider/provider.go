// Package provider contains shared execution plumbing for leaf providers.
// Engine reads provider facts, then leaf providers keep protocol-specific
// request construction, transport calls, and response parsing in Build, Call,
// and Parse.
package provider

import (
	sourcectx "cursortab/ctx"
	"cursortab/engine"
)

// Base carries the provider facts engine reads before execution.
type Base struct {
	kind                            engine.CompletionKind
	canPrefetchFromSyntheticCurrent bool
	materials                       sourcectx.Materials
}

// SyntheticPrefetch declares whether an edit provider can consume
// engine-created current snapshots for cursor-target prefetch.
type SyntheticPrefetch bool

const (
	SyntheticPrefetchDisabled SyntheticPrefetch = false
	SyntheticPrefetchEnabled  SyntheticPrefetch = true
)

// NewBase declares a provider whose Build stage uses the supplied
// CompletionInput snapshot as its editor state.
func NewBase(kind engine.CompletionKind, materials sourcectx.Materials, syntheticPrefetch SyntheticPrefetch) Base {
	return Base{
		kind:                            kind,
		canPrefetchFromSyntheticCurrent: kind == engine.CompletionEdit && bool(syntheticPrefetch),
		materials:                       materials,
	}
}

func (b Base) CompletionKind() engine.CompletionKind {
	return b.kind
}

func (b Base) CanPrefetchFromSyntheticCurrent() bool {
	return b.canPrefetchFromSyntheticCurrent
}

func (b Base) RequiredMaterials() sourcectx.Materials {
	return b.materials
}
