"""The client contract, with the two network seams stubbed.

``_post`` and ``_get_bytes`` are the only methods that touch the network, so
stubbing those two covers the client exactly. No service, no GPU, no models.
"""

import json
import urllib.error

import pytest

from chopshop_flux import client as client_module
from chopshop_flux.client import (FluxClient, FluxError, default_base_url,
                                  image_data_url, pipeline_argv)


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


def test_edit_sends_a_data_url_for_the_reference(tmp_path):
    source = tmp_path / "src.png"
    source.write_bytes(b"reference-bytes")
    client = RecordingClient()
    client.edit(str(source), "flatten to 6 colours", width=512, height=512)
    route, payload = client.posts[-1]
    assert route == "/edit"
    assert payload["image"].startswith("data:image/png;base64,")


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
