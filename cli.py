#!/usr/bin/env python3
"""Command-line entry for chopshop-bp.

Subcommands match the contract operations:

    python3 cli.py generate spec.json out.svg          # geometry  -> SVG
    python3 cli.py digest   metrics.json out.svg       # metrics   -> chart SVG
    python3 cli.py query    runs/ chart.json out.svg   # run records + spec -> SVG
    python3 cli.py tree     hierarchy.json out.svg     # nodes + edges -> tree SVG
    python3 cli.py log      events.json out.svg        # events    -> timeline SVG
    python3 cli.py blender  spec.json blender_out/     # geometry  -> rendered 3D

``out`` defaults to stdout when omitted; any path may be ``-`` for stdin/stdout.
``blender`` is the one operation that writes FILES rather than a document, so its
``out`` is a DIRECTORY (default ``CHOPSHOP_BLENDER_OUT_DIR``) and the file names
it wrote are printed, one per line, to stdout.

Exit codes: 0 success, 2 usage, 3 invalid spec, 4 blender unavailable.

``serve`` is the last command: the same operations over HTTP
(chopshop_plot/server.py), which is how the studio drives this as a runner.
"""

import argparse
import json
import sys
from pathlib import Path

from chopshop_plot import generate, digest, query, tree, log, SpecError, BlenderUnavailable
from chopshop_plot import config
from chopshop_plot.blender import render_blender
from chopshop_plot.query import QueryError
from chopshop_plot.spec import unwrap_payload

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_SPEC = 3

# 4, not 3: the spec was FINE and the renderer is what is missing. A caller that
# sees 3 edits its document; a caller that sees 4 installs Blender or points
# CHOPSHOP_BLENDER_BINARY at it, and a caller that cannot tell them apart
# retries the wrong one. The service maps the same failure to HTTP 503.
EXIT_BLENDER = 4

# The operations that take ONE spec document. `query` is the exception: it takes
# run records AND a chart spec, so it is handled on its own below. `blender` is
# handled on its own too — it writes files rather than returning a string.
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
        prog="chopshop-bp",
        description="The blend-plot service: draw documents, render 3D.",
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

    bln = sub.add_parser("blender", help="geometry spec -> rendered 3D (PNG frames, glb)")
    bln.add_argument("spec", help="path to a JSON spec, or '-' for stdin")
    bln.add_argument("out", nargs="?", default=None,
                     help="output DIRECTORY for the frames (default: "
                          "CHOPSHOP_BLENDER_OUT_DIR); the file names are printed")

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
        elif args.command == "blender":
            text = _read(args.spec)
            spec = _load(text, args.command)
            # "-" (or nothing) means the configured directory: the same default
            # the service uses, so a CLI render and an HTTP render land in one
            # place and /files/<name> can serve either.
            out_dir = config.blender_out_dir() if args.out in (None, "-") else args.out
            names = render_blender(spec, out_dir)
        else:
            text = _read(args.spec)
            spec = _load(text, args.command)
            svg = _SPEC_OPERATIONS[args.command](spec)
    except (SpecError, QueryError) as exc:
        print(f"chopshop-bp: {exc}", file=sys.stderr)
        return EXIT_SPEC
    except BlenderUnavailable as exc:
        print(f"chopshop-bp: {exc}", file=sys.stderr)
        return EXIT_BLENDER

    if args.command == "blender":
        # One name per line: a shell pipeline can read them, and a human can too.
        for name in names:
            print(name)
        return EXIT_OK

    _write(args.out, svg)
    return EXIT_OK


def main():
    sys.exit(run(sys.argv[1:]))


if __name__ == "__main__":
    main()
