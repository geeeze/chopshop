"""The novita remote backend: config and the HTTP client.

The network is touched in exactly one place per call type — ``_post_json`` and
``_post_multipart`` — so tests stub ``urllib.request.urlopen`` and the entire
client contract is exercised with no network.
"""

import base64
import io
import json
import urllib.error

import pytest

from chopshop_flux import config
from chopshop_flux import remote as remote_module
from chopshop_flux.remote import NovitaClient, RemoteError


def _ok_response(body):
    class FakeResponse:
        def __init__(self, body):
            self._body = body

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    return FakeResponse(body)


def _http_error(code, body=None):
    if body is None:
        body = b"{}"
    return urllib.error.HTTPError("http://x/y", code, "err", {}, io.BytesIO(body))


class Capture:
    """A urlopen stand-in that records requests and returns a fixed response."""

    def __init__(self, response_body):
        self.requests = []
        self._body = response_body

    def __call__(self, req, timeout=None):
        self.requests.append(req)
        return _ok_response(self._body)


def _generations_body(png_bytes=b"PNGDATA"):
    return json.dumps(
        {"data": [{"b64_json": base64.b64encode(png_bytes).decode()}]}
    ).encode()


# -- config ----------------------------------------------------------------


def test_novita_api_key_defaults_to_none(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_NOVITA_API_KEY", raising=False)
    assert config.novita_api_key() is None


def test_novita_api_key_reads_the_environment(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_API_KEY", "sk-test-123")
    assert config.novita_api_key() == "sk-test-123"


def test_novita_base_url_defaults_to_the_vendor(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_NOVITA_BASE_URL", raising=False)
    assert config.novita_base_url() == "https://api.novita.ai/openai/v1"


def test_novita_base_url_reads_the_environment(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_BASE_URL",
                       "https://proxy.example.com/v1/")
    # Trailing slash is stripped so callers can concatenate paths safely.
    assert config.novita_base_url() == "https://proxy.example.com/v1"


def test_novita_timeout_defaults_and_reads_env(monkeypatch):
    monkeypatch.delenv("CHOPSHOP_FLUX_NOVITA_TIMEOUT", raising=False)
    assert config.novita_timeout() == 120.0
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_TIMEOUT", "30")
    assert config.novita_timeout() == 30.0


def test_novita_user_agent_defaults_to_the_service_name(monkeypatch):
    """The default UA must start with the service name.

    Cloudflare 403s urllib's default UA; any non-empty UA works, but the
    default must be identifiable as this service so a vendor log can tell
    whose traffic it is.
    """
    monkeypatch.delenv("CHOPSHOP_FLUX_NOVITA_USER_AGENT", raising=False)
    assert config.novita_user_agent().startswith(config.SERVICE_NAME)


def test_novita_user_agent_reads_the_environment(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_USER_AGENT", "my-agent/1.0")
    assert config.novita_user_agent() == "my-agent/1.0"


# -- client construction ----------------------------------------------------


def test_client_reads_config_for_its_defaults(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_API_KEY", "sk-env")
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_BASE_URL", "https://env.example/v1")
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_TIMEOUT", "45")
    client = NovitaClient()
    assert client.api_key == "sk-env"
    assert client.base_url == "https://env.example/v1"
    assert client.timeout == 45.0


def test_client_explicit_arguments_override_config(monkeypatch):
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_API_KEY", "sk-env")
    client = NovitaClient(api_key="sk-explicit",
                          base_url="https://x.example/v1/", timeout=10)
    assert client.api_key == "sk-explicit"
    assert client.base_url == "https://x.example/v1"
    assert client.timeout == 10.0


def test_client_refuses_without_an_api_key(monkeypatch):
    """No key means every request would be a 401; say so before the first one."""
    monkeypatch.delenv("CHOPSHOP_FLUX_NOVITA_API_KEY", raising=False)
    client = NovitaClient()
    with pytest.raises(RemoteError) as caught:
        client.generate("x", model="ming-image-0.1-design")
    assert "api_key" in str(caught.value).lower() or "key" in str(caught.value).lower()


# -- headers ----------------------------------------------------------------


def test_headers_carry_a_user_agent(monkeypatch):
    """The Cloudflare 403 fix: a non-empty UA is mandatory."""
    monkeypatch.setenv("CHOPSHOP_FLUX_NOVITA_USER_AGENT", "test-agent/1.0")
    cap = Capture(_generations_body())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    NovitaClient(api_key="sk-test").generate("x", model="ming-image-0.1-design")
    req = cap.requests[0]
    assert req.get_header("User-agent") == "test-agent/1.0"


def test_headers_carry_the_bearer_token(monkeypatch):
    cap = Capture(_generations_body())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    NovitaClient(api_key="sk-test").generate("x", model="ming-image-0.1-design")
    req = cap.requests[0]
    assert req.get_header("Authorization") == "Bearer sk-test"


# -- generate ---------------------------------------------------------------


def test_generate_posts_to_the_generations_endpoint(monkeypatch):
    cap = Capture(_generations_body())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test",
                          base_url="https://api.novita.ai/openai/v1")
    result = client.generate("a phoenix", model="ming-image-0.1-design")
    req = cap.requests[0]
    assert req.full_url == "https://api.novita.ai/openai/v1/images/generations"
    assert result[0].png == b"PNGDATA"


def test_generate_sends_the_verified_json_body(monkeypatch):
    cap = Capture(_generations_body())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    client.generate("a phoenix", model="ming-image-0.1-design",
                    size="1024x1024", output_format="png", watermark=False)
    body = json.loads(cap.requests[0].data.decode("utf-8"))
    assert body["model"] == "ming-image-0.1-design"
    assert body["prompt"] == "a phoenix"
    assert body["size"] == "1024x1024"
    assert body["output_format"] == "png"
    assert body["response_format"] == "b64_json"
    assert body["watermark"] is False


def test_generate_decodes_multiple_images(monkeypatch):
    imgs = [{"b64_json": base64.b64encode(b"PNG1").decode()},
            {"b64_json": base64.b64encode(b"PNG2").decode()}]
    cap = Capture(json.dumps({"data": imgs}).encode())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    result = client.generate("x", model="ming-image-0.1-design")
    assert [r.png for r in result] == [b"PNG1", b"PNG2"]


def test_generate_raises_on_http_error(monkeypatch):
    def fake_urlopen(req, timeout=None):
        raise _http_error(400, json.dumps({"error": "bad prompt"}).encode())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", fake_urlopen)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError) as caught:
        client.generate("x", model="ming-image-0.1-design")
    assert caught.value.status == 400


def test_generate_sends_the_timeout(monkeypatch):
    seen = []

    def rec(req, timeout=None):
        seen.append(timeout)
        return _ok_response(_generations_body())

    monkeypatch.setattr(remote_module.urllib.request, "urlopen", rec)
    client = NovitaClient(api_key="sk-test", timeout=99.0)
    client.generate("x", model="ming-image-0.1-design")
    assert seen == [99.0]


# -- edit -------------------------------------------------------------------


def test_edit_posts_multipart_to_the_edits_endpoint(monkeypatch):
    revised = {"canvas": [1024, 1024], "regions": []}
    body = json.dumps({"data": [{"b64_json": base64.b64encode(b"PNGDATA").decode(),
                                 "revised_prompt": json.dumps(revised)}]}).encode()
    cap = Capture(body)
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test",
                          base_url="https://api.novita.ai/openai/v1")
    result = client.edit("flatten", image=b"SOURCEPNG",
                         model="ming-image-0.1-design-layer")
    req = cap.requests[0]
    assert req.full_url == "https://api.novita.ai/openai/v1/images/edits"
    assert result[0].png == b"PNGDATA"


def test_edit_sends_the_image_in_the_image_array_field(monkeypatch):
    cap = Capture(_generations_body())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    client.edit("flatten", image=b"SOURCEPNG", model="ming-image-0.1-design-layer")
    req = cap.requests[0]
    raw = req.data
    assert "multipart/form-data" in req.get_header("Content-type")

    # Parse the multipart body: split on the boundary from the Content-Type
    # header and assert the file part's headers and body separately.
    content_type = req.get_header("Content-type")
    boundary = content_type.split("boundary=")[1].strip()
    parts = raw.split(("--%s" % boundary).encode())
    # parts[0] is empty (before the first boundary), parts[-1] is the closing
    # boundary; the middle parts are the form fields and the file.
    file_parts = [p for p in parts if b'name="image[]"' in p]
    assert len(file_parts) == 1
    file_part = file_parts[0]
    # The file part has headers, a blank line, then the raw bytes.
    header_block, _, body = file_part.partition(b"\r\n\r\n")
    assert b'Content-Disposition: form-data; name="image[]"; filename="source.png"' in header_block
    assert b"Content-Type: application/octet-stream" in header_block
    assert body.rstrip(b"\r\n") == b"SOURCEPNG"


def test_edit_parses_the_revised_prompt(monkeypatch):
    revised = {"canvas": [1024, 1024],
               "regions": [{"category": "background", "bbox": [0, 0, 1024, 512]}]}
    body = json.dumps({"data": [{"b64_json": base64.b64encode(b"PNG").decode(),
                                 "revised_prompt": json.dumps(revised)}]}).encode()
    cap = Capture(body)
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    result = client.edit("flatten", image=b"SRC",
                         model="ming-image-0.1-design-layer")
    assert result[0].revised_prompt == revised


def test_edit_without_revised_prompt_gives_none(monkeypatch):
    body = json.dumps({"data": [{"b64_json": base64.b64encode(b"PNG").decode()}]}).encode()
    cap = Capture(body)
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    result = client.edit("flatten", image=b"SRC",
                         model="ming-image-0.1-design-layer")
    assert result[0].revised_prompt is None


def test_edit_raises_on_http_error(monkeypatch):
    def fake_urlopen(req, timeout=None):
        raise _http_error(422, json.dumps({"error": "image too large"}).encode())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", fake_urlopen)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError) as caught:
        client.edit("flatten", image=b"SRC", model="ming-image-0.1-design-layer")
    assert caught.value.status == 422


# -- uncovered error paths (M3) -----------------------------------------------


def test_generate_raises_on_url_error(monkeypatch):
    """A URLError (DNS failure, connection refused, etc.) must raise RemoteError."""
    def fake_urlopen(req, timeout=None):
        raise urllib.error.URLError("connection refused")
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", fake_urlopen)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError):
        client.generate("x", model="ming-image-0.1-design")


def test_edit_raises_on_url_error(monkeypatch):
    """Same for the multipart path."""
    def fake_urlopen(req, timeout=None):
        raise urllib.error.URLError("connection refused")
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", fake_urlopen)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError):
        client.edit("flatten", image=b"SRC", model="ming-image-0.1-design-layer")


def test_generate_raises_on_missing_data_key(monkeypatch):
    """A response with no 'data' key must raise RemoteError."""
    cap = Capture(json.dumps({"unexpected": "shape"}).encode())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError, match="no 'data'"):
        client.generate("x", model="ming-image-0.1-design")


def test_edit_raises_on_missing_data_key(monkeypatch):
    cap = Capture(json.dumps({"unexpected": "shape"}).encode())
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError, match="no 'data'"):
        client.edit("flatten", image=b"SRC", model="ming-image-0.1-design-layer")


def test_generate_raises_on_missing_b64_json(monkeypatch):
    """A data item with no 'b64_json' key must raise RemoteError."""
    body = json.dumps({"data": [{"url": "https://example.com/x.png"}]}).encode()
    cap = Capture(body)
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError, match="b64_json"):
        client.generate("x", model="ming-image-0.1-design")


def test_edit_raises_on_missing_b64_json(monkeypatch):
    body = json.dumps({"data": [{"url": "https://example.com/x.png"}]}).encode()
    cap = Capture(body)
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError, match="b64_json"):
        client.edit("flatten", image=b"SRC", model="ming-image-0.1-design-layer")


def test_generate_raises_on_malformed_revised_prompt(monkeypatch):
    """A revised_prompt string that fails json.loads must raise RemoteError (I4)."""
    body = json.dumps({"data": [{"b64_json": base64.b64encode(b"PNG").decode(),
                                 "revised_prompt": "not valid json {"}]}).encode()
    cap = Capture(body)
    monkeypatch.setattr(remote_module.urllib.request, "urlopen", cap)
    client = NovitaClient(api_key="sk-test")
    with pytest.raises(RemoteError, match="malformed revised_prompt"):
        client.generate("x", model="ming-image-0.1-design")
