#!/usr/bin/env python3
"""A local captioner behind an HTTP seam — the pixels the annotator never sees.

chopshop-jev#2: `prompt_adherence` ("does the image depict what the prompt
asked for?") is the one question in the `generation-slop` vocabulary that
genuinely needs a picture, and a TEXT decision service can never answer it, so
the fold reports it `unevidenced` — correct, but it also means "model X is more
accurate" can only ever mean "more structured".

This is the seam the issue asks for: an endpoint that takes an image and
returns text. The annotator stays stdlib-only and never learns a model exists —
the HARNESS (`scripts/slop_cannon.py`) calls `POST /caption`, carries the text
back inside the artifact, and the projector turns it into `image_visible`
evidence. Same shape as `laya-serve`: stdlib server, env-driven config, a
deploy unit and an env template, no dependency added to the annotator.

Default model is `LiquidAI/LFM2.5-VL-450M` (450M params, SigLIP2 encoder,
native 512x512 — the frame size this harness generates at). It needs
`transformers` >= 5.1 and Pillow; the service refuses to start without them and
says which is missing, rather than importing them at module scope and dying on
a traceback nobody can act on.

Run:

    CAPTION_MODEL=... python3 scripts/caption_serve.py
    curl -s localhost:8798/health
    curl -s localhost:8798/caption -H 'content-type: application/json' \\
         -d '{"image_b64": "..."}'
"""

from __future__ import annotations

import base64
import io
import json
import os
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8798
DEFAULT_MODEL = "LiquidAI/LFM2.5-VL-450M"
DEFAULT_PROMPT = ("Describe this image in one or two sentences: what is depicted, "
                  "what style it is rendered in, and anything visibly wrong with it.")
DEFAULT_MAX_NEW_TOKENS = 96

# Set by configure()/load_model(); read by the handler. Guarded by MODEL_LOCK so
# two first requests cannot load two copies of the weights.
MODEL_LOCK = threading.Lock()
LOADED: dict = {"model": None, "processor": None, "ready": False, "device": "cpu",
                "model_id": None, "load_seconds": None, "error": None}
CONFIG: dict = {"host": DEFAULT_HOST, "port": DEFAULT_PORT, "key": None,
                "model": DEFAULT_MODEL, "device": "cpu", "prompt": DEFAULT_PROMPT,
                "max_new_tokens": DEFAULT_MAX_NEW_TOKENS, "preload": False}


def configure_from_env() -> dict:
    """Read every setting from the environment — nothing host-specific lives here."""
    host = (os.environ.get("CAPTION_HOST") or DEFAULT_HOST).strip()
    try:
        port = int(os.environ.get("CAPTION_PORT") or DEFAULT_PORT)
    except ValueError:
        raise SystemExit("CAPTION_PORT must be a port number, got %r"
                         % os.environ["CAPTION_PORT"])
    key = (os.environ.get("CAPTION_API_KEY") or "").strip() or None
    preload = (os.environ.get("CAPTION_PRELOAD") or "1").strip().lower() in ("1", "true", "yes")

    if host not in ("127.0.0.1", "localhost", "::1") and not key:
        # The laya unit's rule, applied: a bind that leaves loopback without a
        # token is somebody else's model, and every image sent to it.
        raise SystemExit("CAPTION_HOST=%s is not loopback, so CAPTION_API_KEY is "
                         "required — an unauthenticated caption endpoint on a "
                         "shared network receives every raster the pipeline drew." % host)

    CONFIG.update({"host": host, "port": port, "key": key,
                   "model": (os.environ.get("CAPTION_MODEL") or DEFAULT_MODEL).strip(),
                   "device": (os.environ.get("CAPTION_DEVICE") or "cpu").strip(),
                   "prompt": os.environ.get("CAPTION_PROMPT") or DEFAULT_PROMPT,
                   "preload": preload})
    try:
        CONFIG["max_new_tokens"] = int(os.environ.get("CAPTION_MAX_NEW_TOKENS")
                                       or DEFAULT_MAX_NEW_TOKENS)
    except ValueError:
        raise SystemExit("CAPTION_MAX_NEW_TOKENS must be an integer")
    return dict(CONFIG)


def load_model() -> dict:
    """Import the stack and load the checkpoint once. Returns LOADED."""
    with MODEL_LOCK:
        if LOADED["ready"] or LOADED["error"]:
            return dict(LOADED)
        started = time.monotonic()
        try:
            import torch  # noqa: F401
            from transformers import AutoModelForImageTextToText, AutoProcessor
        except ImportError as exc:
            LOADED["error"] = ("missing Python package %r — install transformers "
                               "(>= 5.1) and Pillow into the interpreter that runs "
                               "this service" % (exc.name or str(exc)))
            return dict(LOADED)
        try:
            device = CONFIG["device"]
            dtype = torch.float32 if device.startswith("cpu") else torch.bfloat16
            LOADED["processor"] = AutoProcessor.from_pretrained(CONFIG["model"])
            LOADED["model"] = AutoModelForImageTextToText.from_pretrained(
                CONFIG["model"], dtype=dtype)
            if device.startswith("cuda") or device.startswith("cpu"):
                LOADED["model"].to(device)
            LOADED["model"].eval()
        except Exception:  # noqa: BLE001 - report it, do not traceback at the operator
            LOADED["error"] = "failed to load %s: %s" % (
                CONFIG["model"], traceback.format_exc(limit=1).strip())
            return dict(LOADED)
        LOADED.update({"ready": True, "device": CONFIG["device"],
                       "model_id": CONFIG["model"],
                       "load_seconds": round(time.monotonic() - started, 2)})
        return dict(LOADED)


