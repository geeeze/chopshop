#!/usr/bin/env python3
"""Command-line entry for chopshop-plot.

Subcommands match the contract operations:

    python3 cli.py generate spec.json out.svg          # geometry -> SVG
    python3 cli.py digest   metrics.json out.svg       # metrics  -> chart SVG
    python3 cli.py query    runs/ chart.json out.svg   # run records + spec -> SVG

``out`` defaults to stdout when omitted; any path may be ``-`` for stdin/stdout.
Exit codes: 0 success, 2 usage, 3 invalid spec.
"""

import argparse
import json
import sys
from pathlib import Path

from chopshop_plot import generate, digest, query, SpecError
from chopshop_plot.query import QueryError

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_SPEC = 3


def _read(path):
    if path == "-":
        return sys.stdin.read()
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def _write(path, content):
    if path == "-":
        sys.stdout.write(content)
    else:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)


def _load(text, op):
    try:
        spec = json.loads(text)
    except json.JSONDecodeError as exc:
        raise SpecError(f"{op}: spec is not valid JSON: {exc}") from exc
    if isinstance(spec, dict) and spec.get("op") and spec["op"] != op:
        raise SpecError(f"{op}: spec has op={spec['op']!r}")
    return spec.get("spec", spec) if isinstance(spec, dict) else spec


def _load_runs(runs_path):
    """Load a set of run records from a directory or file.

    A directory loads every ``*.run.json`` under it (recursively).  A file loads
    a JSON list of run records, or a single run record object.
    """
    p = Path(runs_path)
    records = []
    if p.is_dir():
        for f in sorted(p.rglob("*.run.json")):
            try:
                records.append(json.loads(f.read_text(encoding="utf-8")))
            except (OSError, ValueError) as exc:
                raise QueryError(f"query: bad run record {f}: {exc}") from exc
    else:
        try:
            data = json.loads(_read(runs_path))
        except json.JSONDecodeError as exc:
            raise QueryError(f"query: runs file is not valid JSON: {exc}") from exc
        records = data if isinstance(data, list) else [data]
    if not records:
        raise QueryError("query: no run records found")
    return records


def run(argv):
    parser = argparse.ArgumentParser(
        prog="chopshop-plot", description="Geometry source and run reporter for chopshop."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="geometry spec -> SVG")
    gen.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    gen.add_argument("out", nargs="?", default="-", help="SVG output (default stdout)")

    dig = sub.add_parser("digest", help="metrics spec -> chart SVG")
    dig.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    dig.add_argument("out", nargs="?", default="-", help="SVG output (default stdout)")

    qry = sub.add_parser("query", help="run records + chart spec -> SVG")
    qry.add_argument("runs", help="directory of *.run.json, or a runs file")
    qry.add_argument("spec", help="path to a chart spec, or '-' for stdin")
    qry.add_argument("out", nargs="?", default="-", help="SVG output (default stdout)")

    args = parser.parse_args(argv)

    try:
        if args.command == "query":
            records = _load_runs(args.runs)
            text = _read(args.spec)
            spec = _load(text, args.command)
            svg = query(records, spec)
        else:
            text = _read(args.spec)
            spec = _load(text, args.command)
            svg = generate(spec) if args.command == "generate" else digest(spec)
    except (SpecError, QueryError) as exc:
        print(f"chopshop-plot: {exc}", file=sys.stderr)
        return EXIT_SPEC

    _write(args.out, svg)
    return EXIT_OK


def main():
    sys.exit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
