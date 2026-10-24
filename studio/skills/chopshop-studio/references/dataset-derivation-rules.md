> contains one HOST-SPECIFIC path (the `uv` binary location). The
> derivation rules are generic.

# Dataset derivation rules

> Moved out of `SKILL.md` so the always-on file stays a short router; the rules are unchanged.
>
> Complements `public-datasets.md` and `front-pipeline-dev.md`.

- **A generated dataset must never contain a variant that is visually identical to its input without
  SAYING so.** Any stage that derives similar copies (flipped / rotated / colour-shifted proofs, an
  augmentation set, a training bundle) fails worst not by erroring but by emitting a duplicate: a
  file hashed and labelled as new data that teaches nothing, inside the artifact whose whole purpose is
  data. The mechanism to watch for is a colour remap that only touches pixels EXACTLY equal to a
  palette entry — on continuous-tone art (a proof whose own manifest carries a 487-colour finding)
  the remap matches almost nothing and the output is a near-copy: measured 1,652 of 12,629,472 pixels
  changed (0.013%) while the same input through `invert` changed every pixel. So (a) count what
  actually changed and compare it against the strongest available evidence, not against an exit code;
  (b) make the transform either do real work (a nearest-colour fallback) or refuse with a clear
  reason; and (c) record it in the dataset's own notes when a requested transform had nothing to do.
  A test fixture whose exact-match remap trivially succeeds (a 3-colour flat image) cannot catch this
  — the green suite and the no-op output coexist, which is why the real proof is the fixture.
- **An all-or-nothing derivation stage must distinguish "inapplicable to THIS input" from "broken", or
  one unapplicable transform destroys the whole set.** Those two rules collide: the refusal above is
  right (never emit a silent duplicate) and atomicity is right (never ship a partial set as complete),
  but together they turn "this one transform cannot apply here" into "no dataset at all". Measured: on
  single-ink black line art — an ordinary output of the trace stage — the palette cycle refused, and
  the other ELEVEN transforms, every one of which would have worked, were discarded, so under the
  default opt-in (`variants: true`) the operator got nothing and reads the feature as broken. Every
  passing candidate in that real job was single-ink, while the suite stayed green because no fixture
  is single-colour. Give the stage a distinct not-applicable outcome that SKIPS the transform and
  records it in the notes, keep full atomicity for genuine faults, and make `count`/`transforms`
  report what was actually EMITTED — a set that is 11 of 12 with a note is honest; one that claims 12
  and contains 11 is not. A single-colour fixture is the only thing that exercises this path.
- **Verify a derived artifact at the DELIVERABLE level, not at the function's return.** A transform
  that returns correct bytes can still write a file that has lost what made it useful: every emitted
  raster was saved with no `pnginfo`, so a 300 dpi proof produced 12 variants declaring NO physical
  resolution — pixels lossless, the file no longer saying what size it was. Open the files on disk
  and read them back (`im.info`) as part of the check, and carry the source's dpi, text chunks and ICC
  profile through any re-encode; for a print-derived dataset that is content, not metadata. Do not
  claim "lossless" for a re-encode — the PIXELS are, the FILE is not, and byte-identity with an
  upstream encoder this pipeline does not own is unachievable, so assert pixel identity plus
  determinism instead. The same check catches a refused step leaving a partial directory behind, which
  the archive route would 7-Zip and ship as a real dataset.
- **A public corpus is incorporated TWICE over, and the two are different jobs:** as DATA (DiffusionDB prompts into `prompt_sources` — browsable, mapped by the blend-plot service, generated FROM) and as a SCHEMA (MET-Meme's 9-field meme vocabulary, transcribed and PINNED against the source's own README). Provenance is COLUMNS; a hand-typed copy of somebody else's schema gets a GENERATED fixture. Mechanics, join rules and traps (HF serves `part-NNNNNN.zip` not per-part JSON; no pyarrow, so `uv run --with pyarrow`, and uv is not on a background PATH; `schema.rb` is hand-maintained; production needs `db:migrate:up:primary`) are in `references/public-datasets.md`.
