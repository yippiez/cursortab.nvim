package policy

import (
	"testing"

	"cursortab/assert"
	"cursortab/ctx"
)

func allMaterials() ctx.Materials {
	return ctx.Materials{
		ctx.Diagnostics{},
		ctx.Treesitter{},
		ctx.GitDiff{},
		ctx.TabMd{},
		ctx.RecentFiles{},
		ctx.EditHistory{},
		ctx.UserActions{},
	}
}

func baseLimits() ctx.CollectionLimits {
	return ctx.CollectionLimits{
		MaxSiblings:        50,
		MaxDiffBytes:       4096,
		MaxChangedSymbols:  50,
		MaxRecentSnapshots: 3,
		MaxDiffTokens:      1024,
		MaxUserActions:     16,
	}
}

func TestDefaultGenomePreservesSupportedMaterialsAndLimits(t *testing.T) {
	supported := allMaterials()
	base := baseLimits()

	planned, limits := DefaultGenome().Plan(supported, base)

	assert.Len(t, len(supported), planned, "planned materials")
	assert.Equal(t, base, limits, "limits unchanged")
	for _, m := range supported {
		name, ok := materialNameOf(m)
		assert.True(t, ok, "material has a name")
		assert.True(t, plannedContains(planned, name), string(name)+" planned")
	}
}

func TestPlanIntersectsWithProviderSupportedMaterials(t *testing.T) {
	supported := ctx.Materials{ctx.Treesitter{}, ctx.Diagnostics{}}

	planned, _ := DefaultGenome().Plan(supported, baseLimits())

	assert.Len(t, 2, planned, "planned materials")
	assert.True(t, plannedContains(planned, MaterialTreesitter), "treesitter planned")
	assert.True(t, plannedContains(planned, MaterialDiagnostics), "diagnostics planned")
}

func TestPlanDropsDisabledGenes(t *testing.T) {
	genome := DefaultGenome()
	for i := range genome.Genes {
		if genome.Genes[i].Material == MaterialRecentFiles {
			genome.Genes[i].Enabled = false
		}
	}

	planned, _ := genome.Plan(allMaterials(), baseLimits())

	assert.Len(t, len(allMaterials())-1, planned, "planned materials")
	assert.False(t, plannedContains(planned, MaterialRecentFiles), "recent_files dropped")
}

func TestPlanAppliesGeneParamOverrides(t *testing.T) {
	genome := DefaultGenome()
	for i := range genome.Genes {
		switch genome.Genes[i].Material {
		case MaterialTreesitter:
			genome.Genes[i].Params = map[string]int{ParamMaxSiblings: 10}
		case MaterialRecentFiles:
			genome.Genes[i].Params = map[string]int{ParamMaxRecentSnapshots: 5}
		}
	}

	_, limits := genome.Plan(allMaterials(), baseLimits())

	assert.Equal(t, 10, limits.MaxSiblings, "max siblings override")
	assert.Equal(t, 5, limits.MaxRecentSnapshots, "max recent snapshots override")
	assert.Equal(t, 4096, limits.MaxDiffBytes, "untouched limit inherits base")
}

func TestPlanSkipsParamsOfDisabledGenes(t *testing.T) {
	genome := DefaultGenome()
	for i := range genome.Genes {
		if genome.Genes[i].Material == MaterialTreesitter {
			genome.Genes[i].Enabled = false
			genome.Genes[i].Params = map[string]int{ParamMaxSiblings: 10}
		}
	}

	_, limits := genome.Plan(allMaterials(), baseLimits())

	assert.Equal(t, 50, limits.MaxSiblings, "disabled gene params ignored")
}

func TestPlanOrdersMaterialsByGenomeOrder(t *testing.T) {
	genome := Genome{Genes: []Gene{
		{Material: MaterialEditHistory, Enabled: true},
		{Material: MaterialTreesitter, Enabled: true},
	}}
	supported := ctx.Materials{ctx.Treesitter{}, ctx.EditHistory{}}

	planned, _ := genome.Plan(supported, baseLimits())

	assert.Len(t, 2, planned, "planned materials")
	first, _ := materialNameOf(planned[0])
	second, _ := materialNameOf(planned[1])
	assert.Equal(t, MaterialEditHistory, first, "first planned material")
	assert.Equal(t, MaterialTreesitter, second, "second planned material")
}

func plannedContains(planned ctx.Materials, name MaterialName) bool {
	for _, m := range planned {
		if n, ok := materialNameOf(m); ok && n == name {
			return true
		}
	}
	return false
}
