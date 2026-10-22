"""A thin stdlib client for the service.

Standard library only, and the network is touched in exactly one place:
``_urlopen``, which ``_post``, ``_get_json`` and ``_get_bytes`` all go through.
That shape is on purpose and it comes from chopshop-sui's bridge, which learned
the hard way that a client with the network in six places is a client whose
error mapping is only true for three of them:

* stdlib-only means this client can run wherever the pipeline runs — including a
  box that has no GPU and no torch, which is the whole point of a service.
* ONE seam means the tests stub one method and the entire client contract —
  including the restart retry below — is exercised with no server running.

``_urlopen`` also owns the refused-connect retry. The service's idle path
deliberately exits the process when an unload did not return the memory
(``CHOPSHOP_FLUX_IDLE_EXIT``) and the unit restarts it a few seconds later; a
request landing in that window used to fail a whole chain of otherwise-green
steps. See ``FluxError.restarting`` and ``#flux-idle-restart``.
"""

from __future__ import annotations

import base64
import errno
import json
import os
import subprocess
import time
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

    ``restarting`` says the connect was refused and then retried, i.e. the
    service was plausibly between its own restarts (the idle-exit path exits
    deliberately so the unit can return the memory) rather than simply down.
    It is a different event from a generation failure and the message says so,
    because a chained job reports its whole chain as error on its first failing
    step — so "the service was restarting for five seconds" arriving as a
    generation error costs a run whose other steps were green. (#flux-idle-restart)
    """

    def __init__(self, message: str, exit_code: int = 5,
                 restarting: bool = False):
        super().__init__(message)
        self.exit_code = exit_code
        self.restarting = restarting


def _is_refused(exc: BaseException) -> bool:
    """Whether this failure is a REFUSED TCP connect, and nothing else.

    Deliberately narrow, because the retry is only correct for this one case. A
    refused connect means the request never reached the service: there is no
    generation in flight, nothing was half-done, and the service comes back on
    its own within seconds if it is the idle-exit restart doing it. A timeout, a
    DNS failure, a TLS error or a reset connection are different events — a
    timeout in particular may mean the generation IS running, and repeating the
    request would queue a second one.
    """
    # urllib wraps the socket error; on some platforms the reason is the
    # ConnectionRefusedError itself, on others a plain OSError carrying errno.
    reason = getattr(exc, "reason", exc)
    if isinstance(reason, ConnectionRefusedError):
        return True
    return getattr(reason, "errno", None) == errno.ECONNREFUSED


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

    # -- the network seam, and the restart retry that lives on it ------------

    def _headers(self) -> dict:
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = "Bearer %s" % self.token
        return headers

    def _urlopen(self, req):
        """Open a request, riding out a restarting service. (#flux-idle-restart)

        The idle-unload path ends the process on purpose when the unload did not
        return the memory, and the unit restarts it about five seconds later. A
        step that lands in that window used to fail the whole chain — eight
        green steps, one step marked error, a run thrown away for a five-second
        gap in a service that was coming back on its own. The wait lives here,
        in the one method every route goes through, rather than at each call
        site: a call site that forgot it is a false chain failure, and
        forgetting is how the original fault survived.

        Two things are waited out, and only these two, because only these two
        mean the request provably did not become a generation:

        * a REFUSED TCP connect — the process is not listening yet;
        * the service's own DRAIN 503 — it is up, has decided to exit, and says
          how many seconds to wait in ``retry_after``.

        A timeout is NOT waited out: it may mean the generation is running, and
        repeating the request would queue a second one. Nor is a 5xx, which is
        an answer about a generation and not about the service's lifecycle.

        The attempts are one budget, not one per reason, so a service that
        refuses twice and then drains is still bounded by the same number.

        When the budget is spent the failure is raised from here, as the client's
        own error, because only this method knows whether a restart was seen.
        That is what lets the message distinguish "the service was between its
        restarts" from "the service is down" and from "the generation failed" —
        the distinction a chained job's step report cannot make on its own,
        because it only ever sees one step go red.
        """
        attempts = config.reconnect_attempts()
        backoff = config.reconnect_backoff()
        restarting = 0
        for attempt in range(1, attempts + 1):
            try:
                return urllib.request.urlopen(req, timeout=self.timeout)
            except urllib.error.HTTPError as exc:
                wait = self._drain_retry_after(exc)
                if wait is None:
                    # A response that is not the drain. Whatever it says, it is
                    # the service's answer and the caller's to interpret — and
                    # the body is read HERE so `_explain` does not have to read a
                    # stream that has already been consumed.
                    exc.flux_body = self._read_body(exc)
                    raise
                if attempt == attempts:
                    raise self._restarting(wait) from exc
                restarting += 1
                # Honour what the service asked for rather than our own guess:
                # it knows when it is actually going away. Never longer than our
                # own backoff step, so one drain cannot eat the caller's whole
                # timeout budget.
                time.sleep(min(wait, backoff * attempt))
            except (urllib.error.URLError, ConnectionError, OSError) as exc:
                if not _is_refused(exc):
                    raise
                if attempt == attempts:
                    raise self._unreachable(exc, restarting) from exc
                restarting += 1
                # Linear backoff (backoff * attempt), not exponential: the window
                # is bounded and short (measured ~5s), so waiting longer only
                # eats the caller's own timeout budget.
                time.sleep(backoff * attempt)
        raise AssertionError("unreachable: the loop returns or raises")

    @staticmethod
    def _drain_retry_after(exc: urllib.error.HTTPError) -> float | None:
        """The seconds this 503 asks the caller to wait, or None if it is not one.

        Recognised by the service's own ``kind`` rather than by the status code
        alone: 503 already means "the GPU is busy" for the guard, and retrying a
        busy card on the service's schedule is the guard's decision, not this
        client's. The drain says ``kind: "restarting"`` and carries
        ``retry_after``.
        """
        if exc.code != 503:
            return None
        body = FluxClient._read_body(exc)
        exc.flux_body = body
        if not isinstance(body, dict) or body.get("kind") != "restarting":
            return None
        if body.get("retry_after") is None:
            # A `kind: restarting` with no wait is a MALFORMED drain. Guessing a
            # wait for it would be inventing a number, and retrying on a guess
            # is how a client turns one answer into four. Treated as an ordinary
            # error, which is the safe direction.
            return None
        try:
            return max(0.0, float(body["retry_after"]))
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _read_body(exc: urllib.error.HTTPError) -> dict | None:
        """The error body, parsed once. An unreadable body is None, not a raise:
        a proxy's HTML 502 is still a 502."""
        try:
            body = json.loads(exc.read().decode("utf-8"))
        except Exception:  # noqa: BLE001 - a non-JSON error is still an error
            return None
        return body if isinstance(body, dict) else None

    def _unreachable(self, exc, restarting: int, start_hint: bool = True) -> FluxError:
        """The message for a connect that never got through. Exit 3.

        Exit 3 rather than 5 is the distinction the issue asked for: 5 means the
        generation failed, and a chain that reports its whole run as error on its
        first failing step must not be handed a generation failure for a socket
        that was closed under it.
        """
        if restarting:
            slept = config.reconnect_backoff() * restarting * (restarting + 1) / 2.0
            return self._restarting_note(
                "the flux service at %s refused the connection and did not "
                "answer within %d attempt(s) over %.1fs — it looks like it is "
                "RESTARTING (the idle-exit path ends the process so the unit can "
                "return the memory, and systemd brings it back a few seconds "
                "later) rather than down. No generation was started, so nothing "
                "is half-done: re-run the step, or raise "
                "CHOPSHOP_FLUX_RECONNECT_ATTEMPTS to wait longer."
                % (self.base_url, restarting + 1, slept))
        hint = (" Start it with: python -m chopshop_flux serve"
                if start_hint else "")
        return FluxError("cannot reach the flux service at %s (%s).%s"
                         % (self.base_url, exc, hint), exit_code=3)

    def _restarting(self, wait: float) -> FluxError:
        return self._restarting_note(
            "the flux service at %s is RESTARTING and asked for %.1fs before "
            "the retry, which was not enough within the retry budget. No "
            "generation was started, so nothing is half-done: re-run the step, "
            "or raise CHOPSHOP_FLUX_RECONNECT_ATTEMPTS."
            % (self.base_url, wait))

    def _restarting_note(self, message: str) -> FluxError:
        return FluxError(message, exit_code=3, restarting=True)

    def _post(self, route: str, payload: dict) -> dict:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(self.base_url + route, data=data,
                                     headers=self._headers())
        try:
            with self._urlopen(req) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise FluxError(self._explain(exc), exit_code=self._http_exit(exc)) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            # No refusal was seen, or the retry budget ran out for a non-refusal
            # reason; both are plain unreachability, never a generation failure.
            raise self._unreachable(exc, 0) from exc

    def _get_bytes(self, path: str) -> bytes:
        # Quote it: a generated name is ours and therefore safe today, but a
        # caller-supplied name is not, and an unquoted space raises InvalidURL
        # from urllib — a bug chopshop-sui hit on prompt-derived filenames.
        quoted = urllib.parse.quote(str(path).lstrip("/"), safe="/")
        url = self.base_url + "/" + quoted
        req = urllib.request.Request(url, headers=self._headers())
        try:
            with self._urlopen(req) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            raise FluxError(self._explain(exc), exit_code=self._http_exit(exc)) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise self._unreachable(exc, 0, start_hint=False) from exc

    @staticmethod
    def _explain(exc: urllib.error.HTTPError) -> str:
        """Turn the service's JSON error body into the message.

        The body was already read by `_urlopen` (a stream can only be read once,
        and the drain check needs it first), so it rides along on the exception
        rather than being fetched again here.
        """
        body = getattr(exc, "flux_body", None)
        if body is None:
            body = FluxClient._read_body(exc)
        if isinstance(body, dict) and body.get("error"):
            return "%s (HTTP %s)" % (body["error"], exc.code)
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
        # Through `_urlopen` like every other route, so a `/health` probe issued
        # during the restart window also rides it out instead of reporting the
        # service as down when it is three seconds from answering.
        req = urllib.request.Request(self.base_url + route,
                                     headers=self._headers())
        try:
            with self._urlopen(req) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            raise FluxError(self._explain(exc), exit_code=self._http_exit(exc)) from exc
        except (urllib.error.URLError, ConnectionError, OSError) as exc:
            raise self._unreachable(exc, 0) from exc

    def generate(self, prompt: str, **kwargs) -> dict:
        payload = {"prompt": prompt}
        payload.update({k: v for k, v in kwargs.items() if v is not None})
        return self._post("/generate", payload)

    def edit(self, source_path, prompt: str, **kwargs) -> dict:
        """Edit from one source raster, or condition on several at once.

        ``source_path`` is a path or a list of paths. A list sends several
        references as one conditioning set and the prompt says how they
        relate — which only a checkpoint whose pipeline declares a list for its
        image can act on, so a second reference on an img2img family comes back
        as the service's own refusal rather than a silently ignored image.
        """
        if isinstance(source_path, (list, tuple)):
            if not source_path:
                raise FluxError("edit needs at least one reference image",
                                exit_code=2)
            image = [image_data_url(path) for path in source_path]
        else:
            image = image_data_url(source_path)
        payload = {"prompt": prompt, "image": image}
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
