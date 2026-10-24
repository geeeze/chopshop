# Incorporating a public dataset into the studio

The DATASETS page (`/datasets`, `DatasetsController`) is where an external corpus
becomes usable rather than decorative. Two are ingested, and each shows a
different KIND of incorporation — that distinction is the reusable part.

## The two shapes of useful

| dataset | what it gives | where it lands |
| --- | --- | --- |
| **DiffusionDB** (poloclub) | 2M prompts with the hyperparameters their authors used, its own 2-D projection of prompt space, derived topic labels, a phrase tree | `prompt_sources` table + `PromptSource`; browsable, mapped, and GENERATED FROM |
| **MET-Meme** (liaolianfoka) | a 9-field meme annotation SCHEME (metaphor, sentiment, intention, offensiveness) | `app/lib/meme_vocabulary.rb`, transcribed and PINNED against the source README |

A corpus whose data you cannot redistribute is still worth taking as a SCHEMA —
MET-Meme's images are on Kaggle under its own terms, so only the vocabulary came
across, and the page says so rather than implying the pictures are here.

Measured state after the ingest: **60,000 prompts, all mapped, 1,991 parts, 9,632
topics, 1,967 phrase roots, CC0-1.0.**

## Rule 1 — provenance is COLUMNS

A row that cannot say where it came from cannot be used. `dataset`, `licence`,
`part`, `attribution` are columns, and `PromptSource::DATASETS` is the one place a
dataset's identity, licence and attribution are spelled.

## Rule 2 — a hand-typed copy of somebody else's constant must be PINNED

Two transcriptions live here, both generated-from-source:

- MET-Meme's vocabulary → `bin/generate-meme-vocabulary-fixture` parses the
  source **README** (never restated) into `test/fixtures/meme_vocabulary.json`.
- DiffusionDB's numeric `sampler` codes → `bin/generate-sampler-fixture` parses
  `_SAMPLER_DICT` out of the source's `scripts/diffusiondb.py` **with `ast`** (it
  is real Python; a regex over it would be a second, worse parser).

Both support `--check` for CI, and both fail loudly when the source stops
matching rather than pinning a stub. When a source changes: re-run the generator,
review the diff, never edit the fixture to match the code.

**Why the sampler pin matters, concretely:** DiffusionDB stores `sampler` as a
CODE (`8`, `3`) and its own loader maps it (`8 → k_lms`). The studio keeps the
code and `generation_settings` resolves it to the NAME, because the generator
takes a name — passing `"8"` through would file a request the service cannot
honour. A code the source does not define resolves to **nil**, so the request
omits the sampler rather than sending a number.

## Rule 3 — the ingest's fast path must still obey the model

`insert_all` runs **no callbacks**. Reaching for it directly stores rows with no
checksum and unnormalised text — exactly the two things `PromptSource` exists to
guarantee — AND it builds ONE statement, so a batch whose rows carry different
keys aborts with `All objects being inserted must have the same keys`. The
60,000-row ingest hit both: the enriched rows (37,546 of them carry
seed/step/cfg/sampler) had keys the sparse ones lacked.

So the model exposes **one door**: `PromptSource.ingest(rows, slice:)` normalises
the text, stamps the checksum, pads every row to one key set, and slices. The rake
task calls that and nothing else. If a model has callbacks, its bulk path belongs
in the model.

**Corollary that cost a test round:** the checksum must be taken of the
NORMALISED text. Hashing the raw string gave one sentence two identities
depending on the whitespace it arrived with, which defeats the point of a
checksum. One reader (`normalized_prompt`) for the stored value, the hash and the
generation request.

## Ingesting DiffusionDB (the mechanics, and the traps)

Four files, all fetched into `storage/datasets/diffusiondb` (gitignored; URLs are
in the header of `lib/tasks/datasets.rake`):

- `umap-60k.json` — `{xs, ys, prompts}`: 60,000 prompts with the projection
- `umap-1m-topic-data.json` — labelled grid points in the SAME space
- `phrases-tree.json` — `{n, v, l, c}` nodes with counts over 2M prompts
- `metadata.parquet` — 194MB, 2M rows: `image_name, prompt, part_id, seed, step,
  cfg, sampler, width, height, user_name, timestamp, image_nsfw, prompt_nsfw`

Then `bin/rails datasets:ingest_diffusiondb` (env `SOURCE_DIR`, `LIMIT`). It takes
~5 minutes at ~95% CPU; the log is BUFFERED, so an empty log file is not a hang.

**Traps, all hit for real:**

- **HuggingFace serves `images/part-NNNNNN.zip`, not per-part JSON.** The README's
  `part-000001.json` layout is what you get AFTER unzipping a ~600MB shard. The
  usable prompt data without 1.6TB of download is the explorer JSONs above.
