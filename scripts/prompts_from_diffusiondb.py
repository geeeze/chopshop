#!/usr/bin/env python3
"""Extract prompts from a DiffusionDB metadata slice into the list slop_cannon reads.

    python3 scripts/prompts_from_diffusiondb.py \\
        --dataset /path/to/metadata-slice.jsonl.zst --limit 16 --out prompts.json

The slice is zstd-compressed JSONL — one DiffusionDB row per line (`prompt`,
`seed`, `cfg`, `step`, `image_name`, ...). Only `prompt` is taken: a bracket
supplies its OWN seeds and steps, so the comparison stays the model rather than
the dataset's sampler settings.

Selection is a seeded reservoir sample over the WHOLE file, not the first N
lines. That matters: the head of a DiffusionDB slice is one author's batch, and
a bracket built on it would report that bias as a property of the models.

Decoding order, and a refusal that names the missing piece:

1. `zstdcat` / `zstd` on PATH — what this box has,
2. the 3.14+ stdlib `compression.zstd`,
3. a plain `.jsonl` read directly (what the tests use).

Stdlib only, streaming: the 167 MB slice is never held in memory.
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import subprocess
import sys
from pathlib import Path


class ExtractionError(RuntimeError):
    pass


def _decode_lines(path: Path):
    """Yield decoded text lines from a .zst or plain file, streaming."""
    if path.suffix != ".zst":
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                yield line
        return

    zstdcat = shutil.which("zstdcat")
    if zstdcat:
        proc = subprocess.Popen([zstdcat, "-c", str(path)],
                                stdout=subprocess.PIPE, text=True,
                                errors="replace")
        assert proc.stdout is not None
        try:
            for line in proc.stdout:
                yield line
        finally:
            proc.stdout.close()
            proc.wait()
        if proc.returncode not in (0, None):
            raise ExtractionError("zstdcat failed on %s (exit %s)"
                                  % (path, proc.returncode))
        return

    try:  # Python 3.14+
        from compression import zstd
    except ImportError as exc:  # pragma: no cover - depends on the interpreter
        raise ExtractionError(
            "cannot decode %s: no `zstdcat` on PATH and this Python has no "
            "`compression.zstd` (3.14+). Install zstd or use a plain .jsonl."
            % path) from exc
    with path.open("rb") as raw:
        with zstd.open(raw, "rt", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                yield line


def iter_prompts(path: Path, min_length: int = 0):
    """Prompt strings from the slice, in file order, filtering short ones."""
    for line in _decode_lines(path):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue  # a damaged line is skipped, not a reason to abort a sample
        prompt = row.get("prompt") if isinstance(row, dict) else None
        if isinstance(prompt, str) and len(prompt.strip()) >= min_length:
            yield prompt.strip()


def reservoir(prompts, limit: int, seed: int) -> list[str]:
    """Seeded reservoir sample: `limit` (0 = everything) drawn uniformly."""
    rng = random.Random(seed)
    if not limit:
        return list(prompts)
    sample: list[str] = []
    for index, prompt in enumerate(prompts):
        if index < limit:
            sample.append(prompt)
            continue
        slot = rng.randint(0, index)
        if slot < limit:
            sample[slot] = prompt
    return sample


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dataset", type=Path, required=True,
                        help="DiffusionDB metadata slice (.jsonl.zst or .jsonl)")
    parser.add_argument("--out", type=Path, required=True,
                        help="where the JSON prompt list is written")
    parser.add_argument("--limit", type=int, default=16,
                        help="prompts to draw (0 = every one in the file)")
    parser.add_argument("--seed", type=int, default=4242,
                        help="sampling seed: same seed, same prompts")
    parser.add_argument("--min-length", type=int, default=0,
                        help="drop prompts shorter than this many characters")
    args = parser.parse_args(argv)

    if not args.dataset.is_file():
        print("error: no such dataset: %s" % args.dataset, file=sys.stderr)
        return 2
    if args.limit < 0:
        print("error: --limit must be >= 0", file=sys.stderr)
        return 2

    try:
        sample = reservoir(iter_prompts(args.dataset, args.min_length),
                           args.limit, args.seed)
    except ExtractionError as failure:
        print("error: %s" % failure, file=sys.stderr)
        return 2

    if not sample:
        print("error: no prompts survived the filter in %s" % args.dataset,
              file=sys.stderr)
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps([{"prompt": p} for p in sample], indent=2))
    print("prompts: %d drawn (seed %d) -> %s" % (len(sample), args.seed, args.out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
