# chopshop-flux doc/code gaps (recorded)

1. docs/API.md does not document `release()` (locked unload form) or the engine lock behavior added for #flux-unload-locked (mentioned in CONTEXT.md).
2. docs/API.md does not mention env vars `CHOPSHOP_FLUX_IDLE_UNLOAD`, `MALLOC_MMAP_THRESHOLD_`, `MALLOC_ARENA_MAX`, `MemoryMax` — all documented in CONTEXT.md but not the public API docs.
3. docs/API.md route descriptions don't reference `modifier` / `vae` registry keys documented in CONTEXT.md (though `/models` shows them).
4. AGENTS.md / docs/agents/ files exist but contents unclear; may be stale relative to CONTEXT.md work-in-progress.
5. README says six routes; verify server.py exports exactly six (likely /health, /models, /generate, /edit, /files/<name>, /unload, /load? may be more).
6. CONTEXT.md notes SSD-1B steps/guidance are MEASURED, but registry docs don't show measured vs estimated flag.
Note: repo cycle excludes console per user steering.
