package policy

import (
	"encoding/json"
	"os"
	"path/filepath"

	"cursortab/logger"
	"cursortab/metrics"
)

const (
	stateFileName = "context_policy.json"
	stateVersion  = 1
)

// State is the persisted per-user context policy, keyed by provider type so
// each provider evolves independently.
type State struct {
	Version   int                       `json:"version"`
	Providers map[string]*ProviderState `json:"providers"`
}

// ProviderState holds one provider's champion genome and, when evolution is
// active, the in-flight generation bookkeeping. Persisting the epoch counters
// lets generations span the daemon's frequent idle restarts.
type ProviderState struct {
	Genome          Genome          `json:"genome"`
	Generation      int             `json:"generation"`
	Evolution       EvolutionParams `json:"evolution"`
	Phase           Phase           `json:"phase"`
	Challenger      *Genome         `json:"challenger,omitempty"`
	ChampionEpoch   ArmStats        `json:"champion_epoch"`
	ChallengerEpoch ArmStats        `json:"challenger_epoch"`
}

// Phase is which arm currently serves completions.
type Phase string

const (
	PhaseChampion   Phase = "champion"
	PhaseChallenger Phase = "challenger"
)

// ArmStats accumulates outcomes for one arm's current epoch.
type ArmStats struct {
	Shown     int            `json:"shown"`
	WeightSum float64        `json:"weight_sum"`
	Outcomes  map[string]int `json:"outcomes,omitempty"`
}

// EvolutionParams tune the online evolution loop. They live in the state file
// so the loop itself is data-driven.
type EvolutionParams struct {
	// EpochShown is how many shown completions each arm observes per
	// generation before champion and challenger are compared.
	EpochShown int `json:"epoch_shown"`
	// PromoteMargin is the mean-weight improvement a challenger must show
	// over the champion to be promoted.
	PromoteMargin float64 `json:"promote_margin"`
	// MutationOps is how many random edits produce a challenger.
	MutationOps int `json:"mutation_ops"`
	// Weights score each completion outcome. New feedback kinds (e.g. a
	// future "request more concise") slot in as additional entries.
	Weights map[metrics.EventType]float64 `json:"weights"`
}

// DefaultEvolutionParams favors accepts, is neutral on ignores, and penalizes
// explicit rejections.
func DefaultEvolutionParams() EvolutionParams {
	return EvolutionParams{
		EpochShown:    30,
		PromoteMargin: 0.02,
		MutationOps:   1,
		Weights: map[metrics.EventType]float64{
			metrics.EventAccepted: 1.0,
			metrics.EventRejected: -0.25,
			metrics.EventIgnored:  0.0,
		},
	}
}

func defaultProviderState() *ProviderState {
	return &ProviderState{
		Genome:    DefaultGenome(),
		Evolution: DefaultEvolutionParams(),
		Phase:     PhaseChampion,
	}
}

// Provider returns the state for one provider type, initializing a default if
// missing or unusable.
func (s *State) Provider(providerType string) *ProviderState {
	if s.Providers == nil {
		s.Providers = make(map[string]*ProviderState)
	}
	ps := s.Providers[providerType]
	if ps == nil || len(ps.Genome.Genes) == 0 {
		ps = defaultProviderState()
		s.Providers[providerType] = ps
	}
	if ps.Evolution.EpochShown <= 0 {
		ps.Evolution = DefaultEvolutionParams()
	}
	if ps.Phase == "" {
		ps.Phase = PhaseChampion
	}
	return ps
}

// Store reads and writes policy state under a state directory. An empty
// stateDir disables persistence.
type Store struct {
	path string
}

func NewStore(stateDir string) *Store {
	if stateDir == "" {
		return &Store{}
	}
	return &Store{path: filepath.Join(stateDir, stateFileName)}
}

// Load returns the persisted state, or a fresh one when the file is missing
// or unreadable.
func (s *Store) Load() *State {
	state := &State{Version: stateVersion}
	if s.path == "" {
		return state
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		return state
	}
	if err := json.Unmarshal(data, state); err != nil {
		logger.Warn("context policy: resetting unreadable state file: %v", err)
		return &State{Version: stateVersion}
	}
	state.Version = stateVersion
	return state
}

// Save persists the state atomically (write temp file, then rename).
func (s *Store) Save(state *State) {
	if s.path == "" {
		return
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		logger.Warn("context policy: marshal state: %v", err)
		return
	}
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0644); err != nil {
		logger.Warn("context policy: write state: %v", err)
		return
	}
	if err := os.Rename(tmp, s.path); err != nil {
		logger.Warn("context policy: rename state: %v", err)
	}
}