- **No pyarrow on this box, and no pip module for the default python.** `uv` is at
  `~/.hermes/bin/uv` and `uv run --with pyarrow python3 script.py` works — but
  **`uv` is NOT on a background shell's PATH**, so an absolute path is required in
  a background command (`command -v uv` in the foreground can lie to you).
- **Parquet → JSONL once, then join in Ruby.** `read_parquet.py` streams the table
  to `metadata-slice.jsonl` (~1GB, ~2 min in the uv environment); it needs a
  `default=` for `json.dumps` because a row carries a datetime and bytes. Ruby
  then does ONE `File.foreach` line pass, keeping only the prompts the map covers.
- **Join on the prompt TEXT.** It is the only key the four files share. Topics are
  a NEAREST labelled grid point within a radius (beyond it: nil, or every empty
  region inherits its neighbour's label — a lie a map must not tell). A phrase root
  is the most frequent whole-word match, longest first, so `art` does not beat
  `artstation` and `8k` does not match inside `128k`.
- **Store the flux contract's word, keep the dataset's own in `meta`.** `guidance`
  is the dataset's `cfg` and `steps` its `step`; `meta.source_fields` records that
  mapping per row so a reader can always get back to the source's vocabulary.
- **Map only rows with BOTH coordinates.** `nil` x/y drawn at the origin would
  claim the middle of the map for a prompt that has no position.

## The map needs TWO caps, not one

A scatter of prompt space is only readable if you cap how many SERIES there are as
well as how many points per series. The library's topic labels are descriptive
slugs, not a taxonomy: 60,000 prompts carry **9,632** of them, so "one series per
topic" would ask the drawing service for a 9,632-entry legend. `map_series`
names the ten most populous and folds the rest into one `other topics (N)` series,
with up to 300 sampled points each — and the page STATES both caps rather than
letting the drawing hide them. Measured result: a 187KB SVG with ~3,300 circles.

## Studio-side traps that cost time here

- **`db/schema.rb` is HAND-MAINTAINED** (`dump_schema_after_migration = false`), so
  a new table must be added to it by hand AND the `version:` bumped. The migration
  guards on `table_exists?` in the `CreateEvents` style.
- **The migration chain is broken before this point**: `AddPaletteToComposites`
  raises `Could not find table 'composites'` on a DB built without it (the dev DB
  here), so plain `db:migrate` cannot reach a newer migration. Use
  `bin/rails db:migrate:up VERSION=…` per DB.
- **Production is a MULTI-DB app**: `db:migrate:up` refuses and you need
  `db:migrate:up:primary VERSION=…` with `~/.chopshop-studio.env` sourced.
- **One key, one meaning.** `MemeVocabulary::SOURCE` used `images` for the Kaggle
  URL and `languages` for the per-language counts, while the generated fixture used
  `images` for the counts. The pin test passed because it compared across the two
  names, and a page then handed a Hash to `link_to` and 500'd. The URL is now
  `images_url`. When two things share a key, the bug is not if.
- **A `before_action` for anything two actions both read.** `@filters` set inside
  `index` left `library` dereferencing nil → 500. Filters now load for both.
- **Filter lists ordered in SQL** (`count(*) DESC, <column> ASC`) with the column
  named as the tie-break, so two equally common topics do not swap places between
  renders.
- **Adding a nav entry breaks TWO tests on purpose.** `engine_light_test` and
  `bp_page_test` assert the last nav link is the NEWEST page (the rule, not the
  incumbent). Adding Datasets means updating that expectation in both and leaving
  the relative-order assertions (`BP` before `Tournament`) intact.

## Verifying it — and what "done" means here

```bash
bin/rails test test/models/prompt_source_test.rb test/models/meme_vocabulary_test.rb
./bin/generate-meme-vocabulary-fixture --check        # the pins, CI form
./bin/generate-sampler-fixture --check
bin/rails datasets:verify_library                    # census + mapped check
curl -b jar /datasets                                 # the page, 200
curl -b jar '/datasets/library?limit=2'               # census + rows
curl -b jar /datasets/meme-labels                     # the 9 fields
```

But the incorporation is only real when a prompt LEAVES the library and comes back
as an image. That is the last check, and it is not optional:

1. `POST /datasets/use` with an id → the Run Job form renders that prompt as the
   textarea default with a provenance line (verified: 302, prompt present,
   editable).
2. File the job with the row's own `settings` and confirm a raster on disk —
   `Job.find(id).spec.dig("flux", "rendered", "images")`, then `File.size` it.
   (Verified: job 386, `flux_68bd74b78c9a.png`, 562,189 bytes, sampler `k_lms`.)