def caption_image(image, *, prompt: str | None = None) -> str:
    """One caption, synchronously. `image` is a PIL image."""
    import torch
    from transformers import AutoProcessor  # already loaded; import for typing clarity

    state = load_model()
    if state["error"]:
        raise RuntimeError(state["error"])
    model, processor = state["model"], state["processor"]
    text = (prompt or CONFIG["prompt"]).strip() or DEFAULT_PROMPT

    conversation = [{"role": "user", "content": [
        {"type": "image", "image": image},
        {"type": "text", "text": text},
    ]}]
    inputs = processor.apply_chat_template(
        conversation, add_generation_prompt=True, return_tensors="pt",
        return_dict=True, tokenize=True).to(model.device)
    with torch.no_grad():
        outputs = model.generate(**inputs, max_new_tokens=CONFIG["max_new_tokens"])

    # Decode ONLY the tokens the model generated. Decoding the whole sequence
    # echoes the conversation back — measured: the caption arrived prefixed with
    # the role marker ("assistant\nThis image depicts ..."), which would have
    # travelled into the artifact's evidence as if the model wrote it. Slicing
    # at the prompt's length is the difference between an answer and a
    # transcript with an answer somewhere inside it.
    prompt_length = inputs["input_ids"].shape[1]
    generated = outputs[:, prompt_length:]
    return processor.batch_decode(generated, skip_special_tokens=True)[0].strip()


def _image_from_payload(payload: dict):
    from PIL import Image
    if isinstance(payload, dict) and payload.get("image_b64"):
        raw = base64.b64decode(payload["image_b64"])
        return Image.open(io.BytesIO(raw)).convert("RGB")
    if isinstance(payload, dict) and payload.get("image_path"):
        return Image.open(payload["image_path"]).convert("RGB")
    raise ValueError("send {\"image_b64\": \"...\"} or {\"image_path\": \"/path.png\"}")


class CaptionHandler(BaseHTTPRequestHandler):
    server_version = "chopshop-caption/1.0"

    def log_message(self, format, *args):  # noqa: A002 - http.server's spelling
        if os.environ.get("CAPTION_LOG_LEVEL", "warn").lower() == "info":
            sys.stderr.write("%s %s\n" % (self.address_string(), format % args))

    def _send(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorised(self) -> bool:
        key = CONFIG["key"]
        if not key:
            return True
        header = self.headers.get("authorization") or ""
        return header == "Bearer " + key

    def do_GET(self):  # noqa: N802 - http.server's spelling
        if self.path.split("?")[0] == "/health":
            state = load_model() if CONFIG["preload"] else dict(LOADED)
            self._send(200, {
                "status": "error" if state["error"] else "ok",
                "loaded": bool(state["ready"]),
                "model": CONFIG["model"],
                "device": CONFIG["device"],
                "load_seconds": state["load_seconds"],
                "error": state["error"],
                "auth_required": bool(CONFIG["key"]),
            })
            return
        self._send(404, {"detail": "Not Found"})

    def do_POST(self):  # noqa: N802
        if self.path.split("?")[0] != "/caption":
            self._send(404, {"detail": "Not Found"})
            return
        if not self._authorised():
            self._send(401, {"detail": "invalid or missing bearer token"})
            return
        try:
            length = int(self.headers.get("content-length") or 0)
            payload = json.loads(self.rfile.read(length) or b"{}")
            image = _image_from_payload(payload)
        except Exception as exc:  # noqa: BLE001 - a bad request is a 400, not a crash
            self._send(400, {"detail": "bad image payload: %s" % exc})
            return

        state = load_model()
        if state["error"]:
            self._send(503, {"detail": state["error"]})
            return
        started = time.monotonic()
        try:
            text = caption_image(image, prompt=payload.get("prompt"))
        except Exception as exc:  # noqa: BLE001
            self._send(500, {"detail": "caption failed: %s" % exc})
            return
        self._send(200, {"caption": text, "model": CONFIG["model"],
                         "ms": int((time.monotonic() - started) * 1000)})


def main(argv: list[str] | None = None) -> int:
    configure_from_env()
    if CONFIG["preload"]:
        state = load_model()
        if state["error"]:
            print("caption-serve: %s" % state["error"], file=sys.stderr)
            return 1
        print("caption-serve: %s loaded in %.1fs" % (CONFIG["model"],
                                                     state["load_seconds"] or 0), flush=True)
    else:
        print("caption-serve: %s (loads on the first request)" % CONFIG["model"], flush=True)
    server = ThreadingHTTPServer((CONFIG["host"], CONFIG["port"]), CaptionHandler)
    print("caption-serve: listening on %s:%d%s" % (
        CONFIG["host"], CONFIG["port"],
        " with a bearer token" if CONFIG["key"] else " (loopback, no token)"), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
