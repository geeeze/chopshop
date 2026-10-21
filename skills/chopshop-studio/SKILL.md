---
name: chopshop-studio
description: Use when working on Chopshop Studio — the private umbrella (app, Jev, SwarmUI, runner, repo fleet).
---

## Host-specific tagging convention

This skill documents BOTH the Chopshop Studio app (host-agnostic) and the
author's own deployment (this box). Anything that describes the deployment —
absolute paths under the author's home, this box's ports and hostnames,
measured timings and pixel calibrations, this machine's git/docker/systemd
setup — is marked `HOST-SPECIFIC`. Such facts are **subject to change and must
be removed or generalized before this skill is reused on another host or
published elsewhere.** Everything unmarked is host-agnostic and should stay
that way.

Grep `HOST-SPECIFIC` to enumerate everything flagged.

# Chopshop Studio

## When to Use

Load this skill for anything in the private Chopshop system: the studio Rails app
(`~/chopshop-studio`), the Jev add-on, SwarmUI/ComfyUI, the studio-side runner, the
repo fleet, and the change/deploy/verification procedure. The public `chopshop-svg`
pipeline carries its own repo-owned skill. **Read the topic file named in the index
below before working in that area** — only the standing rules under "Working agreements"
are always-on; everything else is one file away, on purpose.

Private demo at https://<public-host>: raster → traced SVG candidates, the operator picks one, and that pick is proved: proof PNG, print PDF, manifest. The pipeline never picks a winner. Rails 8.1 + Propshaft, dark glass Aether theme. Cloudflare (Full strict) → nginx :80/:443 → production Puma on 127.0.0.1:3001. App directory: `~/chopshop-studio`.

This is the **umbrella** skill for the whole Chopshop system except the public
`chopshop-svg` repo (whose host-agnostic knowledge lives in that repo's own
repo-owned skill). Everything private — the studio app, Jev, SwarmUI/ComfyUI,
the repo fleet, and the studio-side runner — lives here. Host-specific facts are
tagged `HOST-SPECIFIC` (subject to change, and the scrub line before studio goes
public — Apache-2.0, private today, likely public later); see
`references/repo-visibility-and-tagging.md`.

