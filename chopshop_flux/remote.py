"""A stdlib-only HTTP client for the novita remote backend.

Standard library only (urllib, json, base64) — no requests, no third-party
dependencies.  The network is touched in exactly two places: ``_post_json``
(for the generations endpoint) and ``_post_multipart`` (for the edits
endpoint).  That shape mirrors the local client's single-seam design so tests
stub ``urllib.request.urlopen`` and the entire contract is exercised with no
network.

Two endpoints are supported:

* ``POST {base}/images/generations`` — JSON body, returns
  ``{"data": [{"b64_json": "<base64 png>"}]}``.
* ``POST {base}/images/edits`` — multipart/form-data with field ``image[]``
  (exactly 1 file), returns N pngs in ``data[]`` with
  ``data[i].revised_prompt`` = JSON ``{"canvas":[w,h],"regions":[...]}``.

CRITICAL: api.novita.ai is behind Cloudflare and returns HTTP 403 for
urllib's default User-Agent.  Any non-empty UA works; the client always sets
one.
"""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
import uuid

from . import config


class RemoteError(Exception):
    """A remote-backend failure: HTTP error, missing key, or bad response."""

    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


class RemoteImage:
    """One image returned by the remote backend."""

    def __init__(self, png: bytes, revised_prompt: dict | None = None):
        self.png = png
        self.revised_prompt = revised_prompt


class NovitaClient:
    """Client for the novita hosted image API.

    Reads its defaults from the environment at construction time (via
    config), so a test or long-lived service can change the environment and
    get the new value without reloading the module.
    """

    def __init__(self, api_key: str | None = None,
                 base_url: str | None = None,
                 timeout: float | None = None):
        self.api_key = api_key if api_key is not None else config.novita_api_key()
        self.base_url = (base_url if base_url is not None
                         else config.novita_base_url()).rstrip("/")
        self.timeout = timeout if timeout is not None else config.novita_timeout()

    # -- the network seams ---------------------------------------------------

    def _headers(self) -> dict:
        """Headers sent with every request.

        The User-Agent is mandatory: Cloudflare returns 403 for urllib's
        default ``Python-urllib/3.x``.  Any non-empty UA works.
        """
        return {
            "Authorization": "Bearer %s" % self.api_key,
            "User-Agent": config.novita_user_agent(),
        }

    def _post_json(self, path: str, payload: dict) -> dict:
        """POST a JSON body and return the parsed response."""
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            self.base_url + path, data=data,
            headers={**self._headers(), "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = self._read_body(exc)
            message = "HTTP %d from the remote backend" % exc.code
            if isinstance(body, dict) and body.get("error"):
                message = "%s: %s" % (message, body["error"])
            raise RemoteError(message, status=exc.code) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise RemoteError("cannot reach the remote backend at %s (%s)"
                              % (self.base_url, exc)) from exc

    def _post_multipart(self, path: str, fields: dict,
                        file_field: str, file_data: bytes,
                        file_name: str) -> dict:
        """POST multipart/form-data and return the parsed response."""
        boundary = "----chopshop-flux-%s" % uuid.uuid4().hex
        lines = []
        for name, value in fields.items():
            lines.append("--%s" % boundary)
            lines.append('Content-Disposition: form-data; name="%s"' % name)
            lines.append("")
            lines.append(value)
        lines.append("--%s" % boundary)
        lines.append('Content-Disposition: form-data; name="%s"; filename="%s"'
                     % (file_field, file_name))
        lines.append("Content-Type: application/octet-stream")
        lines.append("")
        lines.append("")
        body = "\r\n".join(lines).encode("utf-8") + file_data + \
            ("\r\n--%s--\r\n" % boundary).encode("utf-8")
        headers = self._headers()
        headers["Content-Type"] = "multipart/form-data; boundary=%s" % boundary
        req = urllib.request.Request(self.base_url + path, data=body,
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            err_body = self._read_body(exc)
            message = "HTTP %d from the remote backend" % exc.code
            if isinstance(err_body, dict) and err_body.get("error"):
                message = "%s: %s" % (message, err_body["error"])
            raise RemoteError(message, status=exc.code) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise RemoteError("cannot reach the remote backend at %s (%s)"
                              % (self.base_url, exc)) from exc

    @staticmethod
    def _read_body(exc: urllib.error.HTTPError) -> dict | None:
        """The error body, parsed once.  An unreadable body is None."""
        try:
            body = json.loads(exc.read().decode("utf-8"))
        except Exception:  # noqa: BLE001
            return None
        return body if isinstance(body, dict) else None

    # -- API -----------------------------------------------------------------

    def _require_key(self) -> None:
        """Raise if no API key is configured.

        Without a key every request would be a 401; say so before the first
        one rather than after.
        """
        if not self.api_key:
            raise RemoteError(
                "no API key configured for the novita remote backend; "
                "set CHOPSHOP_FLUX_NOVITA_API_KEY")

    def generate(self, prompt: str, *, model: str,
                 size: str = "1024x1024",
                 output_format: str = "png",
                 watermark: bool = False) -> list[RemoteImage]:
        """Text-to-image via POST /images/generations.

        Returns a list of ``RemoteImage`` (one per ``data[]`` entry).
        """
        self._require_key()
        payload = {
            "model": model,
            "prompt": prompt,
            "size": size,
            "output_format": output_format,
            "response_format": "b64_json",
            "watermark": watermark,
        }
        body = self._post_json("/images/generations", payload)
        return self._parse_images(body)

    def edit(self, prompt: str, *, image: bytes,
             model: str = "ming-image-0.1-design-layer") -> list[RemoteImage]:
        """Image editing via POST /images/edits (multipart/form-data).

        ``image`` is the raw bytes of the source raster.  The vendor expects
        exactly one file in the ``image[]`` field.
        """
        self._require_key()
        fields = {
            "model": model,
            "prompt": prompt,
            "response_format": "b64_json",
        }
        body = self._post_multipart("/images/edits", fields,
                                    "image[]", image, "source.png")
        return self._parse_images(body)

    @staticmethod
    def _parse_images(body: dict) -> list[RemoteImage]:
        """Parse the ``data[]`` array into ``RemoteImage`` objects."""
        data = body.get("data")
        if not isinstance(data, list):
            raise RemoteError("remote backend returned no 'data' array")
        results = []
        for item in data:
            b64 = item.get("b64_json")
            if b64 is None:
                raise RemoteError("remote backend returned an image without "
                                  "b64_json")
            png = base64.b64decode(b64)
            revised = item.get("revised_prompt")
            if isinstance(revised, str):
                try:
                    revised = json.loads(revised)
                except (TypeError, ValueError) as exc:
                    raise RemoteError(
                        "remote backend returned a malformed revised_prompt "
                        "(not valid JSON): %r" % revised) from exc
            results.append(RemoteImage(png=png, revised_prompt=revised))
        return results
