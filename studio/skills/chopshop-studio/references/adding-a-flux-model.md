# Adding a model to chopshop-flux (and mirroring it into the studio)

Registering a model is a TWO-REPO change. The studio's `FluxConf` is a hand-mirror
of the service's `models.py`, and the studio's suite fails loudly until the mirror
catches up. Add the model to flux first, then mirror it — the studio's tests tell
you every place that needs an edit.

## In chopshop-flux

1. `chopshop_flux/models.py` — a `ModelSpec` entry in `REGISTRY`, plus `as_dict()`
   if you add a field (a new per-entry field is compared by the studio's parity
   test, so it must be mirrored).
2. `examples/prompts.json` — `validate_examples` enforces COVERAGE: every registry
   key must appear in an example, so the suite goes red the moment you register a
   model. That is the gate; add the example.
3. Fix any pre-existing test that assumed the old shape. Tests that pin
   `len(REGISTRY)`, `layout == "diffusers"`, or a hardcoded key set all break on a
   new entry — update them to be meaningful (`if spec.backend == "local"`), do not
   delete the assertion.
4. A new per-entry field with a default the ENGINE rejects is a real bug: a
   `default_steps` below the engine's `steps >= 1` guard makes the model
   unreachable through `generate()` even though every unit test passes. Test the
   model through `engine.generate()`, not only the registry.

## In chopshop-studio — SIX places, all required

The studio suite (and `flux_page_test`) fails until all six carry the new model:

1. `app/models/flux_conf.rb` — `MODELS` entry (spell it `licence`, not `license`),
   and the new field on EVERY entry if you added one.
2. `app/models/flux_conf.rb` — a `QUALITY` sentence. `flux_page_test` asserts
   `MODELS.keys == QUALITY.keys`, and each sentence must contain `Where it fits:`
   and `Weak spot`.
3. `test/lib/flux_repo_parity_test.rb` — add the new field to `MODEL_FIELDS`.
4. `app/views/pages/flux.html.erb` — a hand-written popup block (`.jev-help-pair`).
   The popup is NOT generated from `MODELS`; `flux_page_test` asserts each key's
   text is on the page.
5. `app/views/jobs/new.html.erb` — an `<option>` in `#flux_model`, and in the
   flux-settings popup select.
6. `test/fixtures/runner_conf_drift.json` — an entry under `chopshop_flux.models`.
   It is HAND-TRANSCRIBED; emit it from `FluxConf` itself (run ruby in the
   container) so it matches by construction.

Plus the test PINS: `flux_page_test.rb` hardcodes the select's option list and
partitions models into no-negative-prompt / SD-family by count; `flux_job_test.rb`
and `flux_modifier_form_test.rb` compare the select to `MODELS.keys`.

## Running the studio suite and verifying the mirror

Ruby is not on the host; use the running container:

```
podman exec chopshop-app bash -lc "cd /app && RAILS_ENV=test bin/rails test"
```

**The parity test (`flux_repo_parity_test.rb`) SKIPS on this box** — the container
has no `python3`, and its comparator is a Python AST parser. A skipping suite is
not a green one, so verify the mirror YOURSELF: dump `models.all_as_dict()` from
flux and `FluxConf::MODELS` from the studio (ruby in the container) and diff them
field-for-field (`license` vs `licence`). Expect ZERO differences.

Measure a baseline before your change (`git stash`, run, unstash) — the suite has
pre-existing errors (AssetStalenessGuard, E2eTestingSkill, JsonInjection) that are
NOT yours, and a sibling session may fix them mid-flight, moving the baseline.
After a `git pull --rebase`, RE-RUN the suite: the collided commits can change it.

## A remote (API) backend model

A hosted model (no local checkpoint) carries `backend="novita"`, `layout="remote"`,
`vram_gb`/`repo_bytes` 0, and a `commercial_ok` that reflects the vendor's terms
(Novita prints no licence string — record the Terms of Service and keep it false).
The engine dispatches it to `_run_remote()` (in `engine.py`), which runs the same
output-side passes as the local path; the local path must stay byte-identical.

**Each remote entry serves exactly ONE vendor endpoint, and it is a property of
the entry — not of whether a reference was passed.** `ModelSpec.remote_endpoint`
("images/generations" | "images/edits" | None) records it, and `generate()` refuses
the wrong pairing with a named `ModelError` BEFORE anything loads: an edits-only
model with no reference, and a t2i model WITH one. Inferring the endpoint from
`bool(reference)` is the bug this replaced — picking the layer model without a
reference sent a doomed generations request and surfaced the vendor's own 400
"unsupported request endpoint", naming neither the model nor the fix.

### Wiring it into the RUNNING service (not just the tests)

A green suite proves the code; the studio can only USE it once the service is
restarted on the new code AND has the key:

1. Put the key in `~/.config/chopshop-flux.env` as `CHOPSHOP_FLUX_NOVITA_API_KEY`
   (the systemd `--user` unit's EnvironmentFile) — `config.novita_api_key()`
   reads it at call time, and without it the service refuses a remote model
   before the first request.
2. `systemctl --user restart chopshop-flux`. A running service keeps the OLD
   registry until restarted; `/models` is how you prove it picked the new code
   (the two ming keys + the `backend` field).
3. The studio (`chopshop-app` container) bind-mounts the host repo at `/app` and
   boots `RAILS_ENV=development`, so it picks up a `FluxConf` edit on reload.

Prove the wiring end-to-end with the live service, not the suite:
`POST /generate {"model":"ming-image-0.1-design"}` returns one 1024x1024 frame,
and `POST /edit` with the layer model + a `data:image/png;base64,...` reference
returns the layer PNGs. A remote job is a raster-only or trace job like any other;
the studio's `RunJob` renders through `FluxClient` unchanged.
