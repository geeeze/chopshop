"""The client contract, with the network seam stubbed.

``_urlopen`` is the only method that touches the network — ``_post``,
``_get_json`` and ``_get_bytes`` all go through it — so stubbing it covers the
client exactly, retry included. No service, no GPU, no models.
"""

import errno
import json
import socket
import urllib.error

import pytest

from chopshop_flux import client as client_module
from chopshop_flux.client import (FluxClient, FluxError, _is_refused,
                                  default_base_url, image_data_url,
                                  pipeline_argv)


def _refused():
    """The error urllib raises when nothing is listening.

    Built the way urllib builds it — the socket error wrapped as the ``reason``
    of a ``URLError`` — because that wrapping is exactly what a naive
    ``except ConnectionRefusedError`` would miss.
    """
    return urllib.error.URLError(
        socket.error(errno.ECONNREFUSED, "Connection refused"))


class FakeResponse:
    """Just enough of a urlopen result for `with ... as resp` to work."""

    def __init__(self, body=b"{}"):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _no_sleep(monkeypatch):
    """Record the backoff instead of spending it."""
    slept = []
    monkeypatch.setattr(client_module.time, "sleep", slept.append)
    return slept


class RecordingClient(FluxClient):
    """A client whose network seams record instead of connecting."""

    def __init__(self, *args, post_response=None, get_bytes=b"BYTES", **kwargs):
        super().__init__(*args, **kwargs)
        self.posts = []
        self.gets = []
        self._post_response = post_response if post_response is not None else {}
        self._get_bytes_value = get_bytes

    def _post(self, route, payload):
        self.posts.append((route, payload))
        return self._post_response

    def _get_bytes(self, path):
        self.gets.append(path)
        return self._get_bytes_value


# -- request shaping -------------------------------------------------------

def test_generate_sends_only_the_fields_it_was_given():
    client = RecordingClient()
    client.generate("a phoenix emblem", width=512, height=512, seed=1)
    route, payload = client.posts[-1]
    assert route == "/generate"
    assert payload["prompt"] == "a phoenix emblem"
    assert payload["width"] == 512
    assert payload["seed"] == 1
    # An unset knob must be absent, not null: the service owns its defaults.
    assert "guidance" not in payload
    assert "model" not in payload


def test_generate_forwards_a_negative_prompt_and_strength():
    client = RecordingClient()
    client.generate("x", negative_prompt="blurry", strength=0.6)
    _, payload = client.posts[-1]
    assert payload["negative_prompt"] == "blurry"
    assert payload["strength"] == 0.6


def test_unset_negative_prompt_and_strength_stay_out_of_the_request():
    client = RecordingClient()
    client.generate("x", negative_prompt=None, strength=None)
    _, payload = client.posts[-1]
    assert "negative_prompt" not in payload
    assert "strength" not in payload


def test_edit_sends_a_data_url_for_the_reference(tmp_path):
    source = tmp_path / "src.png"
    source.write_bytes(b"reference-bytes")
    client = RecordingClient()
    client.edit(str(source), "flatten to 6 colours", width=512, height=512)
    route, payload = client.posts[-1]
    assert route == "/edit"
    assert payload["image"].startswith("data:image/png;base64,")


def test_edit_sends_a_list_of_data_urls_for_several_references(tmp_path):
    first = tmp_path / "pose.png"
    second = tmp_path / "palette.png"
    first.write_bytes(b"pose-bytes")
    second.write_bytes(b"palette-bytes")
    client = RecordingClient()
    client.edit([str(first), str(second)], "pose from the first, palette from the second")
    route, payload = client.posts[-1]
    assert route == "/edit"
    assert isinstance(payload["image"], list) and len(payload["image"]) == 2
    # Order is the caller's meaning, so it is what gets asserted.
    import base64
    assert payload["image"][0].endswith(base64.b64encode(b"pose-bytes").decode())
    assert payload["image"][1].endswith(base64.b64encode(b"palette-bytes").decode())


def test_edit_with_no_references_is_a_client_error_not_an_empty_request(tmp_path):
    client = RecordingClient()
    with pytest.raises(FluxError):
        client.edit([], "x")
    assert client.posts == []


def test_unload_posts_to_unload():
    client = RecordingClient()
    client.unload()
    assert client.posts[-1][0] == "/unload"


