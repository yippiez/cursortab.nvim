package policy

import "math/rand/v2"

// paramSpec bounds one mutable limit parameter. Seed is the starting value
// when a gene has no explicit override to nudge from.
type paramSpec struct {
	Material MaterialName
	Name     string
	Min      int
	Max      int
	Seed     int
}

// paramSpecs are the limit parameters evolution may explore, seeded at the
// engine's built-in defaults.
var paramSpecs = []paramSpec{
	{MaterialTreesitter, ParamMaxSiblings, 5, 200, 50},
	{MaterialGitDiff, ParamMaxDiffBytes, 512, 32768, 4096},
	{MaterialGitDiff, ParamMaxChangedSymbols, 5, 200, 50},
	{MaterialRecentFiles, ParamMaxRecentSnapshots, 1, 10, 3},
	{MaterialEditHistory, ParamMaxDiffTokens, 128, 8192, 1024},
	{MaterialUserActions, ParamMaxUserActions, 4, 64, 16},
}

// Mutate returns a copy of the genome with ops random edits applied: toggling
// a gene, nudging a limit parameter, or swapping adjacent genes. The result is
// guaranteed to differ from the input and to keep at least one gene enabled.
func Mutate(g Genome, rng *rand.Rand, ops int) Genome {
	if ops < 1 {
		ops = 1
	}
	for range 4 {
		mutated := g.clone()
		for range ops {
			applyRandomOp(&mutated, rng)
		}
		if !mutated.equal(g) {
			return mutated
		}
	}
	return g.clone()
}

func applyRandomOp(g *Genome, rng *rand.Rand) {
	if len(g.Genes) == 0 {
		return
	}
	switch rng.IntN(3) {
	case 0:
		toggleGene(g, rng)
	case 1:
		if !nudgeParam(g, rng) {
			toggleGene(g, rng)
		}
	case 2:
		swapGenes(g, rng)
	}
}

// toggleGene flips one gene's enabled flag, never disabling the last enabled
// gene.
func toggleGene(g *Genome, rng *rand.Rand) {
	idx := rng.IntN(len(g.Genes))
	gene := &g.Genes[idx]
	if gene.Enabled && enabledCount(*g) == 1 {
		return
	}
	gene.Enabled = !gene.Enabled
}

// nudgeParam halves or doubles one limit parameter of an enabled gene, clamped
// to its spec bounds. Reports false when no enabled gene has mutable params.
func nudgeParam(g *Genome, rng *rand.Rand) bool {
	type candidate struct {
		gene *Gene
		spec paramSpec
	}
	var candidates []candidate
	for i := range g.Genes {
		gene := &g.Genes[i]
		if !gene.Enabled {
			continue
		}
		for _, spec := range paramSpecs {
			if spec.Material == gene.Material {
				candidates = append(candidates, candidate{gene, spec})
			}
		}
	}
	if len(candidates) == 0 {
		return false
	}

	c := candidates[rng.IntN(len(candidates))]
	current, ok := c.gene.Params[c.spec.Name]
	if !ok || current <= 0 {
		current = c.spec.Seed
	}

	next := current * 2
	if rng.IntN(2) == 0 {
		next = current / 2
	}
	next = min(max(next, c.spec.Min), c.spec.Max)
	if next == current {
		// Clamped into place; step the other way instead.
		if next == c.spec.Min {
			next = min(current*2, c.spec.Max)
		} else {
			next = max(current/2, c.spec.Min)
		}
	}

	if c.gene.Params == nil {
		c.gene.Params = make(map[string]int)
	}
	c.gene.Params[c.spec.Name] = next
	return true
}

func swapGenes(g *Genome, rng *rand.Rand) {
	if len(g.Genes) < 2 {
		return
	}
	i := rng.IntN(len(g.Genes) - 1)
	g.Genes[i], g.Genes[i+1] = g.Genes[i+1], g.Genes[i]
}

func enabledCount(g Genome) int {
	count := 0
	for _, gene := range g.Genes {
		if gene.Enabled {
			count++
		}
	}
	return count
}
