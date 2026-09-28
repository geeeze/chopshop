#!/usr/bin/env python3
"""Command-line entry for chopshop-plot.

Subcommands match the contract operations:

    python3 cli.py generate spec.json out.svg          # geometry  -> SVG
    python3 cli.py digest   metrics.json out.svg       # metrics   -> chart SVG
    python3 cli.py query    runs/ chart.json out.svg   # run records + spec -> SVG
    python3 cli.py tree     hierarchy.json out.svg     # nodes + edges -> tree SVG
    python3 cli.py log      events.json out.svg        # events    -> timeline SVG

``out`` defaults to stdout when omitted; any path may be ``-`` for stdin/stdout.
Exit codes: 0 success, 2 usage, 3 invalid spec.

``serve`` is the last command: the same operations over HTTP
(chopshop_plot/server.py), which is how the studio drives this as a runner.
"""

import argparse
import json
import sys
from pathlib import Path

from chopshop_plot import generate, digest, query, tree, log, SpecError
from chopshop_plot.query import QueryError
from chopshop_plot.spec import unwrap_payload

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_SPEC = 3

# The operations that take ONE spec document. `query` is the exception: it takes
# run records AND a chart spec, so it is handled on its own below.
_SPEC_OPERATIONS = {
    "generate": generate,
    "digest": digest,
    "tree": tree,
    "log": log,
}


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
    # The envelope rule lives in the package, not here: the service reads the
    # same documents and must read them identically.
    return unwrap_payload(spec, op)


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

    tre = sub.add_parser("tree", help="hierarchy spec (nodes + edges) -> tree SVG")
    tre.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    tre.add_argument("out", nargs="?", default="-", help="SVG output (default stdout)")

    lgd = sub.add_parser("log", help="event spec -> timeline SVG")
    lgd.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    lgd.add_argument("out", nargs="?", default="-", help="SVG output (default stdout)")

    srv = sub.add_parser("serve", help="run the HTTP service (the same operations)")
    srv.add_argument("--bind", default=None,
                     help="address to listen on (default: CHOPSHOP_PLOT_BIND, else loopback)")
    srv.add_argument("--port", type=int, default=None,
                     help="port to listen on (default: CHOPSHOP_PLOT_PORT, else the service default)")
    srv.add_argument("--verbose", action="store_true", help="log every request")

    args = parser.parse_args(argv)

    if args.command == "serve":
        # Imported here rather than at module scope: the CLI's file operations
        # should not require the HTTP surface (or vice versa) to be importable,
        # and the service imports the same operation functions.
        from chopshop_plot.server import serve

        serve(bind=args.bind, port=args.port, verbose=args.verbose)
        return EXIT_OK

    try:
        if args.command == "query":
            records = _load_runs(args.runs)
            text = _read(args.spec)
            spec = _load(text, args.command)
            svg = query(records, spec)
        else:
            text = _read(args.spec)
            spec = _load(text, args.command)
            svg = _SPEC_OPERATIONS[args.command](spec)
    except (SpecError, QueryError) as exc:
        print(f"chopshop-plot: {exc}", file=sys.stderr)
        return EXIT_SPEC

    _write(args.out, svg)
    return EXIT_OK


def main():
    sys.exit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
