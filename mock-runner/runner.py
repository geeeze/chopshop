#!/usr/bin/env python3
"""Chopshop Studio mock runner.

Implements the runner contract in doc/runner-contract.md so the Rails GUI can
be exercised end-to-end without a live runner host. Simulates:

  front_pipeline.sh  -> prep -> trace sweep -> comparison (candidates + metrics)
  pipeline.sh        -> Layer A + Layer B manifest, proof.png, print.pdf
  jev_annotate.py    -> typed System One decision sidecar (canned answers)

Serves on 127.0.0.1:8790 only. Auth: bearer token if MOCK_TOKEN is set.
Artifacts land in MOCK_ROOT (default /tmp/chopshop-mock/<job_id>/).
"""
from __future__ import annotations

import json
import hashlib
import os
import random
import re
import shutil
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from PIL import Image, ImageDraw

PORT = int(os.environ.get("MOCK_PORT", "8790"))
ROOT = Path(os.environ.get("MOCK_ROOT", "/tmp/chopshop-mock"))
TOKEN = os.environ.get("MOCK_TOKEN", "")
LOCK = threading.Lock()

JOBS: dict[str, dict] = {}
VALIDATIONS: dict[str, dict] = {}

MIN_ARCHIVE_FREE = 1 * 1024 ** 3  # refuse to build a 7z archive below 1 GiB free


class Cancelled(Exception):
    """Raised by a worker to signal an operator-cancelled job."""


def free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def build_archive(job_dir: Path, name: str) -> Path | None:
    """7z the whole job directory (contents under one folder). Returns the
    archive path, or None when 7z is missing or fails."""
    seven = shutil.which("7z") or shutil.which("7za") or shutil.which("7zr")
    if not seven:
        return None
    out = job_dir.parent / f"{name}.7z"
    cmd = [seven, "a", "-t7z", "-mx=5", "-y", "-bd", str(out), str(job_dir)]
    proc = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, timeout=300)
    if proc.returncode != 0 or not out.is_file():
        return None
    return out

PALETTE = ["#000000", "#FFFFFF", "#FF0000", "#0000FF", "#FFFF00", "#00FF00"]
# Colours a real source raster might carry but that are NOT in the assigned
# palette — the pitch-shift variant visibly snaps these back onto PALETTE.
OFF_PALETTE = ["#E8710A", "#1FB8A0"]
BG = "#101018"
PRESETS = ["bw", "poster", "photo"]
SPECKLES = [2, 8, 16]
HIER = ["cutout", "stacked"]


def invert_hex(h: str) -> str:
    """#rrggbb -> its RGB-inverted twin (#rrggbb)."""
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return "#%02x%02x%02x" % (255 - r, 255 - g, 255 - b)


def variant_colors(variant: str) -> list[str]:
    """The colour pool a pseudo-trace draws from, per pitch-shift variant."""
    if variant == "inverse":
        return [invert_hex(c) for c in (PALETTE + OFF_PALETTE)]
    if variant == "pitch":
        return list(PALETTE)  # recoloured onto the assigned palette
    return list(PALETTE) + list(OFF_PALETTE)  # source as-is

# ---------------------------------------------------------------- helpers

def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "artwork"

def seed_for(text: str) -> int:
    return int(hashlib.sha256(text.encode()).hexdigest()[:8], 16)

