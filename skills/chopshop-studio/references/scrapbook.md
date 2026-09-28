# Scrapbook + Composite — favouriting, left sidebar, surface editing, compositing

A feature built in slices. The composite builder IS built; the prep-config
visual preview is NOT.

## What exists

### Scrapbook (its own store)

- **Store is its own data.** `ScrapbookItem` + `ScrapbooksController`.
  Favouriting a runner artifact COPIES its bytes into `storage/scrapbook/`
  (via `RunnerClient.get_file`). `job_id` is provenance only — no FK — so
  deleting the job never touches the scrapbook. `owner` is NULL today
  (single operator), pivot-ready like `Job`'s.
- **Endpoints** (login-gated, controller `scrapbooks`): `GET /scrapbook`,
  `POST /scrapbook`, `POST /scrapbook/import` (edited PNG/JPEG, magic-byte
  validated), `DELETE /scrapbook/:id`, `GET /scrapbook/:id/file`,
  `POST /scrapbook/:id/use` (copy into uploads → new-job form, redirect),
  `POST /scrapbook/:id/reference` (copy into uploads as a FLUX reference
  image — returns the upload JSON, raster-only; SVG/PDF refused).
- **UI**: left drawer `#scrapbookSidebar` + fixed star `#scrapbookToggle`
  in the layout, every authed page. Favourite buttons (partial
  `scrapbook/_fav_button`) on job-show source/invert tiles and each
  candidate + finished-proof row. Drawer is 240px, single-column; each card
  is a fixed 176px centred thumbnail with an `&times;` remove button in its
  top-right corner, then filename and a size line (formatted client-side from
  the byte count the index sends). Per item actions: Trace / Edit.
- **Editor**: canvas modal (`scrapOpenEditor` in aether.js) — drag-crop,
  cut (drag a region → clipboard, destination-out so it leaves a transparent
  hole), paste (translucent preview under the pointer, clamped on-image,
  committed on click, clipboard kept after drop), destination-out erase, and
  hue-rotate baked on save, via `/scrapbook/import`. Cut hands straight to
  Paste. Cut/paste state (`clip`, `pasteX`, `pasteY`) is declared once and
  reset on `scrapOpenEditor` so a new image never inherits a stale clipboard.

### Composite builder

