# Verifying and measuring a rendered CSS effect

Rules for any effect whose correctness is "it should look right" — a glow, a spinning highlight, an
animated border. `getComputedStyle` is necessary but never sufficient, and naive pixel probes lie.

## Pin the phase before measuring anything that rotates

"Brightest pixel in region X" on a LIVE frame measures every animation in X, not a property of the
effect: a spinning highlight read lum 130 at one rotation and lum 29 at another, so the identical
check flipped green/red across runs while the CSS never changed. Never tune an animation and then
compare such a reading against an earlier run. Pin it first — a registered `@property` can be set
directly, so inject `animation: none !important; --angle: 90deg !important` and the frame becomes
deterministic — then assert on the pinned frames. Derive motion from the DIFFERENCE between two
pinned phases (e.g. 522/2688 annulus px changed, peak delta 87), and prefer "the bright point MOVES
when the angle changes" over any model of how a conic gradient is oriented — a hand-rolled bearing
model was wrong and nearly produced a false red. An assertion of "bright" also needs a threshold;
a blurred band at reduced opacity legitimately measures well below pure white, so calibrate the
threshold against the thing's own neighbours (the icon's indigo `box-shadow` glow sits near 20)
rather than against white.

## Freeze the decoration, and take the noise floor from two identical frames

Comparing "how strong is this effect" across two runs is invalid whenever anything else on the page
animates. The login and job pages run a particle canvas plus three `.bg-gradient-orb` elements at
`blur(150px)`/`blur(260px)`, and their contribution made the frame-diff control baseline 0.01 in one
run and 9.14 in the next — enough to swamp the effect being measured and to produce a confident,
wrong verdict. Freeze the decoration into the measurement (hide it:
`canvas, .bg-gradient-orb, .welcome-overlay { display: none !important }`, and stop the clock:
`for (const a of document.getAnimations()) { a.pause(); a.currentTime = 1000 }`). Capture TWO frames
of the identical configuration as an explicit noise floor (this drove residual noise to 0.000), and
inject the OLD values as a style so before and after come off ONE background state instead of two.

## A reference frame must change exactly one variable

When a reference frame isolates one variable, keep every OTHER difference out of it. The wordmark's
"highlight off" frame also cleared `-webkit-text-stroke` and set `color: inherit`, which swapped the
glyphs between hollow and solid and produced a 98% "no change" reading that hid the real 25%
reduction; removing only the travelling band, leaving the outline, made the measurement mean
something. Check what else your reference frame alters before trusting a delta.

## `getComputedStyle` traps that produce false reds

- `background-clip` computes as a PER-LAYER list (`"text, text"`) once `background-image` has two
  layers — match with a regex, never equality.
- A pseudo-element's `@property`-animated `--angle` is not readable from the host element (it reads
  the initial `0deg` there), and chrome omits `from` from the serialized gradient while the value is
  0 — so a null parse means 0deg, not "not animating". Read the animating pseudo, or use
  `document.getAnimations()`.
- `getAnimations()` reporting an animation on `div.logo-icon` is the two `::after`/`::before` bands,
  not the element itself. Filtering by `animationName` counts them correctly.

## The post-login overlay will silently poison a before/after capture

The login flow renders a full-screen `.welcome-overlay` that types text over the page and clears
~1.7s later. Capturing "before" while it is still up and "after" once it has gone fingerprints the
OVERLAY, not the element under test — that produced a confident "33% of the button's pixels change
once it has been hovered" which was pure overlay fade, and would have justified a fix for the wrong
reason. Either wait it out (poll `getComputedStyle(o).opacity > 0.01 && display !== 'none'` until it
is gone) or hide it with the rest of the decoration before any capture. With it cleared and the
decoration frozen the control noise floor was 0.03, at which point 0.1% means "identical" and 0.6%
means "only the hover lift" — numbers you can actually act on.

## Verify in the browser the operator actually uses

nginx's access log names the operator's browser (his is Firefox 140); every local driver here is
Chromium, so a browser-specific failure is invisible. A headless Firefox needs no package manager:
`curl -sL -o ff.tar.xz "https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US"`,
extract it, then `MOZ_HEADLESS=1 ./ff/firefox --headless --no-remote -profile <dir> --window-size=1440,1000 --screenshot out.png <url>`.
Screenshot mode takes no cookies, so point it at a public page (`/login` carries a `.btn-primary`
scissor and the orbs). Measured that way Firefox renders the `@property` conic-gradient ring
exactly like Chromium — 29% saturated pixels around the button in both, avg luminance 44.2 vs 46.7 —
so do NOT assume a browser bug without this check. `--screenshot` cannot log in; for authenticated
pages compare the served HTML/assets plus the Chromium pixels instead.

## Ring vs shadow: which one is "the glow"

The conic ring and the ambient `box-shadow` contribute very differently, and the shadow is what
reads. Around a `.btn-primary`: the full-opacity ring alone is worth ~90 saturated px in the halo,
while adding `0 20px 60px rgba(99,102,241,0.5)` takes it past 2000. So a hover-only shadow makes a
button look inert no matter how strong the ring is — the reason the buttons appeared to "only show
the effect when hovered" while every computed style said the ring was on. Per-row `.btn-sm` buttons
in one candidate table are ~40px apart, and at full strength the bloom fills the gaps between them
(measured: gap luminance 39-61 against a 27 background); `0 6px 20px` brings the gaps down to ~32
saturation while keeping the glow. Check that table before raising the button glow again.

## Calibration points for the header highlight

Subdued state: ring `alpha 0.85 + opacity 0.72`, face sweep `0.36`, wordmark band `0.75`. Measured
as a frame diff against a highlight-free reference with the decoration frozen (noise 0.000): mean
4.58 over the icon and 3.89 over the wordmark, i.e. 77% and 75% of the previous intensity — still
far above noise. A pinned-angle reading puts the ring's peak at lum 102 with `|R-G| = 0` (white),
against the icon's indigo glow near 20; CHROMA, not raw brightness, is what separates the ring from
that glow. Reuse these numbers as the reference points when asked to make it stronger or weaker.