**Jobs surface**: the Projects redesign (workspace per project,
project-scoped jobs, the Run Job form's project picker) — see
`references/projects-redesign.md`; `GET /jobs` 404s.

Landing a batch of unmerged `agent/*` branches across the fleet — surveying what
is still unmerged, the two review axes, merging and verifying against the remote,
the venv and conflict-resolution pitfalls — is in
`references/repo-fleet-review-and-merge.md`.

A comprehensive REVIEW sweep of the whole stack (the fan-out roles for live-stack
QA, dropped-changes evaluation and reference-app mining; batch tracker filing;
then the fix loops) is in `references/review-sweep.md`.

## Working agreements (always-on)

- Answer the question asked, not the tangent. A narrow ask ("repos up to date?") gets a narrow answer; an incidental finding (uncommitted files in an unrelated clone, an odd config value) gets one line and nothing more. Do not spiral into verifying a subsystem the user didn't mention — that is the correction the user applies hardest.
- When the user tells you to stop, stop and stay stopped — no "understood, I'll stop" followed by more summary, re-answer, or "tell me what to do next". Announcing compliance and then continuing is not acknowledgment, it is the same mistake a second time, and it reads as deliberate ignoring. One quiet ack at most, then nothing until the user speaks.
- **Ship the smallest REVERSIBLE change, not the finished product.** The target is a working studio, not a professional-grade system at the outset: fewer, explained options beat a complete one, and a change the operator can undo by deleting one block beats a redesign he has to unpick. When a decision is low-stakes, make the small reversible improvement instead of asking him to choose between designs — and when he ignores a design question you asked while answering a different one, treat that as the answer. When something must be restructured, keep the old path reachable (hide, do not remove) so reverting is a deletion rather than a rewrite. Machinery that has to be fought to undo is what he pushes back on hardest.
- **"Why can't I do X?" about a breakage he is HITTING is a request for a FIX, not a diagnosis.** Land the fix and verify it live in the same pass; a filed issue is not a deliverable, and he will come back with the same error still in front of him. If you genuinely cannot fix it now (no access, a decision only he can make), say which one you are doing — never quietly substitute a ticket for the fix. When the fault lives in another repo, fix it THERE and file the issue against the repo that OWNS the code, not the one where the symptom appeared: a bug visible in the studio but caused by a service or guard belongs on the service's tracker with the studio side noted as the reporter.
- **Direct, brief responses — no filler.** Match response length to question weight; one line for a one-line ask. No "Great question", no restating the request back, no replaying the process, no filler. This is the user's standing preference (documented in session 2026-10-21 review sweep).
- **When told DOCUMENT ONLY (no change): record findings and stop.** Filing is recording; committing to the tree is changing. Do not blend the two.
- **Scope discipline: only repos/tasks explicitly named.** When the user names "chopshop- issues", do not expand to unrelated repos without confirmation.
- **Under concurrent merges (changes landing mid-sweep): put subagents on the live/local stack FIRST and pull drops when they land** — never block the review waiting for an in-flight merge, and never force-merge (use `--ff-only`; stop and report if refused). The evaluator child is the single writer allowed to pull; the main checkout stays untouched while a coder holds it.

Process rules longer than a line — subagents vs the working tree, the `AGENTS.md` approval
gate, the layout-instruction playbook, resolving a setting in one place — are in
`references/working-agreements.md`.

## Where everything lives — read the topic file, do not re-derive

Load the topic file; do not re-derive these from memory.

### Design and vocabulary
- `references/design-and-vocabulary.md` — **moved out of this file**: the BP action and sequences, who-owns-what (the metrics-engine boundary), the operator vocabulary (candidates/jobs/PROOFS), and the auth model.
- **`references/config-mirror-surface.md`** — the mirrored-config constants (`FluxConf`/`BpConf`/`JevConf`/`PipelineConf`/`Telemetry`/`BpExamples`/`PaletteLibrary`), the pin-strength grades (read the test, don't trust its name), the parity-test skip trap, and the consolidation pattern (one page per service, one fixture, one drift test). Read before touching any `*_conf.rb` or claiming a mirror is "pinned".

### Change, deploy and live verification
- `references/change-and-live-verification.md` — **moved out of this file**: precompile → migrate → restart, the live verification gate, and the deploy/boot traps (asset-file-at-boot, launcher topology, deploy at the end of a layout task).

### Frontend, layout and UX
- `references/ux-and-frontend.md` — **moved out of this file**: the aesthetic invariants, the modal action slot, the layout/CSS/JS/markup traps, and the layout-instruction playbook.
- **`references/layout-and-probe-pitfalls.md`** — the bulk of the front-end rules: grid
  placement, cascade specificity, flex/grid min-content, modal scrollers, the
  page-head mechanism, and the Ruby/Nokogiri test traps. Read before any layout change.
- **`references/headless-layout-probe.md`** — the working probe harness (temporary
  integration test → template with a `<pre id="result">` → Chromium `--dump-dom`), the
  computed-value normalisation traps, and the CSS rules it has caught.
- **`references/layout-measurement.md`** — measuring a LAYOUT change (column geometry, control
  bands, panel widths): `vw` vs `%`, label-fits assertions, pill-vs-orb shape changes,
  `requestSubmit()`, WCAG label-in-name, and the probe-harness traps. Complements
  `visual-effect-verification.md`, which covers glows/rings/animation.
- **`references/background-canvas-and-animation.md`** — `aether.js` and anything that
  animates: what "background nodes" actually are, resizing a canvas from the element that
  is really CSS-sized, callbacks that run before a prototype assignment, and why a debounce
  needs a timeout behind its rAF.
- `references/ui-conventions.md` — design inventory and copy rules; with
  `ui-copy-and-tooltips.md` and `visual-effect-verification.md` for wording, help popups
  and effect checks.
- `references/composites-and-test-uploads.md` — **read before any test that writes
  to `storage/uploads`, and before driving the Composite path.** A cleanup that globs the LIVE
  uploads directory deletes the operator's rasters and bp drawings, so scope every cleanup to
  what the test itself added; a lost drawing is repairable from the job's own recorded document
  rather than by re-running the job. Plus the composite create → flatten contract.
- `references/job-form-and-templates.md` — **read before adding a template, a
  form control, or a new way of filing a job.** The one-spec-round-trip rule,
  the GUIDED CHOICE (`PipelineConf::GROUPS`: a kind-of-job control that narrows
  the template list, then that kind's deeper setting), why picking a kind must
  APPLY and why the apply path must hydrate EVERY panel, the
dedicated-fieldset pattern (window-scoped hooks + `showKind` ownership) and why
  an off-screen fieldset must be DISABLED and not merely `hidden`, why feature
  params are TOP-LEVEL (`job[…]` unknown attrs 500), the inline sim-job create
  branch with its validator stand-aside, and the testing rules (runner-env
  hermeticity, flux stubbing trio, guard-wave sweep, random-draw determinism,
  validating a composed spec against the SERVICE's own validator).

### Backend, Rails and infrastructure
- `references/backend-rails-and-infra.md` — **moved out of this file**: Cloudflare/TLS facts and the Rails template, asset, migration, controller, session and wire traps.
- **`references/studio-backend-traps.md`** — runner contract, uploads, auth/session,
  deploy and asset commands, Rails/Ruby version traps, process handling, the
  merge-after-deploy asset check, and **filing to this repo's GitHub issue tracker**
  (`--body-file`, the label vocabulary, verifying after filing, proving a staged list
  byte-identical to the tracker BEFORE deleting it, and re-probing a credential before
  declaring an access blocker). Also why the recorded suite baseline is
  environment-specific and must be re-measured. Batch-files a staged issue list:
  `scripts/file-issues.py`.
- **`references/git-history-rewrite.md`** — purging a committed secret from PUBLISHED
  history: the recon, measuring whether the leaked value is even live, the backup,
  the filter-branch + `refs/original` + gc sequence, verifying from a fresh clone of
  the remote (including the all-objects brute-force scan), the leased force-push, and
  why unpublish is never rotation. Read before any history rewrite.
- **Backend, runner, deploy and tooling traps** — the `RunnerClient#post` keyword-argument
  trap, the source-preview naming contract, private uploads, the `RAILS_ENV=production`
  precompile rule, why a 302 from an auth-gated page proves nothing, the **CSRF-recovery
  contract** (a stale authenticity token now redirects to `/login` instead of 422ing — and
  the trap where enabling forgery protection in a test signs nobody in) plus the
  **scripted-login recipe** that makes a live gated replay possible, the production-DB
  prefix, Minitest 6 dropping `minitest/mock`, and the `pkill -f` self-match that kills
  your own shell or hangs a wait loop — all in `references/studio-backend-traps.md`.
- **`config/master.key` was tracked from the first commit and has since been PURGED
  from published history.** Untracking alone does not unpublish, so the history itself
  was rewritten and force-pushed, then verified from a fresh clone of the remote — the
  procedure and its traps (the `refs/original` refs that defeat `gc`, the fictitious
  `--mirror` origin, verifying from the remote and not the rewriting copy) are in
  `references/git-history-rewrite.md`. Read it before touching history again.

### Runner and services
- `references/runner-and-services.md` — **moved out of this file**: mock-vs-real runner traps, manifest servability, a service behind its own origin, the fleet-venv breakage after a python bump.
- `references/runner-deploy.md` — the real runner on this box: docker on
  `127.0.0.1:8787`, image name, rebuild-not-restart, the archive endpoint and
  its status ladder, disk gate, mock-runner two-path drift, mock-vs-real.
- `references/runner-job-dirs.md`, `references/orphan-sweep.md` — job-dir
  layout and the orphan sweep.
- `references/jev-integration.md` — the Jev add-on (three pieces, status
  contract, typed answers, timing), the question-set TEMPLATES (a second vocabulary,
  built as data: projector + questions + fold), and the MEASURED wire contract — what
  the service accepts and what it refuses with an opaque 400. Read it before adding a
  question set or touching the request envelope.
- `references/flux-jobs.md` — flux job shapes (trace vs raster-only), the model registry and its hand-mirrored twin in `FluxConf`, why a running service can advertise a registry it no longer has, the raster-only archive gap, and the guidance-vs-default warning rule.
- `references/model-registry-recipes.md` — adding models / LoRA adapters / VAE swaps: HF-API licence and size triage, the rejections worth recording, the diffusers call ORDER that makes a VAE swap work under CPU offload, the vendored-`peft` step LoRA loading depends on, and the measured timings (including why a distilled model is not proportionally faster).

### Verification and probes
- `references/verification-and-probes.md` — **moved out of this file**: checks that cannot fail, the render-and-walk-the-DOM shortcut, the ERB compile limits, Nokogiri selector gotchas.
- `references/e2e-testing.md` — driving the app end-to-end as a specific user (<test-handle>): the python-urllib login/session harness, job-submit fields and spec shapes, polling to done, the `upload_preview/:name` route gotcha, **a live bash smoke pass over the whole stack** (the `/login` CSRF token, the `--data-urlencode` one-field trap, the `job[spec]={...}` brace trap, the bp `input_path` bug, id-from-`Location`), and the credential rule (**`<test-handle>` is the OPERATOR's account and its password is never reset — `<disposable-handle>` is the disposable one**). Read before "run the e2e tests". Proves a credential is the live one: `scripts/check_studio_login.py`.
- `references/browser-interaction-verification.md` — verifying a gesture, button or JS
  state in a real browser: **a delegated handler's throw is SILENT** (collect
  `window.onerror` + `unhandledrejection`), assert the app's OWN side effect rather than
  "the handler ran", `awaitPromise`-poll for AJAX-rendered nodes, bind a drop to
  `document.body` when the drag has exactly one meaning on the page, and use `git log -L`
  to tell "never worked" from "regressed".
- `references/probe-verification-failures.md` — the four ways a probe reports a confident
  green without testing anything, and the two questions to ask before believing one.
- **Five more ways to build a probe that cannot fail** — a mutation that never landed, the
  wrong invariant compared, a harness varying a variable the artifact records, a harness
  reading its OWN bug as the system's answer, and a source-reading test grepping markup
  kept behind a fallback (it passes in both switch states and false-alarms on the
  revert). Each reports a confident green: full text in
  `references/probe-verification-failures.md`.

### Datasets and the pipeline
- `references/datasets-library.md` — **read before planning or promising any
  DATASETS feature.** The prompt-source library (DiffusionDB/MET-Meme) lives
  HERE, not in flux/dmpool: where each piece of the data lives (corpus on <gpu-box>,
  rows in the VPS sqlite, MET-Meme schema-only), what is already built
  (`PromptSource`, ingest, single-job dataset draw), the real gap (batch /
  mashup / curated views), the mashup design (LM Studio strict-JSON, N≥1,
  template fallback), how to test the mashup LIVE, and the pitfalls (grep the app tree first, no podman on
  the VPS, <gpu-box> is ssh -p 22822).
- `references/dataset-derivation-rules.md` — **moved out of this file**: never emit a silent duplicate variant, not-applicable vs broken in an all-or-nothing stage, verify at the deliverable.
- `references/front-pipeline-dev.md`, `references/pipeline-notes.md` — the
  tracing side and its packaging/opt-in rule.

### Fleet, repos and process
- `references/working-a-studio-issue.md` — the CONCRETE one-issue-at-a-time loop: the `gh` claim commands (assignee + comment = the hands-off signal), the coder → neutral-reviewer → parent-ships cycle, the suite-is-green rule (the old #15 `E2eTestingSkillTest` expected-failure baseline is gone — a failure is a failure now), and the `CHROME_BIN` path `verify-ui-clicks.js` needs on this box (there is no `~/.cache/ms-playwright`).
- `references/working-agreements.md` — **moved out of this file**: the behavioural rules — subagents vs the working tree, the `AGENTS.md` gate, opening the target view before the first edit, one resolution site per setting.
- `references/repo-fleet.md` — repo sweep, visibility/tagging, sync-skills,
  delegation (and the one-issue-at-a-time backlog cycle: claim → coder → reviewer →
  the PARENT ships), commit-author forensics, scope boundary, vetting a dirty worktree
  before syncing, and the "is there abandoned plugin work here" recon (with the
  upstream-checkout noise that makes a no look like a yes), plus VETTING A NEWLY
  CLONED repo for adoption (metadata → suite → real CLI on an out-of-clone store →
  defects with evidence) and the `dmpool` entry.
- `references/repo-hygiene-audit.md` — the duplication audit (duplicate/divergent agent files, skills,
  redundant docs) **and the visibility audit**: scan TRACKED files not the working tree, scan history
  and commit METADATA for a public repo, verify a green `--check` actually compares something, and file
  a leak finding privately. Read when the ask is "audit the repos / check for leakage".
- `references/auditing-errored-jobs.md` — **read when the ask is "look at the errored
  jobs".** Group them by root cause, not by job: an audit of nine collapsed into three classes,
  and one wrong rule was reachable by four different doors. Covers where a "what may be a job's
  source" check belongs (the create path, not the model — and why), the two tests that were
  PINNING the broken rule, which errored rows are working correctly and should be reported as
  such, and the concurrent-test-run collision signature (865 errors in 9.6s).

### Topic files not linked from anywhere else
- **Four reference files exist but were missing from this map** — load them by name rather
  than assuming the list above is complete: `references/candidate-triage.md` (the triage
  vocabulary and the ranker/bandit seam), `references/one-job-step-lists.md` (one job
  carrying an ordered step list rather than N rows), `references/queue-and-plot.md` (the
  queue's plot/blend-plot targets AND what bp can/cannot draw — read before promising a
  diagram through bp), `references/studio-driver-scripts.md` (the harness
  scripts and how they authenticate). Nothing else links to them, so a reader who trusts
  the map alone will not know they exist.
