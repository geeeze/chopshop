#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""systemone_gateway.py -- ONE `/v1/systemone` front door, any backend.

WHY THIS EXISTS
---------------
This repo's contract is already right: *which* service answers a typed question
is a deployment choice, and `JEV_ENDPOINT` is the entire seam
(`docs/local-decision-service.md`). Every local backend speaks
`POST /v1/systemone` — `laya-serve` implements the TypeSafe wire protocol
natively, which is why there is no adapter in this repo.

What was missing is the OTHER direction. The hosted decision service is
`/v1/systemone`; OpenRouter and the HuggingFace Inference Router are
`/v1/chat/completions`. So pointing the annotator at a cloud model meant either
a second client in the annotator (which the seam exists to prevent) or no cloud
option at all. This gateway closes that: it accepts `/v1/systemone`, and
translates for whichever backend is configured.

    annotator / slop_cannon / the svg runner
                  |  POST /v1/systemone   (never changes)
                  v
          systemone_gateway  ---- local  ---->  laya-serve   (native, pass-through)
                  |        ---- cloud  ---->  OpenRouter    (chat/completions)
                  |        ---- cloud  ---->  HF router     (chat/completions)
                  v
        {"model", "answers", "usage", "routing"}

DESIGN RULES, each for a reason
-------------------------------
* **Stdlib only.** It is a wire adapter; it holds no model, so it must not pull a
  torch/diffusers tree to do its job. This process idles at single-digit MB.
* **`laya` is a PASS-THROUGH, not a translation.** The local service already
  speaks the protocol. Rebuilding the request here would be a second
  implementation of a wire format that is already correct, and it would drift.
* **Cloud answers are TYPED, not prose.** A `choice` question must come back as
  one of its own `criteria` ids plus a confidence, or it is reported as
  `unevidenced`/`error` rather than guessed — a plausible-looking free-text
  answer folded into a print verdict is worse than a missing one.
* **A backend that fails is NAMED.** `routing.attempts` records every backend
  tried and why it did not answer. "No backend answered" and "laya said
  unevidenced" are different facts about an artifact.
* **No key is ever logged or echoed.** Only whether one was configured.

ENVIRONMENT (all read at CALL time, nothing baked in)
-----------------------------------------------------
    SYSTEMONE_BACKEND        default backend: local | openrouter | hf  (local)
    SYSTEMONE_FALLBACK       comma list tried in order after the chosen one
    SYSTEMONE_HOST / _PORT   bind (127.0.0.1 / 8799)
    SYSTEMONE_API_KEY        bearer the CALLER must present, if set
    LAYA_ENDPOINT            default http://127.0.0.1:8797
    OPENROUTER_API_KEY       cloud key
    OPENROUTER_MODEL         default google/gemini-2.5-flash
    HF_TOKEN                 cloud key for the HF router
    HF_MODEL                 default Qwen/Qwen2.5-7B-Instruct
    SYSTEMONE_TIMEOUT        seconds per backend call (default 60)

RUN
---
    python3 scripts/systemone_gateway.py
    curl -s localhost:8799/health
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = "systemone-gateway"
VERSION = "0.1.0"

LOCAL = "local"
OPENROUTER = "openrouter"
HF = "hf"
BACKENDS = (LOCAL, OPENROUTER, HF)

# The question types the decision service answers, MEASURED from this repo's own
# profiles: `printability` mixes choice + score + noul. `phrase` is refused by the
# service itself (HTTP 400), so it is refused here too.
QUESTION_TYPES = ("choice", "score", "noul")

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8799
DEFAULT_LAYA = "http://127.0.0.1:8797"
DEFAULT_OPENROUTER_MODEL = "google/gemini-2.5-flash"
DEFAULT_HF_MODEL = "Qwen/Qwen2.5-7B-Instruct"
OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
HF_ROUTER_URL = "https://router.huggingface.co/v1/chat/completions"

# A decision should be one short JSON object. A generous ceiling still stops a
# runaway model from streaming an essay into an answer parser.
MAX_TOKENS = 900
MAX_BODY_BYTES = 1024 * 1024


class BackendError(RuntimeError):
    """A backend was tried and did not produce usable answers."""

    def __init__(self, message: str, status: int = 502, kind: str = "backend_error"):
        super().__init__(message)
        self.status = status
        self.kind = kind


# ---------------------------------------------------------------------------
# configuration (read at call time, like every other knob in this repo)
# ---------------------------------------------------------------------------


