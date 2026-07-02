package policy

import (
	"math/rand/v2"
	"sync"

	"cursortab/ctx"
	"cursortab/logger"
	"cursortab/metrics"
)

// Static serves the persisted champion genome without learning. It is the
// default context policy: data-driven, but fixed for the session.
type Static struct {
	genome Genome
}

// NewStatic loads the champion genome for the provider from stateDir (or the
// default genome when none is persisted).
func NewStatic(stateDir, providerType string) *Static {
	state := NewStore(stateDir).Load()
	return &Static{genome: state.Provider(providerType).Genome}
}

func (s *Static) Plan(supported ctx.Materials, base ctx.CollectionLimits) (ctx.Materials, ctx.CollectionLimits) {
	return s.genome.Plan(supported, base)
}

func (s *Static) RecordOutcome(metrics.EventType) {}

// Optimizer serves and evolves the persisted genome with a (1+1) online
// evolution strategy: each generation the champion and a mutated challenger
// alternately serve an epoch of completions, their outcome-weighted scores are
// compared, and the winner becomes (or stays) the champion. State persists
// after every outcome so generations survive daemon restarts.
type Optimizer struct {
	mu           sync.Mutex
	store        *Store
	state        *State
	providerType string
	rng          *rand.Rand
}

func NewOptimizer(stateDir, providerType string, rng *rand.Rand) *Optimizer {
	store := NewStore(stateDir)
	return &Optimizer{
		store:        store,
		state:        store.Load(),
		providerType: providerType,
		rng:          rng,
	}
}

func (o *Optimizer) Plan(supported ctx.Materials, base ctx.CollectionLimits) (ctx.Materials, ctx.CollectionLimits) {
	o.mu.Lock()
	defer o.mu.Unlock()
	ps := o.state.Provider(o.providerType)
	if ps.Phase == PhaseChallenger && ps.Challenger != nil {
		return ps.Challenger.Plan(supported, base)
	}
	return ps.Genome.Plan(supported, base)
}

func (o *Optimizer) RecordOutcome(event metrics.EventType) {
	o.mu.Lock()
	defer o.mu.Unlock()
	ps := o.state.Provider(o.providerType)
	arm := o.activeArm(ps)

	if event == metrics.EventShown {
		arm.Shown++
	} else {
		arm.WeightSum += ps.Evolution.Weights[event]
		if arm.Outcomes == nil {
			arm.Outcomes = make(map[string]int)
		}
		arm.Outcomes[string(event)]++
		// Advance only on terminal events so an epoch's final completion
		// counts its own outcome before the arms switch.
		o.advance(ps)
	}

	o.store.Save(o.state)
}

func (o *Optimizer) activeArm(ps *ProviderState) *ArmStats {
	if ps.Phase == PhaseChallenger {
		return &ps.ChallengerEpoch
	}
	return &ps.ChampionEpoch
}

func (o *Optimizer) advance(ps *ProviderState) {
	switch ps.Phase {
	case PhaseChampion:
		if ps.ChampionEpoch.Shown < ps.Evolution.EpochShown {
			return
		}
		challenger := Mutate(ps.Genome, o.rng, ps.Evolution.MutationOps)
		ps.Challenger = &challenger
		ps.Phase = PhaseChallenger

	case PhaseChallenger:
		if ps.ChallengerEpoch.Shown < ps.Evolution.EpochShown {
			return
		}
		champion := meanWeight(ps.ChampionEpoch)
		challenger := meanWeight(ps.ChallengerEpoch)
		if ps.Challenger != nil && challenger > champion+ps.Evolution.PromoteMargin {
			logger.Info("context policy: generation %d promoted challenger (%.3f > %.3f)",
				ps.Generation, challenger, champion)
			ps.Genome = *ps.Challenger
		}
		ps.Generation++
		ps.Challenger = nil
		ps.ChampionEpoch = ArmStats{}
		ps.ChallengerEpoch = ArmStats{}
		ps.Phase = PhaseChampion
	}
}

func meanWeight(arm ArmStats) float64 {
	if arm.Shown == 0 {
		return 0
	}
	return arm.WeightSum / float64(arm.Shown)
}