def test_download_writes_the_bytes_to_disk(tmp_path):
    client = RecordingClient(get_bytes=b"\x89PNG\x00payload")
    path = client.download("image-01.png", str(tmp_path / "out"))
    assert path.endswith("image-01.png")
    assert open(path, "rb").read() == b"\x89PNG\x00payload"
    assert client.gets == ["/files/image-01.png"]


def test_download_fetches_before_it_truncates_the_target(tmp_path):
    """The download directory may be the directory the service serves from.

    `open(target, "wb")` truncates immediately, so fetching inside that
    with-block zeroed the source file before the fetch ran. The client then
    stored the empty body the service sent back — 0 bytes, reported as success.
    """
    existing = tmp_path / "image-01.png"
    existing.write_bytes(b"PNG-BYTES")

    class ServerReadsSameTree(RecordingClient):
        """Stands in for the service reading from the very same directory."""

        def _get_bytes(self, path):
            self.gets.append(path)
            return existing.read_bytes()

    client = ServerReadsSameTree()
    path = client.download(existing.name, str(tmp_path))
    assert open(path, "rb").read() == b"PNG-BYTES"


def test_download_strips_any_directory_from_the_name(tmp_path):
    """A name from the network must not write outside the output directory."""
    client = RecordingClient(get_bytes=b"x")
    path = client.download("../../etc/passwd", str(tmp_path / "out"))
    assert path.endswith("/passwd")
    assert "etc" not in path.split(str(tmp_path))[1]
    assert client.gets == ["/files/passwd"]


# -- error mapping ---------------------------------------------------------

def _http_error(code):
    return urllib.error.HTTPError("http://x/y", code, "boom", {}, None)


def test_a_4xx_is_a_usage_error_not_a_generation_failure(monkeypatch):
    client = RecordingClient()

    def boom(route, payload):
        raise FluxError("bad request", exit_code=2)

    client._post = boom
    with pytest.raises(FluxError) as caught:
        client.generate("x")
    assert caught.value.exit_code == 2


def test_an_unreachable_service_is_exit_3(monkeypatch):
    # One attempt: this test is about the MESSAGE and the exit code, not the
    # retry. The retry gets its own tests below, with the sleeping stubbed out.
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "1")
    client = FluxClient("http://127.0.0.1:1")

    def boom(req, timeout=None):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(client_module.urllib.request, "urlopen", boom)
    with pytest.raises(FluxError) as caught:
        client.health()
    assert caught.value.exit_code == 3
    assert "cannot reach" in str(caught.value)


def test_a_4xx_body_message_is_surfaced(monkeypatch):
    """The service's own sentence is more useful than the status code."""
    import io

    body = json.dumps({"error": "width must be a multiple of 16, got 1000"}).encode()
    err = urllib.error.HTTPError("http://x/generate", 400, "bad", {},
                                io.BytesIO(body))
    client = FluxClient("http://x")
    monkeypatch.setattr(client_module.urllib.request, "urlopen",
                        lambda req, timeout=None: (_ for _ in ()).throw(err))
    with pytest.raises(FluxError) as caught:
        client.generate("x", width=1000)
    assert "multiple of 16" in str(caught.value)
    assert caught.value.exit_code == 2
    assert "HTTP 400" in str(caught.value)


def test_a_5xx_is_a_generation_failure():
    assert FluxClient._http_exit(_http_error(500)) == 5
    assert FluxClient._http_exit(_http_error(400)) == 2
    assert FluxClient._http_exit(_http_error(404)) == 2


# -- base url --------------------------------------------------------------