def config() -> dict:
    return {
        "backend": (os.environ.get("SYSTEMONE_BACKEND") or LOCAL).strip().lower(),
        "fallback": [name.strip().lower()
                     for name in (os.environ.get("SYSTEMONE_FALLBACK") or "").split(",")
                     if name.strip()],
        "host": (os.environ.get("SYSTEMONE_HOST") or DEFAULT_HOST).strip(),
        "port": int((os.environ.get("SYSTEMONE_PORT") or DEFAULT_PORT)),
        "api_key": os.environ.get("SYSTEMONE_API_KEY") or None,
        "laya": (os.environ.get("LAYA_ENDPOINT") or DEFAULT_LAYA).rstrip("/"),
        "openrouter_key": os.environ.get("OPENROUTER_API_KEY") or None,
        "openrouter_model": (os.environ.get("OPENROUTER_MODEL")
                             or DEFAULT_OPENROUTER_MODEL),
        "hf_key": os.environ.get("HF_TOKEN") or None,
        "hf_model": (os.environ.get("HF_MODEL") or DEFAULT_HF_MODEL),
        "timeout": float(os.environ.get("SYSTEMONE_TIMEOUT") or 60.0),
    }


# ---------------------------------------------------------------------------
# request validation -- the annotation envelope, nothing else
# ---------------------------------------------------------------------------


def validate_request(body) -> dict:
    """The documented envelope: ``model``, ``state``, ``questions``.

    Refused here rather than at a backend, so a malformed projection costs no
    cloud call and no local load. ``questions`` must be a non-empty object of
    question-id -> {type, instructions, criteria}.

    The three types the service actually answers are accepted, and each is
    checked against ITS OWN criteria shape — MEASURED from this repo's profiles:
    ``choice`` and ``noul`` carry a criteria DICT (id -> description, the answer
    is one id), while ``score`` carries a criteria LIST (one described level per
    entry, the answer is an index into it). An earlier version of this file
    accepted ``choice`` only, which rejected the default `printability` profile
    outright — its `tonal_structure` is a `score`.
    """
    if not isinstance(body, dict):
        raise BackendError("body must be a JSON object", 400, "bad_request")
    state = body.get("state")
    questions = body.get("questions")
    if not isinstance(state, dict):
        raise BackendError("state must be a JSON object", 400, "bad_request")
    if not isinstance(questions, dict) or not questions:
        raise BackendError("questions must be a non-empty object", 400, "bad_request")
    if len(questions) > 32:
        raise BackendError("questions carries %d entries; at most 32 are accepted"
                           % len(questions), 400, "bad_request")
    for name, question in questions.items():
        if not isinstance(question, dict):
            raise BackendError("question %r must be an object" % name, 400,
                               "bad_request")
        kind = question.get("type")
        if kind not in QUESTION_TYPES:
            raise BackendError(
                "question %r has type %r; the service answers %s"
                % (name, kind, "/".join(QUESTION_TYPES)), 400, "bad_request")
        criteria = question.get("criteria")
        if kind == "score":
            if not isinstance(criteria, list) or not criteria:
                raise BackendError(
                    "question %r is a score, so its criteria must be a LIST of "
                    "described levels" % name, 400, "bad_request")
        else:
            if not isinstance(criteria, dict) or not criteria:
                raise BackendError(
                    "question %r is a %s, so its criteria must be an OBJECT of "
                    "id -> description" % (name, kind), 400, "bad_request")
    return body


def evidence_gate(body: dict) -> tuple[dict, list]:
    """Answer only what the state can evidence; name the rest.

    A question declaring ``requires: ["image_visible"]`` cannot be answered from
    text alone. The local service gets the same state and does its own thing;
    for a CLOUD backend this gateway must not let a model invent a picture it
    cannot see. So those questions are skipped and reported.
    """
    declared = (body.get("state", {}).get("evidence") or {})
    answerable, skipped = {}, []
    for name, question in body["questions"].items():
        missing = [requirement for requirement
                   in (question.get("requires") or ())
                   if not declared.get(requirement)]
        if missing:
            skipped.append({"question": name, "requires": missing,
                            "reason": "evidence absent: %s" % ", ".join(missing)})
            continue
        answerable[name] = question
    return answerable, skipped


# ---------------------------------------------------------------------------
# the prompt for a cloud backend
# ---------------------------------------------------------------------------


