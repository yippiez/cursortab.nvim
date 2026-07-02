package policy

import (
	"os"
	"path/filepath"
	"testing"

	"cursortab/assert"
)

func writeCorruptState(t *testing.T, dir string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, stateFileName), []byte("{not json"), 0644); err != nil {
		t.Fatal(err)
	}
}

func TestStoreSaveLoadRoundtrip(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)

	state := store.Load()
	ps := state.Provider("fim")
	ps.Generation = 3
	ps.Genome.Genes[0].Enabled = false
	ps.Genome.Genes[1].Params = map[string]int{ParamMaxSiblings: 25}
	store.Save(state)

	loaded := NewStore(dir).Load()
	lps := loaded.Provider("fim")
	assert.Equal(t, 3, lps.Generation, "generation")
	assert.False(t, lps.Genome.Genes[0].Enabled, "gene enabled flag")
	assert.Equal(t, 25, lps.Genome.Genes[1].Params[ParamMaxSiblings], "gene param")
}

func TestStoreWithoutStateDirIsInMemory(t *testing.T) {
	store := NewStore("")
	state := store.Load()
	state.Provider("fim").Generation = 5
	store.Save(state)

	fresh := NewStore("").Load()
	assert.Equal(t, 0, fresh.Provider("fim").Generation, "no persistence without state dir")
}

func TestStateKeyedPerProvider(t *testing.T) {
	state := NewStore(t.TempDir()).Load()
	state.Provider("fim").Generation = 2

	assert.Equal(t, 0, state.Provider("zeta-2").Generation, "providers evolve independently")
	assert.Equal(t, 2, state.Provider("fim").Generation, "fim state intact")
}