def test_the_base_url_comes_from_the_environment(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_URL", "http://gpu-box:8795/")
    assert default_base_url() == "http://gpu-box:8795"


def test_the_default_base_url_is_the_configured_loopback(monkeypatch):
    """Not a literal host: the default is "the service as this box would run it"."""
    monkeypatch.delenv("CHOPSHOP_FLUX_URL", raising=False)
    monkeypatch.setenv("CHOPSHOP_FLUX_BIND", "127.0.0.1")
    monkeypatch.setenv("CHOPSHOP_FLUX_PORT", "9001")
    assert default_base_url() == "http://127.0.0.1:9001"


# -- image encoding --------------------------------------------------------

def test_image_data_url_reports_the_extension_it_cannot_handle(tmp_path):
    path = tmp_path / "art.tiff"
    path.write_bytes(b"x")
    with pytest.raises(FluxError) as caught:
        image_data_url(str(path))
    assert ".tiff" in str(caught.value)
    assert caught.value.exit_code == 2


def test_image_data_url_encodes_a_png(tmp_path):
    path = tmp_path / "art.png"
    path.write_bytes(b"\x89PNG")
    assert image_data_url(str(path)) == "data:image/png;base64,iVBORw=="


# -- the pipeline seam -----------------------------------------------------

def test_the_sweep_is_passed_in_the_equals_form(monkeypatch, tmp_path):
    """front_pipeline.sh parses only `--sweep=FILE`.

    The two-token form hits its `unknown option` path and the sweep is silently
    not applied. chopshop-sui shipped this bug once; this pins it.
    """
    monkeypatch.setenv("CHOPSHOP_FLUX_PIPELINE", str(tmp_path))
    (tmp_path / "front_pipeline.sh").write_text("#!/bin/sh\n")
    argv = pipeline_argv("raster.png", sweep=str(tmp_path / "sweep.json"))
    assert "--sweep=%s" % (tmp_path / "sweep.json") in argv
    # Never as two argv entries.
    assert "--sweep" not in argv


def test_skip_prep_is_passed_through(monkeypatch, tmp_path):
    monkeypatch.setenv("CHOPSHOP_FLUX_PIPELINE", str(tmp_path))
    (tmp_path / "front_pipeline.sh").write_text("#!/bin/sh\n")
    assert "--skip-prep" in pipeline_argv("raster.png", skip_prep=True)


def test_the_handoff_refuses_without_a_configured_pipeline(monkeypatch):
    """Guessing where the pipeline lives is how you trace the wrong tree."""
    monkeypatch.delenv("CHOPSHOP_FLUX_PIPELINE", raising=False)
    with pytest.raises(FluxError) as caught:
        pipeline_argv("raster.png")
    assert "CHOPSHOP_FLUX_PIPELINE" in str(caught.value)
    assert caught.value.exit_code == 2


def test_the_handoff_refuses_a_directory_with_no_pipeline_in_it(monkeypatch, tmp_path):
    monkeypatch.setenv("CHOPSHOP_FLUX_PIPELINE", str(tmp_path))
    with pytest.raises(FluxError) as caught:
        pipeline_argv("raster.png")
    assert "front_pipeline.sh" in str(caught.value)


# -- the restart window (#flux-idle-restart) -------------------------------
#
# The service's idle path ends the process on purpose when an unload did not
# return the memory, and the unit restarts it a few seconds later. A step that
# posts in that window gets a refused TCP connect. These tests are the claim
# that such a step no longer fails: the request is retried, and if the service
# really is gone the failure says RESTARTING rather than reading as a generation
# error.


def test_a_refused_connect_is_recognised_through_urllib_wrapping():
    assert _is_refused(_refused())
    assert _is_refused(ConnectionRefusedError())
    # A bare OSError carrying the errno, which is what some platforms raise.
    assert _is_refused(OSError(errno.ECONNREFUSED, "Connection refused"))


def test_a_timeout_is_not_mistaken_for_a_refusal():
    """A timeout may mean the generation IS running; retrying it would double
    the job. Only a refusal is safe to repeat, because nothing was started."""
    assert not _is_refused(urllib.error.URLError(socket.timeout("timed out")))
    assert not _is_refused(urllib.error.URLError(socket.gaierror("no host")))
    assert not _is_refused(OSError(errno.ECONNRESET, "Connection reset"))


def test_a_step_that_lands_in_the_restart_window_succeeds(monkeypatch):
    """The whole point: two refusals, then the service answers.

    The step must return the service's real answer — the retry is invisible to
    the caller, not a swallowed error or an empty result.
    """
    _no_sleep(monkeypatch)
    attempts = []
    body = json.dumps({"images": [{"name": "image-01.png"}]}).encode()

    def flaky(req, timeout=None):
        attempts.append(1)
        if len(attempts) < 3:
            raise _refused()
        return FakeResponse(body)

    monkeypatch.setattr(client_module.urllib.request, "urlopen", flaky)
    payload = FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 3
    assert payload["images"][0]["name"] == "image-01.png"


def test_the_backoff_grows_linearly_between_attempts(monkeypatch):
    """Not exponential: the window is bounded and short, so a long sleep only
    eats the caller's own timeout budget."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "4")
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_BACKOFF", "2")
    slept = _no_sleep(monkeypatch)
    attempts = []

    def always_refused(req, timeout=None):
        attempts.append(1)
        raise _refused()

    monkeypatch.setattr(client_module.urllib.request, "urlopen", always_refused)
    with pytest.raises(FluxError):
        FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 4, "the first try plus three retries"
    assert slept == [2.0, 4.0, 6.0]


def test_a_persistent_refusal_says_RESTARTING_not_generation_failed(monkeypatch):
    """The distinction a chained job needs, and the one the issue asked for.

    Eight green steps and one step that arrived during a five-second restart is
    not a generation failure. So the exit code stays 3 (unreachable) rather
    than 5, `restarting` is set, and the message says what happened.
    """
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "2")
    _no_sleep(monkeypatch)

    def always_refused(req, timeout=None):
        raise _refused()

    monkeypatch.setattr(client_module.urllib.request, "urlopen", always_refused)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("a phoenix")
    error = caught.value
    assert error.exit_code == 3, "unreachable, NOT the repo's generation-failed 5"
    assert error.restarting is True
    assert "RESTARTING" in str(error)
    assert "CHOPSHOP_FLUX_RECONNECT_ATTEMPTS" in str(error), \
        "the message must name the knob that widens the window"


def test_a_service_that_was_never_there_is_not_reported_as_restarting(monkeypatch):
    """A first-ever refusal with no retry budget is plain unreachability.

    Claiming "restarting" for a service that was never up would be a nicer lie
    than the old one, and the start hint is more useful than a guess.
    """
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "1")
    _no_sleep(monkeypatch)

    def always_refused(req, timeout=None):
        raise _refused()

    monkeypatch.setattr(client_module.urllib.request, "urlopen", always_refused)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("a phoenix")
    assert caught.value.restarting is False
    assert "cannot reach" in str(caught.value)
    assert "python -m chopshop_flux serve" in str(caught.value)


def test_a_dns_failure_is_not_retried(monkeypatch):
    """Only a refusal is the service's own restart. A name that does not
    resolve is the caller's, and retrying it just delays the same error."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "4")
    _no_sleep(monkeypatch)
    attempts = []

    def no_such_host(req, timeout=None):
        attempts.append(1)
        raise urllib.error.URLError(socket.gaierror("Name or service not known"))

    monkeypatch.setattr(client_module.urllib.request, "urlopen", no_such_host)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 1
    assert caught.value.restarting is False


def test_a_service_error_response_is_never_retried(monkeypatch):
    """A 500 is an answer. Retrying it would run the generation again, and the
    caller is entitled to see the failure rather than a second attempt at it."""
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "4")
    _no_sleep(monkeypatch)
    attempts = []

    def boom(req, timeout=None):
        attempts.append(1)
        raise _http_error(500)

    monkeypatch.setattr(client_module.urllib.request, "urlopen", boom)
    with pytest.raises(FluxError) as caught:
        FluxClient("http://x").generate("a phoenix")
    assert len(attempts) == 1
    assert caught.value.exit_code == 5