def build_prompt(state: dict, questions: dict) -> list:
    """Turn a typed-question bundle into a chat request that must answer in JSON.

    Ids are passed VERBATIM and the model is told they are the only legal
    answers: validation is by membership, so a paraphrase cannot slip through as
    a different category. Temperature 0 because two identical artifacts must not
    earn different verdicts.

    A ``score`` question is answered as an INDEX into its criteria list rather
    than as a free number: the list already describes the levels, and letting a
    model invent 7.3 on a four-level scale produces a label that does not exist.
    """
    schema = {}
    for name, question in questions.items():
        kind = question.get("type")
        entry = {"type": kind, "instructions": question.get("instructions", "")}
        if kind == "score":
            entry["levels"] = {str(index): text
                               for index, text in enumerate(question["criteria"])}
            entry["answer_as"] = ("score: the index of the level that fits, "
                                  "0 to %d" % (len(question["criteria"]) - 1))
        else:
            entry["allowed"] = list(question["criteria"])
            entry["criteria"] = question["criteria"]
            entry["answer_as"] = "choice: one allowed id, verbatim"
        schema[name] = entry
    system = (
        "You answer typed decision questions about one generated artwork. "
        "Reply with ONE JSON object and nothing else, of the form "
        '{"answers": {"<question_id>": {"choice": "<allowed id>", '
        '"answer_confidence": <0..1>}, ...}}. '
        "For a question whose `answer_as` asks for a score, return "
        '{"score": <index>, "answer_confidence": <0..1>} instead of "choice". '
        "`choice` MUST be one of that question's `allowed` ids, verbatim, and "
        "`score` MUST be one of its level indices. "
        "`answer_confidence` is your probability that the answer is correct. "
        "If the evidence given does not let you judge a question, use a low "
        "confidence rather than inventing detail. Do not answer questions that "
        "are not listed."
    )
    user = json.dumps({"evidence_state": state, "questions": schema},
                      indent=2, sort_keys=True)
    return [{"role": "system", "content": system},
            {"role": "user", "content": user}]


def parse_answers(text: str, questions: dict) -> tuple[dict, list]:
    """Extract validated answers from a model reply, or say what was wrong.

    Tolerates a fenced block or prose around the object (models do that), but
    never tolerates an answer outside the question's own criteria: an unknown id
    is DROPPED and reported, because a made-up category folded into a verdict is
    a wrong verdict wearing a confident number.

    ``score`` answers are returned in the shape this repo's fold reads —
    ``{"score": <index>, "legend": {index: level}}`` — so a cloud answer and a
    local one are indistinguishable to the caller.
    """
    answers, rejected = {}, []
    document = _first_json_object(text)
    if document is None:
        return {}, [{"reason": "no JSON object in the reply",
                     "excerpt": (text or "")[:180]}]
    raw = document.get("answers")
    if not isinstance(raw, dict):
        return {}, [{"reason": "reply has no 'answers' object",
                     "excerpt": (text or "")[:180]}]
    for name, question in questions.items():
        entry = raw.get(name)
        if not isinstance(entry, dict):
            rejected.append({"question": name, "reason": "no answer returned"})
            continue
        kind = question.get("type")
        confidence = _confidence(entry)
        if kind == "score":
            levels = question["criteria"]
            value = entry.get("score", entry.get("choice"))
            try:
                index = int(round(float(value)))
            except (TypeError, ValueError):
                rejected.append({"question": name,
                                 "reason": "score %r is not a number" % (value,)})
                continue
            if not 0 <= index < len(levels):
                rejected.append({"question": name,
                                 "reason": "score %r is outside 0..%d"
                                           % (value, len(levels) - 1)})
                continue
            answer = {"score": index,
                      "legend": {str(i): text for i, text in enumerate(levels)}}
            if confidence is not None:
                answer["answer_confidence"] = confidence
            answers[name] = answer
            continue
        choice = entry.get("choice")
        if choice not in question["criteria"]:
            rejected.append({"question": name,
                             "reason": "choice %r is not one of the criteria"
                                       % (choice,)})
            continue
        if kind == "noul":
            # The local service answers a `noul` as a calibrated P(true) in a
            # `noul` field, NOT as a `choice` id -- MEASURED from laya's reply:
            # {"noul": 0.5052, "answer_confidence": 0.5052, "type": "noul"}.
            # Emitting the same shape is what makes a cloud answer and a local
            # one indistinguishable to the fold.
            probability = confidence
            if probability is None:
                rejected.append({"question": name,
                                 "reason": "a noul answer needs a confidence "
                                           "to be read as a probability"})
                continue
            if str(choice).lower() in ("false", "no", "0"):
                probability = 1.0 - probability
            answers[name] = {"noul": round(probability, 4),
                             "answer_confidence": round(probability, 4),
                             "type": "noul"}
            continue
        answer = {"choice": choice, "type": kind}
        if confidence is not None:
            answer["answer_confidence"] = confidence
        answers[name] = answer
    for name in raw:
        if name not in questions:
            rejected.append({"question": name,
                             "reason": "not asked in this request"})
    return answers, rejected