- `Composite` model (name, width, height, background, json `layers`, owner)
  + `CompositesController` + `app/views/composites/show.html.erb` (canvas
  page, page-level script — NOT aether.js; it is one page's tool).
- The page is titled **Compose** and is NOT in the header nav. It is reached
  from the Run Job page via a **Compose** `head-action--below` button under
  the Run Job button (the same slot the JSON page uses for its secondary
  button). The Compose page head carries its own Run Job button.
- Routes are NAMED and deliberately explicit: `new_composite_path`,
  `create_composite_path`, `list_composites_path`, `composite_layers_path`,
  `composite_update_path`, `flatten_composite_path`, `use_composite_path`,
  `delete_composite_path`. A layer is
  `{key, name, src, x, y, w, h, z, opacity, hue, visible}`.
- **Sensible defaults**: a new layer lands centred at 40% of the canvas,
  sized to 40% of it. Anything else means placing every piece by hand
  before the composite reads as a composition.
- Move (drag), resize (corner handle), plus per-layer x/y/w/h, opacity and
  hue sliders, visibility, bring-forward/send-back.
- **Geometry is in COMPOSITE pixels**; pointer positions are divided by the
  stage scale, so placement survives a window/canvas resize.
- **Paint order is a layer's `z`, not array order** — reordering is a
  one-number change and a hand-edited payload still paints sanely.
- **Flatten** rasterises at full size into an OFF-SCREEN canvas (the
  preview's scale must never leak into exported pixels) and POSTs the PNG.
  The server stores it twice: a `ScrapbookItem` (re-usable artefact) and an
  upload in `storage/uploads` (the only place the runner reads).
- **Run Job is one click.** The head's Run Job button saves (create/update),
  flattens, then POSTs the upload path to `use_composite_path`, which hands
  it to the new-job form — a brand-new composite runs with no separate
  "create" step. `create`/`update` answer JSON with
  `{ id, flatten_url, use_url }` (`run_handoff` in the controller), which is
  what lets the page chain save → flatten → run without a page reload. The
  excess "Create composite" / "Use as job source" buttons are gone.

## Key rules / pitfalls

- **A json column given a JSON *String* casts to `[]` and silently drops
  every layer.** `Composite#layers` must be parsed explicitly
  (`parse_layers`) on both create and update. This is the single easiest
  way to lose a composite's work.
- `parse_layers` returns **nil** for absent/malformed payloads, deliberately
  distinct from `[]` — `[]` is a legitimate value (all layers removed) and
  must not be confused with "mangled, keep what you had". Update assigns
  only when non-nil; other fields are assigned only when actually posted
  (a partial update must not nil a required field).
- The scrapbook drawer is SOLID (`rgba(10,10,15,0.97)`), NOT the glass blur:
  the blur/saturate tokens are pinned by `GlassBarsAndSolidTablesTest` to
  the header and footer bars alone. Reusing them in the drawer breaks it.
- The drawer SHARES the screen, not an overlay: `body.scrapbook-open` pads
  `nav.topbar`, `main.container` and the footer container left by
  `--scrapbook-w`, published by the script from the drawer's measured box.
  One source of truth so a drawer capped at 85vw cannot leave a gap. Do NOT
  push `body` itself — the background orbs/canvases are `position: fixed`.
- The star hides while the drawer is open (`body.scrapbook-open
  .scrapbook-toggle { display: none; }`): it is the drawer's opener, and a
  fixed handle over the drawer it just opened re-toggles nothing.
- **Close conventions are two, deliberately.** The drawer's close is an
  inline SVG ✕ (`.scrapbook-close` with `data-scrap-close`) on the drawer's
  vertical edge — NOT a word button — wearing the login page's sunspot orb
  accent (the reused `.login-sun-*` layers behind a thin ✕). Any control
  with `data-popup-close` must use `class="popup-close"` + `&times;` and
  must NEVER be a word button (`PopupCloseStandardTest` pins this for all
  popups). The composite's scrapbook modal is a popup → `&times;`.
- Favouriting COPIES bytes, never references a job path — surviving job
  deletion is the whole requirement.
- **Delete asks first.** `scrapDelete` gates removal through `csConfirm`
  (the glass modal), naming the item in the message — removal is destructive
  and has no undo.
- **`reference` is raster-only.** A FLUX reference image is something the
  generator transforms, so SVG/PDF items are refused by magic-byte check.
  The endpoint copies scrapbook bytes into `storage/uploads` and returns the
  SAME JSON shape as the upload endpoint (`path`/`preview_url`/`name`/`size`),
  so the reference field's drop handler consumes it unchanged.
- Kind is derived server-side from the runner filename, never trusted from
  the client. `/scrapbook/import` validates by magic number, not filename.
- In tests, `File.read` on a source file tags it with the locale default
  encoding; a UTF-8 regexp literal then raises
  `Encoding::CompatibilityError`. Use `.read(encoding: "UTF-8")`.

## Not built

- **Prep-config visual preview** — toggle JSON prep configurations and see
  the effect on an image live. (This is the last slice of the standing
  goal: favouriting + sidebar, editor crop/cut/paste/erase/hue, and the
  composite builder are all shipped.)

## Tests

`scrapbook_test.rb`, `scrapbook_ui_test.rb`, `scrapbook_share_screen_test.rb`
(drawer close/star-hide/share-the-screen invariants),
`composite_test.rb` (defaults, layer round-trip, malformed payload, flatten
twice-stored, non-PNG refused, path-traversal refused, nav order),
`scrapbook_editor_tools_test.rb` (tool surface, clipboard state, cut erases
transparent, cut→paste handoff, paste clamping).
`AuthGateTest` enumerates the gated controllers — add new ones there.
`scrapbook_test.rb` also covers `reference` (copies a raster into uploads,
refuses SVG/PDF); `flux_job_test.rb` pins the reference field's drop wiring.
Full suite: 427 runs, 0 failures.
