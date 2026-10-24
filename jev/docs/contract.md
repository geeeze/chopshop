# chopshop-jev — Interface Contract

Jev is optional and advisory. It never modifies the manifest, never ranks, never
picks a winner. Deterministic gates in `chopshop-svg` stay the source of truth.

## Scripts (`scripts/`)

| Script | Role |
|---|---|
| jev_annotate.py   | behavioural spec — do NOT reimplement its question set/projection/verdict |
| jev_remediate.py  | remediation loop (steps 3-7 open; `--remediate` refuses by design) |
| slop_cannon.py    | slop detection |
| caption_serve.py  | caption serving |
| prompts_from_diffusiondb.py | prompt sourcing |

## HTTP policy

- Unconfigured add-on answers **503 with a reason**, never 404 (404 = wiring bug hunt).

## Boundaries

- If a change would make Jev decisive, it is wrong.
- Repo private; host facts tagged `HOST-SPECIFIC`.
