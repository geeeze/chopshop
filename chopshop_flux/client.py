"""A thin stdlib client for the service.

Standard library only, and the network is touched in exactly two methods,
``_post`` and ``_get_bytes``. Both properties are on purpose and both come from
chopshop-sui's bridge, which learned them the hard way:

* stdlib-only means this client can run wherever the pipeline runs — including a
  box that has no GPU and no torch, which is the whole point of a service.
* two network seams mean the tests stub those two and the entire client contract
  is exercised with no server running.
"""

from __future__ import annotations

import base64
import json
import os
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from . import config

# What a raster may be passed as. Extension-driven rather than sniffed, because
# the client is meant to work without Pillow installed.
MIME_BY_EXT = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".bmp": "image/bmp",
}


class FluxError(Exception):
    """A client-side or service-side failure, carrying an exit code.

    Exit codes match the shape chopshop-sui's bridge already uses, so a script
    that handles one handles the other:

        2 = bad usage / bad request
        3 = service unreachable
        4 = model missing or unloadable
        5 = generation failed
    """

    def __init__(self, message: str, exit_code: int = 5):
        super().__init__(message)
        self.exit_code = exit_code


def default_base_url() -> str:
    """Where to reach the service, from the environment.

    Falls back to the configured loopback address and port rather than a literal
    host, so the default is "the service as this box would run it" and a remote
    service is one variable away.
    """
    explicit = os.environ.get("CHOPSHOP_FLUX_URL")
    if explicit:
        return explicit.rstrip("/")
    return "http://%s:%d" % (config.bind(), config.port())


class FluxClient:
    def __init__(self, base_url: str | None = None, token: str | None = None,
                 timeout: float = 600.0):
        self.base_url = (base_url or default_base_url()).rstrip("/")
        self.token = token if token is not None else config.token()
        # Generous by default: a first request on a cold cache loads ~16 GB of
        # weights before it generates anything, and the slowest part of this
        # service is the load, not the generation.
        self.timeout = timeout

    # -- network seams (the only two places the network is touched) ---------

    def _headers(self) -> dict:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer %s" % self.token
        return headers

    def _post(self, route: str, payload: dict) -> dict:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(self.base_url + route, data=data,
                                     headers=self._headers())
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise FluxError(self._explain(exc), exit_code=self._http_exit(exc)) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise FluxError(
                "cannot reach the flux service at %s (%s). Start it with: "
                "python -m chopshop_flux serve" % (self.base_url, exc),
                exit_code=3) from exc

    def _get_bytes(self, path: str) -> bytes:
        # Quote it: a generated name is ours and therefore safe today, but a
        # caller-supplied name is not, and an unquoted space raises InvalidURL
        # from urllib — a bug chopshop-sui hit on prompt-derived filenames.
        quoted = urllib.parse.quote(str(path).lstrip("/"), safe="/")
        url = self.base_url + "/" + quoted
        req = urllib.request.Request(url, headers=self._headers())
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            raise FluxError(self._explain(exc), exit_code=self._http_exit(exc)) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise FluxError("cannot reach the flux service at %s (%s)"
                            % (self.base_url, exc), exit_code=3) from exc

    @staticmethod
    def _explain(exc: urllib.error.HTTPError) -> str:
        """Turn the service's JSON error body into the message."""
        try:
            body = json.loads(exc.read().decode("utf-8"))
            if isinstance(body, dict) and body.get("error"):
                return "%s (HTTP %s)" % (body["error"], exc.code)
        except Exception:  # noqa: BLE001 - a non-JSON error is still an error
            pass
        return "HTTP %s from the flux service" % exc.code

    @staticmethod
    def _http_exit(exc: urllib.error.HTTPError) -> int:
        # A 4xx is the caller's fault and will not fix itself by retrying; a 5xx
        # is generation failing, which is the bridge's exit 5.
        return 2 if 400 <= exc.code < 500 else 5

    # -- API ----------------------------------------------------------------

    def health(self) -> dict:
        return self._get_json("/health")

    def models(self) -> dict:
        return self._get_json("/models")

    def _get_json(self, route: str) -> dict:
        req = urllib.request.Request(self.base_url + route,
                                     headers=self._headers())
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise FluxError(self._explain(exc), exit_code=self._http_exit(exc)) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise FluxError(
                "cannot reach the flux service at %s (%s). Start it with: "
                "python -m chopshop_flux serve" % (self.base_url, exc),
                exit_code=3) from exc

    def generate(self, prompt: str, **kwargs) -> dict:
        payload = {"prompt": prompt}
        payload.update({k: v for k, v in kwargs.items() if v is not None})
        return self._post("/generate", payload)

    def edit(self, source_path: str, prompt: str, **kwargs) -> dict:
        payload = {"prompt": prompt, "image": image_data_url(source_path)}
        payload.update({k: v for k, v in kwargs.items() if v is not None})
        return self._post("/edit", payload)

    def unload(self) -> dict:
        return self._post("/unload", {})

    def download(self, name: str, out_dir: str) -> str:
        # Fetch BEFORE opening the target. `open(target, "wb")` truncates the
        # moment it is evaluated, so writing the fetch *inside* that with-block
        # destroys the source whenever out_dir is the directory the service
        # serves from — a reasonable thing to configure, and it silently
        # produced 0-byte files (the service then streamed the file it had just
        # had zeroed underneath it).
        safe_name = os.path.basename(name)
        raw = self._get_bytes("/files/%s" % safe_name)
        os.makedirs(out_dir, exist_ok=True)
        target = os.path.join(out_dir, safe_name)
        with open(target, "wb") as handle:
            handle.write(raw)
        return target


