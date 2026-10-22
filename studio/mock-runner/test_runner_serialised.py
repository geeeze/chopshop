"""Behavioural test for the serialised mock runner.

Run with the pipeline venv:

    ~/chopshop-svg/.venv/bin/python -m pytest -p no:cacheprovider mock-runner/test_runner_serialised.py

The server is started on an ephemeral loopback port with a single worker thread,
and driven over real HTTP with a deliberately tiny sweep so a job finishes in a
few seconds. The point is the CONTRACT of the queue, not load:

  * a second POST /jobs reports state "queued" while the first is "running"
  * cancelling a queued job settles it to "cancelled" without running it
  * cancelling a running job is cooperative ("cancelling" -> "cancelled")
"""
import importlib.util
import json
import os
import tempfile
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

HERE = Path(__file__).resolve().parent

# One tiny candidate, no pitch shift: the whole front pipeline is a few seconds.
TINY_SPEC = {
    "print": {
        "sweep": {
            "presets": ["bw"],
            "filter_speckle": [2],
            "hierarchical": ["cutout"],
            "max_candidates": 1,
        }
    }
}


def _request(base, path, method="GET", payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(base + path, data=data, headers=headers,
                                 method=method)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return resp.status, json.loads(resp.read())


def post(base, path, payload):
    return _request(base, path, method="POST", payload=payload)


def get(base, path):
    return _request(base, path)


def delete(base, path):
    return _request(base, path, method="DELETE")


def wait_for_state(base, job_id, state, timeout=5.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        _, body = get(base, f"/jobs/{job_id}")
        last = body["state"]
        if last == state:
            return last
        time.sleep(0.05)
    return last


@pytest.fixture(scope="module")
def runner():
    tmp = tempfile.TemporaryDirectory()
    os.environ["MOCK_ROOT"] = tmp.name
    os.environ.pop("MOCK_TOKEN", None)

    spec = importlib.util.spec_from_file_location(
        "runner_serialised", HERE / "runner_serialised.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    server = ThreadingHTTPServer(("127.0.0.1", 0), mod.Handler)
    base = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # A single worker: exactly what main() starts on the deployed box.
    threading.Thread(target=mod.worker_loop, daemon=True).start()
    try:
        yield base, mod
    finally:
        server.shutdown()
        tmp.cleanup()


def submit(base, name):
    _, body = post(base, "/jobs", {"name": name, "input_path": "/data/x.png",
                                   "spec": TINY_SPEC})
    return body["id"]


def test_second_job_is_queued_while_the_first_runs(runner):
    base, _mod = runner
    first = submit(base, "serial-alpha")
    assert wait_for_state(base, first, "running") == "running"

    second = submit(base, "serial-beta")
    _, beta = get(base, f"/jobs/{second}")
    assert beta["state"] == "queued", beta

    _, alpha = get(base, f"/jobs/{first}")
    assert alpha["state"] == "running", "the first must still be the one running"

    post(base, f"/jobs/{first}/cancel", {})
    post(base, f"/jobs/{second}/cancel", {})
    delete(base, f"/jobs/{first}")
    delete(base, f"/jobs/{second}")


def test_cancelling_a_queued_job_settles_it_without_running(runner):
    base, _mod = runner
    first = submit(base, "queue-alpha")
    assert wait_for_state(base, first, "running") == "running"

    second = submit(base, "queue-beta")
    assert get(base, f"/jobs/{second}")[1]["state"] == "queued"

    status, cancel = post(base, f"/jobs/{second}/cancel", {})
    assert status == 200
    assert cancel["state"] == "cancelled"

    time.sleep(0.5)  # give the worker time to reach the tombstone
    _, beta = get(base, f"/jobs/{second}")
    assert beta["state"] == "cancelled"
    assert beta["candidate_count"] == 0, "a queued job must never produce candidates"

    post(base, f"/jobs/{first}/cancel", {})
    delete(base, f"/jobs/{first}")
    delete(base, f"/jobs/{second}")


def test_cancelling_a_running_job_is_cooperative(runner):
    base, _mod = runner
    job = submit(base, "coop-alpha")
    assert wait_for_state(base, job, "running") == "running"

    status, cancel = post(base, f"/jobs/{job}/cancel", {})
    assert status == 200
    assert cancel["state"] == "cancelling"

    assert wait_for_state(base, job, "cancelled") == "cancelled"
    _, done = get(base, f"/jobs/{job}")
    assert done["error"] == "cancelled by operator"
    delete(base, f"/jobs/{job}")


def test_health_is_available_and_reports_mock(runner):
    base, _mod = runner
    status, health = get(base, "/health")
    assert status == 200
    assert health["ok"] is True
    assert health["mode"] == "mock"
