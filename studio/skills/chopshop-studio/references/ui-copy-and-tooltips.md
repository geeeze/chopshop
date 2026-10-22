# Strings, tooltips and help text

Rules for anything the operator can READ. The prose in this app is judged harder
than the CSS: he reads it, and he will tell you when it is wrong.

## Length is a feature, not a shortfall

Default to the shortest string that carries the meaning. The usual correction is
not "wrong wording" but **too many words**.

- A tooltip is an ICON or a couple of words. If a `title=` runs past a short
  phrase, it is a paragraph pretending to be a tooltip. `title="🤞"` is a
  complete, accepted tooltip.
- An emoji is a legitimate tooltip payload. He asks for them by name
  ("fingers crossed icon/emoji please") and means the emoji *alone*.
- Once the meaning is in the `?` popup, do NOT also print it under the control.
  The hint line and the popup are two homes for one sentence; pick one. Moving
  the card's prose into its `?` is usually the right direction, because the
  popup is where the other cards' explanations already live.
- Page blurbs: 2-3 sentences. Sub-titles under a heading: 1-2.

## Do not repeat a claim in two places

Before adding a string, grep for what the string already says elsewhere on the
page. A `.prep-note` that restates `help-prep` in slightly different words is
noise, and its removal is a win, not a loss. When you move text into a popup,
check the popup genuinely covered every claim first — then pin that with a
test so the coverage cannot silently lapse.

## A string that describes code behaviour is a claim about the code

The JEV page's `?` help explains what the annotator reads and returns. Written
from memory, it asserted the confidence floor "does not apply" to a score
answer. It does: the code falls through to the top of the answer's
`probabilities` and gates on that. The page was confidently wrong, which is
worse than silent.

So:

1. Read the implementation before writing the sentence. Transcribe the keys,
   the branches and the thresholds; do not paraphrase from the feature's name.
2. Pin each claim in a test **against the implementation**, not against the
   page. A help screen that has drifted from the code it describes is a defect.
3. Where a claim was wrong once, make the test **refute the wrong wording**:
   `refute_includes text, "does not apply"`. An assertion that only checks the
   new truth still passes the old lie.
4. When the code is in a sibling repo, read it at `../<repo>/` from the app root
   and keep the test's path in a constant so a moved source fails loudly.

## Unicode escapes: Ruby sees them, raw HTML does not

`"\u{1F91E}"` is processed inside a **Ruby string** and printed literally
anywhere the template is **raw HTML**. One field, two languages:

```erb
<%= f.text_field :name, title: "\U0001F91E" %>   <%# Ruby: renders 🤞 %>
<div class="hint">\U0001F91E …</div>            <%# raw HTML: prints \U{1F91E} %>
```

Write the real character in both. When a test asserts an emoji, compare with
`codePointAt` in the browser probe — `charCodeAt` returns the **high surrogate**
of a surrogate pair, so `charCodeAt(0) === 0x1F91E` is always false and looks
like a missing glyph.

For an icon glyph, prefer the text-presentation codepoint over the
colour-presentation one: `U+1F5AB` (floppy) not `U+1F4BE`, which renders as a
full-colour emoji inside a small monochrome button.

## An editor for a file this app does not own must say so

When a page offers to "edit" a config that lives in ANOTHER repo and is read
from there by the pipeline, a Save button would be a lie — the write has nowhere
to go. Make it a viewer plus copy-out, and say that in the popup, in the same
breath as the copy button: this page cannot write there, copy it out and commit
it in the repo that owns it, where its own tests check it.

The file's own explanatory keys (`_comment`, `_grounding_note`, `_metrics_note`)
are the help text, transcribed rather than paraphrased, so the popup cannot drift
from the file it explains — and the test asserts those exact strings are present.
Add the one field that is not in the file (the entry-key summary, the remedy
count) as a labelled extra rather than folding it into a transcribed note.

## Match the requested scope exactly, even when more would help

"He wants it just to have nothing but the fingers crossed" means the tooltip is
one emoji and the hint underneath carries no emoji. Do not add an explanatory
sentence because it seems more informative, and do not repeat the payload below
the control — the ask named a payload, and extra prose reads as nagging. When a
later sentence names a button or a file, it must be updated in the SAME change or
it becomes a dead reference; grep for the old word after any label change.

## Accessible names

The visible label must be inside the accessible name (WCAG 2.5.3). A glyph-only
control needs `aria-label`; a control with visible text does not get a
contradicting one. `title` and `aria-label` should agree — the tooltip is read
out on some ATs.

If a string names a button ("JSON shows the conf."), **rename the button in the
same change** or the sentence is a dead reference. Grep for the old word
after any button-label change.
