require "test_helper"

# The scrapbook editor's tool surface. These pin the CONTRACT of the surface
# editing the operator asked for (crop / cut / paste / erase / colour shift):
# the four tools exist, the clipboard state the cut/paste depends on is declared
# once, and cut hands off to paste rather than leaving the operator stranded.
#
# Issue #67's drawer-copy pins live here too, because the drawer's markup is a
# STRING BUILT IN THIS FILE: what the operator reads is in aether.js, not in a
# template, so a template test would prove nothing about it.
class ScrapbookEditorToolsTest < ActiveSupport::TestCase
  def js
    Rails.root.join("app/javascript/aether.js").read(encoding: "UTF-8")
  end

  test "the editor exposes crop, cut, paste and erase as tools" do
    %w[crop cut paste erase].each do |tool|
      assert_includes js, %(data-scrap-tool="#{tool}"),
        "the #{tool} tool must be in the editor toolbar"
    end
  end

  test "the clipboard is a single declared piece of state, cleared on open" do
    assert_match(/clip: null, pasteX: 0, pasteY: 0/, js,
      "cut/paste state must be declared on the editor object")
    # Opening a new image must not carry a stale clipboard from the previous one.
    assert_match(/scrapEditor\.clip = null;/, js,
      "scrapOpenEditor must reset the clipboard")
  end

  test "cut erases the region with destination-out, leaving transparency" do
    # A cut on a PNG must leave a transparent hole, not a white box — the whole
    # point of cutting versus merely copying.
    assert_includes js, "globalCompositeOperation = 'destination-out';",
      "cut must erase with destination-out"
  end

  test "cut hands straight to paste" do
    # The operator cut to place it somewhere: don't make them pick the tool.
    assert_match(/scrapEditor\.tool = 'paste';/, js,
      "applyCut must switch the tool to paste")
    assert_includes js, "function setActiveTool()",
      "the programmatic switch must move the active class with it"
  end

  test "paste is clamped so the clipboard cannot be dropped off-image" do
    assert_includes js, "function clampPaste(",
      "paste placement must be clamped"
  end

  # Issue #66: the drawer offered Edit on EVERY item, and the editor is a
  # raster tool. A vector (dimension-less SVG) loads as 0x0, the clamp
  # silently makes it 1x1, and the operator gets an unusable canvas with no
  # explanation. Two pins: the Edit affordance is emitted only for raster
  # items, and the loader itself refuses a zero-dimension image.
  test "the drawer offers Edit only on raster items" do
    # The whole Edit button is wrapped in a !it.vector ternary so a vector
    # item gets NO edit affordance — not a disabled or misleading one.
    assert_match(/!it\.vector \? .*data-scrap-edit .*: ''/, js,
      "the Edit button must be emitted only when !it.vector")
    # The vector flag the drawer branches on must be the one the JSON carries.
    assert_match(/vector: item\.vector\?/, Rails.root.join("app/controllers/scrapbooks_controller.rb").read,
      "the scrapbook JSON must carry item.vector so the drawer can gate on it")
  end

  test "the editor loader refuses a zero-dimension image instead of a 1x1 canvas" do
    assert_match(/img\.naturalWidth === 0 \|\| img\.naturalHeight === 0/, js,
      "scrapLoadEditorImage must guard the zero-dimension case")
    assert_includes js, "this item has no pixel dimensions to edit — it is a vector",
      "the guard must set an explicit hint on #scrapEditorHint"
    # The guard must bail before the canvas is built: it returns without
    # reaching the Math.max(1, …) clamp.
    guard_idx = js.index("naturalWidth === 0")
    assert_not_nil guard_idx
    guard_block = js[guard_idx..(guard_idx + 400)]
    assert_includes guard_block, "return;",
      "the zero-dimension guard must return before building the canvas"
  end

  # ---- Issue #67: what the drawer SAYS ------------------------------------
  #
  # Two strings the operator reads, both wrong in the shipped drawer.
  #
  #  1. The per-item button was labelled "Trace" with a "Trace as a new job"
  #     tooltip, and it does not trace: its handler posts to scrapbooks#use,
  #     which copies the item into uploads and opens the Run Job form. The
  #     visible word promised a pipeline stage this shop has never run on a
  #     scrapbook item, and the operator who wanted a trace got a job form.
  #  2. The empty state said "Use the &#9734; on a source…" — a star glyph.
  #     There is no star anywhere in the app: the favourite control is the
  #     SCISSOR ORB (see scrapbook/_fav_button.html.erb, whose doc says so in
  #     words). The copy named a control that does not exist, so the operator
  #     hunted for a star that was never drawn.
  #
  # Both are pinned as refutations as well as assertions, because an assertion
  # that only checks the new truth still passes the old lie.
  test "the drawer's per-item button says Use as source, not Trace" do
    # The word the operator reads.
    assert_includes js, %(title="Use this item as the source for a new job">Use as source</button>),
      "the drawer action must name what it does — open the Run Job form — not a trace"
    refute_includes js, %(<title="Trace as a new job">Trace<),
      "the old mislabel: the handler is scrapbooks#use, which never traces"
    # The attribute stays: it is the internal handle the delegated handler and
    # aether.js's own code speak, and renaming it is a refactor, not a copy fix.
    assert_includes js, "data-scrap-trace",
      "the data-scrap-trace handle must survive the relabel"
  end

  test "the drawer empty state names the action, not a star glyph" do
    assert_includes js, "Favourite a source, invert, candidate or proof to keep it here.",
      "the empty state must name the ACTION, and it is the scissor orb that performs it"
    refute_includes js, "&#9734;",
      "there is no star in this app — the favourite is the scissor orb"
  end
end
