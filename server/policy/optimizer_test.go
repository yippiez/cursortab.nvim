package policy

import (
	"testing"

	"cursortab/assert"
	"cursortab/ctx"
	"cursortab/metrics"
)

const testProvider = "zeta-2"

// runEpoch feeds one epoch of shown completions where acceptRate of them are
// accepted and the rest ignored.
func runEpoch(o *Optimizer, acceptRate float64) {
	epoch := o.state.Provider(testProvider).Evolution.EpochShown
	accepts := int(acceptRate * float64(epoch))
	for i := 0; i < epoch; i++ {
		o.RecordOutcome(metrics.EventShown)
		if i < accepts {
			o.RecordOutcome(metrics.EventAccepted)
		} else {
			o.RecordOutcome(metrics.EventIgnored)
		}
	}
}

func TestOptimizerPromotesBetterChallenger(t *testing.T) {
	o := NewOptimizer(t.TempDir(), testProvider, testRNG(1))
	champion := o.state.Provider(testProvider).Genome.clone()

	runEpoch(o, 0.2) // champion epoch: low accept rate
	ps := o.state.Provider(testProvider)
	assert.Equal(t, PhaseChallenger, ps.Phase, "phase after champion epoch")
	assert.NotNil(t, ps.Challenger, "challenger spawned")
	challenger := ps.Challenger.clone()

	runEpoch(o, 0.8) // challenger epoch: high accept rate
	ps = o.state.Provider(testProvider)
	assert.Equal(t, PhaseChampion, ps.Phase, "phase after challenger epoch")
	assert.Equal(t, 1, ps.Generation, "generation advanced")
	assert.True(t, ps.Genome.equal(challenger), "challenger promoted")
	assert.False(t, ps.Genome.equal(champion), "champion replaced")
}

func TestOptimizerDiscardsWorseChallenger(t *testing.T) {
	o := NewOptimizer(t.TempDir(), testProvider, testRNG(2))
	champion := o.state.Provider(testProvider).Genome.clone()

	runEpoch(o, 0.8) // champion epoch: high accept rate
	runEpoch(o, 0.2) // challenger epoch: low accept rate

	ps := o.state.Provider(testProvider)
	assert.Equal(t, 1, ps.Generation, "generation advanced")
	assert.True(t, ps.Genome.equal(champion), "champion kept")
	assert.Nil(t, ps.Challenger, "challenger discarded")
}

func TestOptimizerRejectionsWeighAgainstChallenger(t *testing.T) {
	o := NewOptimizer(t.TempDir(), testProvider, testRNG(3))
	champion := o.state.Provider(testProvider).Genome.clone()

	runEpoch(o, 0.0) // champion epoch: everything ignored (score 0)

	// Challenger epoch: same accept rate of zero, but explicit rejections.
	epoch := o.state.Provider(testProvider).Evolution.EpochShown
	for i := 0; i < epoch; i++ {
		o.RecordOutcome(metrics.EventShown)
		o.RecordOutcome(metrics.EventRejected)
	}

	ps := o.state.Provider(testProvider)
	assert.True(t, ps.Genome.equal(champion), "rejected challenger not promoted")
}

func TestOptimizerServesActiveArmGenome(t *testing.T) {
	o := NewOptimizer(t.TempDir(), testProvider, testRNG(4))
	supported := allMaterials()
	base := baseLimits()

	championPlan, championLimits := o.Plan(supported, base)
	assert.Len(t, len(supported), championPlan, "champion serves default genome")
	assert.Equal(t, base, championLimits, "champion serves base limits")

	runEpoch(o, 0.5)
	ps := o.state.Provider(testProvider)
	assert.Equal(t, PhaseChallenger, ps.Phase, "challenger phase active")

	challengerPlan, challengerLimits := o.Plan(supported, base)
	planChanged := len(challengerPlan) != len(championPlan) ||
		!limitsEqual(challengerLimits, championLimits) ||
		!sameMaterialOrder(challengerPlan, championPlan)
	assert.True(t, planChanged, "challenger plan differs from champion plan")
}

func TestOptimizerStateSurvivesRestart(t *testing.T) {
	dir := t.TempDir()

	o := NewOptimizer(dir, testProvider, testRNG(5))
	runEpoch(o, 0.2)
	runEpoch(o, 0.9)
	evolved := o.state.Provider(testProvider)

	restarted := NewOptimizer(dir, testProvider, testRNG(6))
	ps := restarted.state.Provider(testProvider)
	assert.Equal(t, evolved.Generation, ps.Generation, "generation persisted")
	assert.True(t, ps.Genome.equal(evolved.Genome), "genome persisted")

	static := NewStatic(dir, testProvider)
	assert.True(t, static.genome.equal(evolved.Genome), "static policy serves evolved genome")
}

func TestOptimizerPartialEpochPersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()

	o := NewOptimizer(dir, testProvider, testRNG(7))
	o.RecordOutcome(metrics.EventShown)
	o.RecordOutcome(metrics.EventAccepted)
	o.RecordOutcome(metrics.EventShown)
	o.RecordOutcome(metrics.EventIgnored)

	restarted := NewOptimizer(dir, testProvider, testRNG(8))
	arm := restarted.state.Provider(testProvider).ChampionEpoch
	assert.Equal(t, 2, arm.Shown, "shown count persisted")
	assert.Equal(t, 1.0, arm.WeightSum, "weight sum persisted")
	assert.Equal(t, 1, arm.Outcomes[string(metrics.EventAccepted)], "accepted count persisted")
}

func TestStoreLoadToleratesMissingAndCorruptFiles(t *testing.T) {
	state := NewStore(t.TempDir()).Load()
	ps := state.Provider(testProvider)
	assert.True(t, ps.Genome.equal(DefaultGenome()), "missing file yields default genome")

	dir := t.TempDir()
	store := NewStore(dir)
	writeCorruptState(t, dir)
	state = store.Load()
	ps = state.Provider(testProvider)
	assert.True(t, ps.Genome.equal(DefaultGenome()), "corrupt file yields default genome")
}

func limitsEqual(a, b ctx.CollectionLimits) bool {
	return a == b
}

func sameMaterialOrder(a, b ctx.Materials) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		an, _ := materialNameOf(a[i])
		bn, _ := materialNameOf(b[i])
		if an != bn {
			return false
		}
	}
	return true
}
