package policy

import (
	"math/rand/v2"
	"testing"

	"cursortab/assert"
)

func testRNG(seed uint64) *rand.Rand {
	return rand.New(rand.NewPCG(seed, seed))
}

func TestMutateProducesDifferentGenome(t *testing.T) {
	rng := testRNG(1)
	genome := DefaultGenome()

	for i := 0; i < 50; i++ {
		mutated := Mutate(genome, rng, 1)
		assert.False(t, mutated.equal(genome), "mutation changes genome")
	}
}

func TestMutateDoesNotModifyInput(t *testing.T) {
	rng := testRNG(2)
	genome := DefaultGenome()
	original := genome.clone()

	for i := 0; i < 50; i++ {
		Mutate(genome, rng, 2)
	}

	assert.True(t, genome.equal(original), "input genome unchanged")
}

func TestMutateKeepsParamsWithinBounds(t *testing.T) {
	rng := testRNG(3)
	genome := DefaultGenome()

	// Walk many generations to push params toward their bounds.
	for i := 0; i < 500; i++ {
		genome = Mutate(genome, rng, 2)
	}

	for _, gene := range genome.Genes {
		for name, value := range gene.Params {
			spec, ok := specFor(gene.Material, name)
			assert.True(t, ok, "param has a spec: "+name)
			assert.GreaterOrEqual(t, value, spec.Min, name+" >= min")
			assert.LessOrEqual(t, value, spec.Max, name+" <= max")
		}
	}
}

func TestMutateNeverDisablesAllGenes(t *testing.T) {
	rng := testRNG(4)
	genome := DefaultGenome()

	for i := 0; i < 500; i++ {
		genome = Mutate(genome, rng, 2)
		assert.Greater(t, enabledCount(genome), 0, "at least one gene enabled")
	}
}

func specFor(material MaterialName, name string) (paramSpec, bool) {
	for _, spec := range paramSpecs {
		if spec.Material == material && spec.Name == name {
			return spec, true
		}
	}
	return paramSpec{}, false
}