def _confidence(entry: dict):
    """A 0..1 certainty from any of the shapes a model answers with."""
    for key in ("answer_confidence", "confidence"):
        value = entry.get(key)
        if value is None:
            continue
        try:
            return min(1.0, max(0.0, float(value)))
        except (TypeError, ValueError):
            continue
    return None


def _first_json_object(text: str):
    """The first balanced top-level JSON object in ``text``, or None."""
    if not text:
        return None
    start = text.find("{")
    while start != -1:
        depth, in_string, escaped = 0, False, False
        for index in range(start, len(text)):
            char = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue
            if char == '"':
                in_string = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    try:
                        value = json.loads(text[start:index + 1])
                    except json.JSONDecodeError:
                        break
                    if isinstance(value, dict):
                        return value
                    break
        start = text.find("{", start + 1)
    return None


# ---------------------------------------------------------------------------
# backends
# ---------------------------------------------------------------------------


def _post_json(url: str, payload: dict, headers: dict, timeout: float) -> dict:
    request = urllib.request.Request(
        url, data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json",
                 "Accept": "application/json", **headers})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:300].decode("utf-8", "replace")
        raise BackendError("HTTP %s from the backend: %s" % (exc.code, detail),
                           status=exc.code) from exc
    except urllib.error.URLError as exc:
        raise BackendError("cannot reach the backend: %s" % (exc.reason,),
                           status=503, kind="backend_unreachable") from exc
    except json.JSONDecodeError as exc:
        raise BackendError("backend returned non-JSON: %s" % (exc,),
                           status=502) from exc


def call_local(body: dict, settings: dict) -> dict:
    """PASS-THROUGH to laya. The local service speaks this protocol natively.

    Everything is forwarded unchanged except the URL: rebuilding the request
    here would be a second copy of a wire format that is already implemented
    correctly one hop away, and the two would drift.
    """
    headers = {}
    if os.environ.get("LAYA_API_KEY"):
        headers["Authorization"] = "Bearer " + os.environ["LAYA_API_KEY"]
    document = _post_json(settings["laya"] + "/v1/systemone", body, headers,
                          settings["timeout"])
    if not isinstance(document, dict):
        raise BackendError("laya returned %s, not an object"
                           % type(document).__name__)
    return document


def _cloud(body: dict, settings: dict, *, kind: str, url: str, key: str | None,
           model: str) -> dict:
    if not key:
        raise BackendError(
            "no API key configured for the %s backend (%s)"
            % (kind, "OPENROUTER_API_KEY" if kind == OPENROUTER else "HF_TOKEN"),
            status=503, kind="backend_unconfigured")
    answerable, skipped = evidence_gate(body)
    if not answerable:
        # Nothing a text model could answer: report it instead of asking one.
        return {"model": model, "answers": {}, "usage": {},
                "routing": {"backend": kind, "skipped": skipped,
                            "note": "every question needs evidence this state "
                                    "does not carry"}}
    started = time.monotonic()
    document = _post_json(
        url,
        {"model": model, "messages": build_prompt(body["state"], answerable),
         "temperature": 0, "max_tokens": MAX_TOKENS},
        {"Authorization": "Bearer " + key}, settings["timeout"])
    choices = document.get("choices") or []
    if not choices:
        raise BackendError("%s returned no choices" % kind)
    text = ((choices[0].get("message") or {}).get("content") or "")
    answers, rejected = parse_answers(text, answerable)
    return {"model": document.get("model") or model,
            "answers": answers,
            "usage": document.get("usage") or {},
            "routing": {"backend": kind, "elapsed_seconds":
                        round(time.monotonic() - started, 3),
                        "skipped": skipped, "rejected": rejected}}


def call_openrouter(body: dict, settings: dict) -> dict:
    return _cloud(body, settings, kind=OPENROUTER, url=OPENROUTER_URL,
                  key=settings["openrouter_key"],
                  model=settings["openrouter_model"])


def call_hf(body: dict, settings: dict) -> dict:
    return _cloud(body, settings, kind=HF, url=HF_ROUTER_URL,
                  key=settings["hf_key"], model=settings["hf_model"])


HANDLERS = {LOCAL: call_local, OPENROUTER: call_openrouter, HF: call_hf}


