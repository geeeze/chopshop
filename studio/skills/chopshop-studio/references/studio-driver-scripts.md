# Driving the studio from a scratch python script

The long demos (conference/tournament runs, sheet composes, benchmarks) are
driven over HTTP by scratch scripts — `chopshop_demo.py` for sessions, job submit
and poll, `chopshop_gamut.py` for compose frames and layers, then a per-task
driver. These are the traps that cost real time.

## Sessions and per-user isolation

- **Fetch a job's files with the session of the job's OWNER.** A non-owner's
  request can come back as an HTML error page at HTTP 200; a naive `<svg` sniff
  accepts it and you then "compose" the error page. Guard on both halves:
  the root `<svg` is present AND there is no `<!doctype html` / `<html`.
- **One cookie jar per handle.** The password is the identity; three accounts must
  never share a session object, and re-login (a 422 on submit usually means the
  token rotated) must rebuild the jar.

## Composing pages

- **A layer's `src` is NOT raw SVG text.** A document must first be stored to
  `storage/uploads` and referenced as `/jobs/upload_preview/<name>`; passing the
  bytes through is answered with `cannot read the layer's source` and the text
  echoed back. Store the frame, then place it.
- **Strip everything before the root `<svg` when embedding a fetched document as
  a layer.** Traced candidates open with `<?xml …?>` and a generator comment; an
  XML declaration is only legal at the very start of a document, so a layer that
  keeps one is refused as not well-formed XML. The same strip also cures
  "Extra content at the end of the document", which is what an HTML error page
  cached under an SVG name looks like.
- Compose in VECTOR mode for anything that was drawn or traced, and RASTER only
  for real pixels (a generated render, the 3D frames, a proof PNG).

## Long runs

- File long jobs with `terminal(background=True, notify=True)` and poll on the
  notification; the same run posted to the studio page is polled through
  `chopshop_demo.poll`, which reads the served page's state, not the runner.
- **Never `pkill -f <pattern>` to stop a job you launched from the agent's own
  shell.** The pattern can match the agent's own command line and the tool
  self-terminates mid-turn (`kill hermes/gateway process`). Kill the explicit PID
  instead, or let the notification arrive.
- A batch of finished background processes is mostly EARLIER ATTEMPTS of steps that
  later succeeded. Triage each one: name the cause, confirm what superseded it,
  then verify the final state of the artifacts — never re-run the batch.
- **Make the state file's writes idempotent (upsert by name).** A killed or
  retried run re-notes the same job, and the duplicate is invisible until you
  aggregate. After any batch of failures, dedupe by name (keep the richest record)
  and re-check that every recorded artifact still exists on disk.

## Proving a change did not move anything

- **Verifying a layout refactor is a BYTE comparison.** Rebuild each frame from the
  new code path and compare with the artifact the old path stored; identical bytes
  is the proof, and it is decisive in seconds.
- **Do not trust a visual read of a rendered sheet for GEOMETRY.** Extra cards
  drawn past the page edge, or a stats box with the last row sitting on its border,
  look plausible in a rendered preview. Assert from the SVG text: count the card
  groups, take the maximum text y and compare it with the page height, and check
  that a drawn element's box actually contains its own rows.
- Determinism checks compare the BYTES of two runs, not frame NAMES — every render
  lands under its own hash, so names differ between runs by design.