def image_data_url(path: str) -> str:
    """Encode a local raster as a ``data:image/...;base64,`` URL.

    The same wire format for a reference image that chopshop-sui uses for
    img2img, so the two layers are readable by the same person without a second
    convention to remember.
    """
    ext = os.path.splitext(path)[1].lower()
    mime = MIME_BY_EXT.get(ext)
    if mime is None:
        raise FluxError("unsupported image extension %r (known: %s)"
                        % (ext or "", ", ".join(sorted(MIME_BY_EXT))), exit_code=2)
    with open(path, "rb") as handle:
        raw = handle.read()
    return "data:%s;base64,%s" % (mime, base64.b64encode(raw).decode("ascii"))


def pipeline_argv(raster: str, *, sweep: str | None = None,
                  skip_prep: bool = False,
                  root: str | None = None) -> list[str]:
    """The argv for handing a raster to chopshop-svg's front half.

    ``--sweep`` is emitted in the ``--sweep=FILE`` form and only that form:
    front_pipeline.sh parses the equals form, and passing the two-token form hits
    its ``unknown option`` path. chopshop-sui shipped that bug once.
    """
    root = root or config.pipeline_root()
    if not root:
        raise FluxError(
            "no chopshop-svg checkout configured; set CHOPSHOP_FLUX_PIPELINE to "
            "one to use gen2pipe", exit_code=2)
    script = os.path.join(root, "front_pipeline.sh")
    if not os.path.isfile(script):
        raise FluxError("no front_pipeline.sh in %s" % root, exit_code=2)
    argv = [script, raster]
    if sweep:
        argv.append("--sweep=%s" % sweep)
    if skip_prep:
        argv.append("--skip-prep")
    return argv


def run_pipeline(raster: str, *, sweep: str | None = None, skip_prep: bool = False,
                 root: str | None = None, runner=subprocess.call) -> int:
    """Run the front half. A seam, so the hand-off is testable without a pipeline.

    0 = candidates produced and at least one passed; 1 = candidates produced but
    none passed; anything else is a pipeline step failure.
    """
    return runner(pipeline_argv(raster, sweep=sweep, skip_prep=skip_prep,
                                root=root))