def test_the_retry_knobs_read_their_environment(monkeypatch):
    from chopshop_flux import config

    monkeypatch.delenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", raising=False)
    monkeypatch.delenv("CHOPSHOP_FLUX_RECONNECT_BACKOFF", raising=False)
    assert config.reconnect_attempts() == 4
    assert config.reconnect_backoff() == 2.0
    # 4 attempts at 2s linear = 2+4+6 = 12s of window, against a measured ~5s
    # restart. The default has to clear the window it was made for.
    assert config.reconnect_backoff() * 6 > 5.0
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_ATTEMPTS", "1")
    monkeypatch.setenv("CHOPSHOP_FLUX_RECONNECT_BACKOFF", "0")
    assert config.reconnect_attempts() == 1
    assert config.reconnect_backoff() == 0.0


def test_a_download_also_rides_out_the_restart(monkeypatch, tmp_path):
    """The download is a separate call and it has the same window: the service
    can exit between generating a frame and the client fetching it."""
    _no_sleep(monkeypatch)
    attempts = []

    def flaky(req, timeout=None):
        attempts.append(1)
        if len(attempts) < 2:
            raise _refused()
        return FakeResponse(b"PNGBYTES")

    monkeypatch.setattr(client_module.urllib.request, "urlopen", flaky)
    client = FluxClient("http://x")
    path = client.download("image-01.png", str(tmp_path))
    assert open(path, "rb").read() == b"PNGBYTES"
    assert len(attempts) == 2
