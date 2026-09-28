#!/usr/bin/env python3
"""Command-line entry for chopshop-plot.

Subcommands match the two contract operations:

    python3 cli.py generate spec.json out.svg    # geometry -> SVG
    python3 cli.py digest   metrics.json out.svg # metrics  -> chart SVG

Either file may be ``-`` for stdin/stdout. Exit codes: 0 success, 2 usage,
3 invalid spec.
"""

import argparse
import json
import sys

from chopshop_plot import generate, digest, SpecError

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


def run(argv):
    parser = argparse.ArgumentParser(
        prog="chopshop-plot", description="Geometry source and run reporter for chopshop."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    gen = sub.add_parser("generate", help="geometry spec -> SVG")
    gen.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    gen.add_argument("out", help="path to write SVG, or '-' for stdout")

    dig = sub.add_parser("digest", help="metrics spec -> chart SVG")
    dig.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    dig.add_argument("out", help="path to write SVG, or '-' for stdout")

    args = parser.parse_args(argv)

    text = _read(args.spec)
    spec = _load(text, args.command)
    try:
        if args.command == "generate":
            svg = generate(spec)
        else:
            svg = digest(spec)
    except SpecError as exc:
        print(f"chopshop-plot: {exc}", file=sys.stderr)
        return EXIT_SPEC

    _write(args.out, svg)
    return EXIT_OK


def main():
    sys.exit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