def make_sample_raster(path: Path, seed: int) -> None:
    """Deterministic demo artwork: bold shapes from the spec palette."""
    rng = random.Random(seed)
    img = Image.new("RGB", (900, 900), BG)
    d = ImageDraw.Draw(img)
    colors = list(PALETTE) + list(OFF_PALETTE)
    for i in range(7):
        color = rng.choice(colors)
        kind = rng.choice(["circle", "rect", "tri", "ring"])
        x, y = rng.randint(80, 700), rng.randint(80, 700)
        r = rng.randint(60, 220)
        if kind == "circle":
            d.ellipse([x, y, x + r, y + r], fill=color)
        elif kind == "rect":
            d.rectangle([x, y, x + r, y + int(r * rng.uniform(0.4, 1.0))], fill=color)
        elif kind == "tri":
            d.polygon([(x, y + r), (x + r // 2, y), (x + r, y + r)], fill=color)
        else:
            w = max(12, r // 8)
            d.ellipse([x, y, x + r, y + r], outline=color, width=w)
    # a bold "ink" bar so min-stroke checks have something to chew on
    d.rectangle([120, 780, 780, 830], fill=rng.choice(colors))
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")

def make_inverse_twin(src: Path) -> None:
    """RGB-inverted twin of the source raster (the studio's source.inverse.png).

    Always produced for raster sources — this mirrors the real pipeline's
    ``print.invert`` prep twin, which the studio's source preview shows
    alongside the original. Pure PIL, so it runs in the runner venv.
    """
    img = Image.open(src).convert("RGB")
    inv = img.point(lambda p: 255 - p)
    inv.save(src.with_name("source.inverse.png"), "PNG")


def make_pitch_raster(src: Path) -> None:
    """Nearest-palette recolour of the source (the studio's source.pitch.png)."""
    img = Image.open(src).convert("RGB")
    pal = [tuple(int(h[i:i + 2], 16) for i in (1, 3, 5)) for h in PALETTE]
    cache = {}

    def nearest(px):
        if px not in cache:
            cache[px] = min(pal, key=lambda c: sum(
                (a - b) ** 2 for a, b in zip(px, c)))
        return cache[px]

    pitch = Image.new("RGB", img.size)
    pitch.putdata([nearest(px) for px in img.getdata()])
    pitch.save(src.with_name("source.pitch.png"), "PNG")

def make_candidate_svg(path: Path, index: int, preset: str, speckle: int,
                       hier: str, use_palette: bool, seed: int,
                       variant: str = "source") -> None:
    """Deterministic pseudo-trace: simple vector shapes honouring the sweep
    axes and the pitch-shift variant (source / inverse / pitch)."""
    rng = random.Random(seed + index * 977)
    colors = variant_colors(variant)
    if use_palette:
        colors = [c for c in colors if c != "#00FF00"]
    bg = invert_hex(BG) if variant == "inverse" else BG
    parts = []
    for i in range(4 + (index % 4)):
        color = colors[i % len(colors)]
        x, y = rng.randint(60, 660), rng.randint(60, 660)
        r = rng.randint(70, 200) + (8 if speckle == 16 else 0)
        op = 1.0 if hier == "stacked" else 0.9
        parts.append(
            f'<circle cx="{x + r // 2}" cy="{y + r // 2}" r="{r // 2}" '
            f'fill="{color}" fill-opacity="{op}"/>')
    if preset == "bw":
        parts = [p.replace('fill-opacity="0.9"', 'fill-opacity="1"')
                 for p in parts]
    body = "\n  ".join(parts)
    path.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="900" height="900" '
        f'viewBox="0 0 900 900">\n'
        f'  <rect width="900" height="900" fill="{bg}"/>\n  {body}\n</svg>\n',
        encoding="utf-8")

def make_proof_png(path: Path, index: int, seed: int) -> None:
    rng = random.Random(seed + index * 31)
    img = Image.new("RGB", (600, 600), "#101018")
    d = ImageDraw.Draw(img)
    for i in range(5):
        color = rng.choice([c for c in PALETTE if c != "#101018"])
        x, y = rng.randint(30, 450), rng.randint(30, 450)
        r = rng.randint(40, 160)
        d.ellipse([x, y, x + r, y + r], fill=color)
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")

def candidate_metrics(index: int, preset: str, speckle: int, hier: str,
                      use_palette: bool, seed: int,
                      variant: str = "source") -> dict:
    """Metrics shaped like the real comparison.json entries."""
    rng = random.Random(seed + index * 131)
    base_hard = 0 if preset != "photo" else 1
    if use_palette and rng.random() < 0.4:
        base_hard += 1
    if speckle == 2 and rng.random() < 0.5:
        base_hard += 1
    hard = base_hard
    advisory = rng.randint(0, 3)
    layer_a = "pass" if hard == 0 or rng.random() < 0.2 else "fail"
    layer_b = "pass" if (layer_a == "pass" and rng.random() < 0.85) else (
        "error" if rng.random() < 0.1 else "fail")
    mae = round(rng.uniform(2.0, 18.0), 2)
    if preset == "bw":
        mae = round(mae * 1.6, 2)
    if use_palette:
        mae = round(mae * 1.3, 2)
    # inverse and pitch traces diverge from the source, so their fidelity
    # against the source is higher (they are different on purpose)
    if variant in ("inverse", "pitch"):
        mae = round(mae * 1.4, 2)
    passed = layer_a == "pass" and layer_b == "pass"
    return {
        "file": f"candidate_{index:02d}.svg",
        "sweep": {
            "preset": preset,
            "filter_speckle": speckle,
            "hierarchical": hier,
            "use_palette": use_palette,
            "variant": variant,
        },
        "layer_a": {"status": layer_a},
        "layer_b": {"status": layer_b},
        "hard": hard,
        "advisory": advisory,
        "fidelity": {
            "measured": True,
            "mae": mae,
            "mae_art": round(mae * rng.uniform(0.5, 0.95), 2),
            "p95": round(mae * rng.uniform(2.5, 4.0), 1),
            "within_10": round(rng.uniform(0.55, 0.97), 3),
        },
        "passed": passed,
    }

def run_front(job: dict) -> None:
    """Simulate front_pipeline.sh: prep -> sweep -> compare."""
    d = Path(job["dir"])
    log = job["log"]
    stem = job["stem"]
    seed = job["seed"]

    def stage(msg: str, delay: float) -> None:
        deadline = time.time() + delay
        while time.time() < deadline:
            if job.get("cancel"):
                raise Cancelled()
            time.sleep(0.2)
        with LOCK:
            log.append(msg)

    job["state"] = "running"
    stage(f"front pipeline   input: {job['input_path']}", 0.4)
    stage("--- stage 1: raster prep ---", 0.9)
    d.mkdir(parents=True, exist_ok=True)
    src = d / "source.png"
    make_sample_raster(src, seed)
    with LOCK:
        job["prep_summary"] = {
            "format": "PNG", "dimensions": "900x900 px",
            "aspect": "1.00", "colors_declared": 6,
            "checks": ["format ok", "alpha flattened", "background uniform"],
        }
    stage(f"prep ok -> 01_prepped/{stem}.prepped.png", 0.8)
    stage("--- stage 2: trace sweep (vtracer 0.6.15 python-api) ---", 1.2)

    spec = job.get("spec") or {}
    print_opts = spec.get("print") or {}
    pitch_shift = bool(print_opts.get("pitch_shift"))
    sweep_max = int(print_opts.get("sweep_max_candidates") or 12)
    variants = ["source", "inverse", "pitch"] if pitch_shift else ["source"]
    pal_axis = [False] if pitch_shift else (False, True)

    # The inverse twin is a standard prep output (mirrors the real pipeline's
    # print.invert twin) and always exists; pitch is pitch-shift-specific.
    make_inverse_twin(src)
    if pitch_shift:
        make_pitch_raster(src)
        stage("prep variants -> source / inverse / pitch", 0.5)

    combos = []
    for speckle in SPECKLES:
        for hier in HIER:
            for preset in PRESETS:
                for pal in pal_axis:
                    for variant in variants:
                        combos.append((preset, speckle, hier, pal, variant))
    combos = combos[:sweep_max]
    candidates = []
    index = 1
    for preset, speckle, hier, pal, variant in combos:
        make_candidate_svg(d / f"candidate_{index:02d}.svg",
                           index, preset, speckle, hier, pal, seed, variant)
        m = candidate_metrics(index, preset, speckle, hier, pal, seed, variant)
        candidates.append(m)
        stage(f"  traced candidate_{index:02d}.svg  "
              f"[preset={preset} speckle={speckle} hier={hier} "
              f"variant={variant} palette={'y' if pal else '-'}]", 0.25)
        index += 1

    candidates.sort(key=lambda c: (c["hard"], c["advisory"]))
    comparison = {
        "stem": stem,
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sort": "fewest hard gates failed, then fewest advisories",
        "candidates": candidates,
    }
    (d / "comparison.json").write_text(json.dumps(comparison, indent=2),
                                        encoding="utf-8")
    stage("--- stage 3: compare candidates (Layer A + Layer B) ---", 1.0)
    passed = [c["file"] for c in candidates if c["passed"]]
    stage(f"front pipeline: {len(passed)} of {len(candidates)} candidates "
          f"passed both gates -- comparison: 04_validated/{stem}.comparison.json",
          0.3)
    with LOCK:
        job["candidates"] = candidates
        job["comparison"] = comparison
        job["state"] = "done"

def run_back(val: dict) -> None:
    """Simulate pipeline.sh on one candidate."""
    time.sleep(1.4)
    job = JOBS[val["job_id"]]
    d = Path(job["dir"])
    seed = job["seed"]
    cand = next(c for c in job["candidates"] if c["file"] == val["candidate_file"])
    idx = int(re.search(r"(\d+)", cand["file"]).group(1))

    proof = d / f"proof_{idx:02d}.png"
    make_proof_png(proof, idx, seed)
    pdf = d / f"print_{idx:02d}.pdf"
    make_proof_png(d / f"_pdfsrc_{idx:02d}.png", idx, seed)
    Image.open(d / f"_pdfsrc_{idx:02d}.png").save(pdf, "PDF")
    (d / f"_pdfsrc_{idx:02d}.png").unlink(missing_ok=True)

    hard_findings = cand["hard"]
    advisory = cand["advisory"]
    findings = []
    if hard_findings:
        findings.append({
            "rule": "COLOR_BUDGET", "severity": "hard", "layer": "A",
            "detail": f"rendered inks exceed max_colors=6 (by {hard_findings})",
        })
    for i in range(advisory):
        findings.append({
            "rule": ["PALETTE_MATCH", "NODE_WEIGHT", "MIN_STROKE",
                     "COVERAGE"][i % 4],
            "severity": "advisory", "layer": "A" if i % 2 else "B",
            "detail": "metric within tolerance; review before production",
        })
    manifest = {
        "input": {"kind": "svg", "file": cand["file"],
                  "spec": "spec.json"},
        "summary": {
            "hard": hard_findings, "advisory": advisory,
            "by_layer": {"A": hard_findings, "B": 0},
            "print_method": "screen_print",
        },
        "findings": findings,
        "stats": {
            "dpi": 300,
            "hard_findings": hard_findings,
            "advisory_findings": advisory,
            "rendered_distinct_colors": 5 + (idx % 4),
            "rendered_ink_colors": 3 + (idx % 3),
            "rendered_screens": 3 + (idx % 3),
            "ink_tac_max_percent": 240 + (idx * 7) % 60,
            "ink_tac_limit_percent": 300,
            "pdf_pages": 1,
            "pdf_page_size": [900, 900],
            "pdf_color_spaces": ["DeviceRGB"],
            "proof_path": proof.name,
            "pdf_path": pdf.name,
            "static": {
                "paths": 4 + (idx % 6),
                "path_nodes_total": 120 + idx * 37,
                "path_nodes_max": 40 + idx * 5,
                "paths_over_node_limit": 0,
                "color_count": 4 + (idx % 3),
                "palette_conformance": "partial" if cand["sweep"]["use_palette"] else "ok",
            },
        },
        "passed": cand["passed"],
        "proof": proof.name,
        "print_pdf": pdf.name,
    }
    (d / f"manifest_{idx:02d}.json").write_text(json.dumps(manifest, indent=2),
                                                 encoding="utf-8")
    with LOCK:
        val["manifest"] = manifest
        val["state"] = "done"
        val["log"] = [
            f"pipeline.sh 02_traced/{job['stem']}/{cand['file']}",
            "--- stage 1: Layer A (validate_svg.py) ---",
            f"Layer A: {cand['layer_a']['status']} ({hard_findings} hard)",
            "--- stage 2: Layer B (preflight.py) ---",
            f"Layer B: {cand['layer_b']['status']}",
            f"proof -> {proof.name}  print pdf -> {pdf.name}",
            f"manifest -> manifest_{idx:02d}.json",
        ]

JEV_ANSWERS = {
    "dominant_issue": {"choice": "color_budget", "confidence": 0.82},
    "next_action": {"choice": "reduce_color_complexity", "confidence": 0.74},
    "evidence_quality": {"choice": "useful", "confidence": 0.66},
    "human_visual_review": {"choice": "true", "confidence": 0.93},
}


def _guarded(fn, obj):
    """Run a job body, capturing any exception into state/error."""
    try:
        fn(obj)
    except Cancelled:
        with LOCK:
            obj["state"] = "cancelled"
            obj["error"] = "cancelled by operator"
    except Exception as exc:  # surface, never hang a job silently
        with LOCK:
            obj["state"] = "error"
            obj["error"] = f"{type(exc).__name__}: {exc}"
        import traceback
        traceback.print_exc(file=sys.stderr)

# ---------------------------------------------------------------- server

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # quiet
        pass

    def _json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _file(self, path: Path, download: str, attachment: bool = False) -> None:
        if not path.is_file():
            self._json(404, {"error": "not found"})
            return
        ctypes = {".svg": "image/svg+xml", ".png": "image/png",
                  ".pdf": "application/pdf", ".json": "application/json",
                  ".7z": "application/x-7z-compressed"}
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctypes.get(path.suffix,
                                                    "application/octet-stream"))
        self.send_header("Content-Length", str(len(data)))
        disposition = "attachment" if attachment else "inline"
        self.send_header("Content-Disposition",
                         f'{disposition}; filename="{download}"')
        self.end_headers()
        self.wfile.write(data)

    def _authed(self) -> bool:
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        parts = [p for p in self.path.split("/") if p]

        if self.path == "/health":
            self._json(200, {"ok": True, "host": "mock-runner",
                             "tools": {"inkscape": True, "gs": True},
                             "mode": "mock"})
            return

        if len(parts) >= 3 and parts[0] == "files":
            job = JOBS.get(parts[1])
            if not job:
                self._json(404, {"error": "no such job"})
                return
            name = "/".join(parts[2:])
            self._file(Path(job["dir"]) / name, name)
            return

        if len(parts) == 2 and parts[0] == "jobs":
            job = JOBS.get(parts[1])
            if not job:
                self._json(404, {"error": "no such job"})
                return
            with LOCK:
                payload = {
                    "id": job["id"],
                    "state": job["state"],
                    "log_tail": job["log"][-40:],
                    "prep_summary": job["prep_summary"],
                    "candidate_count": len(job["candidates"]),
                    "comparison": job["comparison"],
                    "error": job["error"],
                }
            self._json(200, payload)
            return

        if len(parts) == 3 and parts[0] == "jobs" and parts[2] == "candidates":
            job = JOBS.get(parts[1])
            if not job:
                self._json(404, {"error": "no such job"})
                return
            with LOCK:
                self._json(200, {"candidates": job["candidates"]})
            return

        if len(parts) == 3 and parts[0] == "jobs" and parts[2] == "archive":
            job = JOBS.get(parts[1])
            if not job:
                self._json(404, {"error": "no such job"})
                return
            if job["state"] != "done":
                self._json(409, {"error": f"job not done ({job['state']})"})
                return
            job_dir = Path(job["dir"])
            if not job_dir.is_dir():
                self._json(404, {"error": "job dir missing"})
                return
            if free_bytes(job_dir) < MIN_ARCHIVE_FREE:
                self._json(507, {"error": "insufficient disk to archive"})
                return
            archive = build_archive(job_dir, parts[1])
            if archive is None:
                self._json(500, {"error": "7z unavailable or failed"})
                return
            try:
                self._file(archive, f"{job.get('stem') or parts[1]}.7z", attachment=True)
            finally:
                archive.unlink(missing_ok=True)
            return

        if len(parts) == 2 and parts[0] == "validations":
            val = VALIDATIONS.get(parts[1])
            if not val:
                self._json(404, {"error": "no such validation"})
                return
            with LOCK:
                payload = {"id": val["id"], "state": val["state"],
                           "manifest": val["manifest"],
                           "log": val["log"], "error": val["error"]}
            self._json(200, payload)
            return

        self._json(404, {"error": "unknown route"})

    def do_POST(self):
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        parts = [p for p in self.path.split("/") if p]
        body = self._body()

        if self.path == "/jobs":
            job_id = uuid.uuid4().hex[:12]
            name = body.get("name") or "artwork"
            stem = slug(name)
            dirp = ROOT / job_id
            job = {
                "id": job_id, "stem": stem, "name": name,
                "dir": str(dirp), "state": "queued",
                "input_path": body.get("input_path", ""),
                "spec": body.get("spec") or {},
                "seed": seed_for(job_id + name),
                "log": [], "candidates": [], "comparison": None,
                "prep_summary": None, "error": None, "cancel": False,
            }
            with LOCK:
                JOBS[job_id] = job
            threading.Thread(target=_guarded, args=(run_front, job), daemon=True).start()
            self._json(202, {"id": job_id, "stem": stem})
            return

        if len(parts) == 3 and parts[0] == "jobs" and parts[2] == "cancel":
            job = JOBS.get(parts[1])
            if not job:
                self._json(404, {"error": "no such job"})
                return
            with LOCK:
                if job["state"] in ("queued", "running"):
                    job["cancel"] = True
                    self._json(200, {"state": "cancelling"})
                elif job["state"] == "cancelled":
                    self._json(200, {"state": "cancelled"})
                else:
                    self._json(409, {"state": job["state"]})
            return

        if self.path == "/validations":
            job_id = body.get("job_id")
            candidate_file = body.get("candidate_file")
            job = JOBS.get(job_id)
            if not job or job["state"] != "done":
                self._json(409, {"error": "job not ready"})
                return
            if not any(c["file"] == candidate_file for c in job["candidates"]):
                self._json(404, {"error": "no such candidate"})
                return
            val_id = uuid.uuid4().hex[:12]
            val = {"id": val_id, "job_id": job_id,
                   "candidate_file": candidate_file,
                   "state": "running", "manifest": None, "log": [],
                   "error": None}
            with LOCK:
                VALIDATIONS[val_id] = val
            threading.Thread(target=_guarded, args=(run_back, val), daemon=True).start()
            self._json(202, {"id": val_id})
            return

        if len(parts) == 3 and parts[0] == "validations" and parts[2] == "jev":
            val = VALIDATIONS.get(parts[1])
            if not val or val["state"] != "done":
                self._json(409, {"error": "validation not ready"})
                return
            time.sleep(0.4)  # 70-500ms typical; pad for demo visibility
            self._json(200, {
                "model": "jev-latest",
                "endpoint": "api.typesafe.ai/v1/systemone (mock)",
                "latency_ms": 412,
                "answers": json.loads(json.dumps(JEV_ANSWERS)),
            })
            return

        self._json(404, {"error": "unknown route"})

    def do_DELETE(self):
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return
        parts = [p for p in self.path.split("/") if p]
        if len(parts) == 2 and parts[0] == "jobs":
            job = JOBS.get(parts[1])
            if not job:
                self._json(404, {"error": "no such job"})
                return
            job_dir = Path(job["dir"])
            with LOCK:
                if job["state"] in ("queued", "running"):
                    job["cancel"] = True
                JOBS.pop(parts[1], None)
            if job_dir.is_dir():
                shutil.rmtree(job_dir, ignore_errors=True)
            self._json(200, {"deleted": parts[1]})
            return
        self._json(404, {"error": "unknown route"})


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    # Bind loopback by default. MOCK_BIND exists because a mock runner inside
    # a container is unreachable from the app in a sibling container: both
    # would each see their own 127.0.0.1, and the studio's file proxy fails
    # 502 on every artefact. Set MOCK_BIND=0.0.0.0 only on a trusted network.
    host = os.environ.get("MOCK_BIND", "127.0.0.1")
    server = ThreadingHTTPServer((host, PORT), Handler)
    print(f"mock runner on {host}:{PORT}, root={ROOT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
