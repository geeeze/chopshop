# Datasets as a translation problem — and why JEV is already the right machine

This annotator was built to translate one thing into another: a printability
**measurement** becomes a production **decision**, through a projection, a set of
narrow typed questions, and a thresholded fold. The vocabulary it translates
*into* (screen spot, halftone, DTG, engraving-grade) is a print shop's.

Nothing in that machinery is specific to print. It is a translation layer, and a
translation layer is only as useful as the vocabularies you point it at. The
studio's DATASETS page now holds two public corpora, and this document is the
case for using them as the second vocabulary — plus the honest list of what is
not built and what may not be claimed.

## The two shapes a dataset can take here

| corpus | what it gives | how it is used today |
| --- | --- | --- |
| **DiffusionDB** | real prompts and the hyperparameters their authors used, with the dataset's own 2-D projection of prompt space | the studio's prompt **library**: browsable, mapped, and generated from for real (ingested: 60,000 prompts) |
| **MET-Meme** | a nine-field meme annotation scheme — metaphor occurrence and category, source/target domain and modality, sentiment, intention, offensiveness | transposed into the studio as a **vocabulary** (`app/lib/meme_vocabulary.rb`), pinned against the source's README; its images stay on Kaggle |

So one corpus supplies **material** and the other supplies **questions**. That
split is the whole design: a prompt library on its own is a gallery, and an
annotation scheme on its own is a paper. Pointed at each other they produce
something neither has — labels over a space.

## The join the studio already has

The studio does not merely store prompts; it **generates** from them and keeps
what came back. A prompt drawn from the library plus the raster the generator
produced from it is a **text-image pair** — which is exactly MET-Meme's unit of
analysis, and exactly what that scheme is designed to describe.

Nothing else in this system has that triangle: material, artifact, and a
published vocabulary for labelling the second given the first. This is why the
translation work belongs here rather than as a general "ask JEV about anything"
feature — the join is real, specific, and already populated.

## The profile, concretely

`dataset-translation` is the second question set (see `PROFILES` in
`scripts/jev_annotate.py`; `--list-profiles` prints every template that ships,
this one among them). Its three stages map
onto the printability profile's, one for one:

- **Project** — `project_artifact` reads a generation artifact (prompt, the
  author's settings, whatever was measured of the raster) and produces a compact
  state. Same rule as the manifest projection: long text is scrubbed, paths are
  shortened, and the full record never leaves the machine.
- **Ask** — eight questions: seven of MET-Meme's nine fields (the two it does not
  get are the SHAPE-constrained domain fields — see the `phrase` decision below),
  plus `evidence_is_actionable`, the `noul` that asks whether the state holds
  enough to label the thing at all.
- **Fold** — `compose_annotation_verdict` reads the question set's own types
  rather than any one domain's keys, so a third vocabulary needs no new folding
  code. `compose_verdict` (the studio's domain contract: `headline`,
  `print_route`, `tonal_score`, `evidence_actionable`) is deliberately untouched.

Two decisions in that mapping are worth stating because they were choices:

- **Criteria keys are identifiers, not display words.** The question set says
  `text_dominant`; the studio's vocabulary module holds "text dominant" and the
  dataset's ordinals. Two renderings of one vocabulary, deliberately — the
  question set has to survive a JSON contract, and the studio page has to read
  like the paper. The follow-up is a drift test between them, the way the studio
  already pins its `JevConf` against this file. Until that test exists, the two
  renderings are correct by inspection and not by construction, and that is a
  weaker claim.
- **`phrase` is not a type the service has — measured, not assumed.** MET-Meme
  constrains its two domain fields by SHAPE ("adj + n" / "verb + n") rather than
  by a list, so they need a free-text answer. A `phrase` type was written for
  this repo and REFUSED IN USE: a question set containing one comes back
  `HTTP 400 api_usage_error: Invalid request`, while the same set without it is
  answered. So `source_domain` and `target_domain` are **not asked at all** —
  the one part of the scheme this profile cannot reach — and a template that
  declares a type the service refuses is stopped locally with the measurement in
  the message, so nobody pays a round trip to rediscover it.

## What the service actually accepts (measured, not read off a card)

Every line below is one live request against `api.typesafe.ai/v1/systemone`,
model `jev-latest`, each varying exactly one thing:

| request | result |
| --- | --- |
| printability, envelope `{model, state, questions}` | **200** |
| the same, plus a `profile` key in the envelope | **400** `api_usage_error` |
| the meme set as first written (10 questions, two of them `phrase`) | **400** |
| the meme set with `requires`/`shape` stripped, `phrase` still present | **400** |
| 4, 5, 6 and 8 non-`phrase` questions | **200** each — no count cap |
| 8 questions carrying `requires` | **200** — extra fields INSIDE a question are tolerated |

Two conclusions, and both changed the code:

1. **The envelope is exactly `{model, state, questions}`.** An extra key beside
   them — added for bookkeeping, which felt harmless — turned every request in
   the repo into a 400, including the printability request that had worked for a
   year. What this repo knows about a request now goes in the **sidecar**. The
   service is strict about the envelope and relaxed about question objects, which
   is not a distinction that could have been guessed.
2. **There is no free-text answer type.** Only `choice`, `score` and `noul` are
   implemented. That is what costs the scheme its two domain fields.

## What the fold admits, in three lists

The verdict keeps three different admissions apart, because collapsing them is
how a guess starts reading as a fact:

| list | meaning |
| --- | --- |
| `values` | what was answered |
| `low_confidence` | answered, below the confidence floor |
| `unevidenced` | answered, but the state says the evidence that question needs is not here |

`unevidenced` exists because of one fact this annotator must not paper over:
**it is given text and numbers, never pixels**. Three of MET-Meme's fields
(`metaphor_category`, `source_modality`, `target_modality`) are about an image
and declare `requires: ["image_visible"]`, and the state declares
`evidence.image_visible: false` by construction, so the fold reports them rather
than letting a confident answer stand. A fourth, `metaphor_occurrence`, is about
the metaphor's presence and is asked from the prompt alone — it declares no
requirement, so it is not reported as unevidenced, and the one live run agrees:
eight answers, three of them unevidenced.

The honest consequence: **run as-is, this profile's image-dependent answers are
unevidenced by definition.** That is not a defect to be tuned away; it is the
finding. It says either the annotator needs to see the image, or the profile
should ask only the questions the evidence actually supports. Both are legitimate
next moves and this document does not pick between them.

## What may not be claimed

- **It runs.** One artifact has been annotated live end to end (job 386's raster,
  1,320 input tokens): `status: ok`, model `jev-1.13.0`, eight answers folded,
  three of them `unevidenced` and two below the confidence floor. The two honesty
  mechanisms agreed with each other — the fold's mechanical `unevidenced` list
  and the service's own `evidence_is_actionable` answer (P(true) = 0.26, i.e.
  "your materials will not support a label") — which is the first evidence that
  the design is not merely strict but *correctly* strict.
- **These answers are not ground truth.** MET-Meme's images and their per-image
  labels are not in this repo (they are on Kaggle under the dataset's own terms),
  so nothing here can be scored against a reference. An answer is an
  **unvalidated annotation** and any page that shows one must say so as plainly
  as the tournament page says "SIMULATED".
- **JEV remains advisory.** Unchanged, and it is rule one: a label never filters,
  ranks, gates or auto-rejects anything. It annotates.
- **Scale.** One external call per artifact, so 60,000 library rows are not the
  unit; a sample, or the artifacts this system generated, are.

## The next step, which is small on purpose

Before any of this is built out: **measure whether the translation is stable.**
Run the profile twice over the sixteen conference contenders — artifacts the
studio already holds both a prompt and a raster for — and compare the two sets of
answers.

That is a **reliability** measurement (does the same input get the same label?),
not an accuracy claim (is the label right?), and the distinction is the whole
point: reliability can be measured here, with what is on disk, and accuracy
cannot be measured at all until a labelled reference is available. If the answers
do not agree with themselves, nothing downstream of them is worth building.

Deliberately not proposed yet: making the profile visible in the studio, the
cross-vocabulary drift test, and giving the annotator pixels. Each is a real
piece of work and each should follow the reliability number rather than precede
it.

## See also

A third vocabulary ships beside this one: `generation-slop`, which asks what the
**measurements** of a raster say about whether it is slop, over the same kind of
generation artifact, and is driven by `scripts/slop_cannon.py` (README, "The slop
cannon"). This document stays about the MET-Meme translation.