def dispatch(body: dict, settings: dict, prefer: str | None = None) -> dict:
    """Try the chosen backend, then the configured fallbacks, and REPORT each.

    A refusal is not silently retried across backends: each attempt is recorded
    with its reason, so a caller can tell "the local model said unevidenced"
    from "laya was down and OpenRouter answered instead". The answer's own
    ``routing`` says which backend actually produced it.
    """
    order, seen = [], set()
    for name in ([prefer] if prefer else []) + [settings["backend"]] + settings["fallback"]:
        if name and name not in seen:
            seen.add(name)
            order.append(name)
    attempts = []
    for name in order:
        handler = HANDLERS.get(name)
        if handler is None:
            attempts.append({"backend": name, "ok": False,
                             "reason": "unknown backend; known: %s"
                                       % ", ".join(BACKENDS)})
            continue
        try:
            document = handler(body, settings)
        except BackendError as exc:
            attempts.append({"backend": name, "ok": False, "kind": exc.kind,
                             "reason": str(exc)})
            continue
        routing = dict(document.get("routing") or {})
        routing["backend"] = name
        routing["attempts"] = attempts
        if len(order) > 1:
            routing["fallback_used"] = bool(attempts)
        document["routing"] = routing
        document.setdefault("usage", {})
        return document
    raise BackendError(
        "no backend answered (%s)"
        % "; ".join("%s: %s" % (entry["backend"], entry["reason"])
                    for entry in attempts) or "none configured",
        status=503, kind="no_backend")


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


def _send(handler, status: int, payload: dict) -> None:
    body = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    server_version = "%s/%s" % (SERVICE, VERSION)

    def log_message(self, format, *args):  # noqa: A002 - base class names it this
        if (os.environ.get("SYSTEMONE_LOG_LEVEL") or "").lower() == "debug":
            super().log_message(format, *args)

    def _authorised(self, settings: dict) -> bool:
        if not settings["api_key"]:
            return True
        header = self.headers.get("Authorization") or ""
        return header == "Bearer " + settings["api_key"]

    def do_GET(self):  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            settings = config()
            _send(self, 200, {
                "ok": True, "service": SERVICE, "version": VERSION,
                "backend": settings["backend"],
                "fallback": settings["fallback"],
                "auth_required": bool(settings["api_key"]),
                # Whether a key EXISTS -- never the key.
                "configured": {
                    "local": True,
                    "openrouter": bool(settings["openrouter_key"]),
                    "hf": bool(settings["hf_key"]),
                },
                "models": {"openrouter": settings["openrouter_model"],
                           "hf": settings["hf_model"]},
            })
            return
        _send(self, 404, {"error": "no route %s" % path, "kind": "not_found"})

    def do_POST(self):  # noqa: N802
        settings = config()
        if not self._authorised(settings):
            _send(self, 401, {"error": "unauthorised", "kind": "unauthorised"})
            return
        path, _, query = self.path.partition("?")
        if path not in ("/v1/systemone", "/systemone"):
            _send(self, 404, {"error": "no route %s" % path, "kind": "not_found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            _send(self, 400, {"error": "body must be 1..%d bytes" % MAX_BODY_BYTES,
                              "kind": "bad_request"})
            return
        try:
            body = json.loads(self.rfile.read(length))
            body = validate_request(body)
        except BackendError as exc:
            _send(self, exc.status, {"error": str(exc), "kind": exc.kind})
            return
        except json.JSONDecodeError as exc:
            _send(self, 400, {"error": "invalid JSON: %s" % exc,
                              "kind": "bad_request"})
            return
        prefer = self.headers.get("X-SystemOne-Backend")
        if not prefer and query:
            for pair in query.split("&"):
                name, _, value = pair.partition("=")
                if name == "backend":
                    prefer = value
        prefer = (prefer or "").strip().lower() or None
        try:
            document = dispatch(body, settings, prefer)
        except BackendError as exc:
            _send(self, exc.status, {"error": str(exc), "kind": exc.kind})
            return
        _send(self, 200, document)


def build_server(host: str | None = None, port: int | None = None):
    settings = config()
    server = ThreadingHTTPServer((host or settings["host"], port or settings["port"]),
                                 Handler)
    server.daemon_threads = True
    return server


def main(argv=None) -> int:
    settings = config()
    server = build_server()
    bound = server.server_address
    print("%s %s listening on %s:%d (backend=%s, fallback=%s)"
          % (SERVICE, VERSION, bound[0], bound[1], settings["backend"],
             ",".join(settings["fallback"]) or "-"))
    if settings["backend"] == LOCAL or LOCAL in settings["fallback"]:
        print("  local    -> %s" % settings["laya"])
    if settings["openrouter_key"]:
        print("  openrouter -> %s" % settings["openrouter_model"])
    if settings["hf_key"]:
        print("  hf       -> %s" % settings["hf_model"])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
