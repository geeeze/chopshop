require "test_helper"

# The scrapbook editor's tool surface. These pin the CONTRACT of the surface
# editing the operator asked for (crop / cut / paste / erase / colour shift):
# the four tools exist, the clipboard state the cut/paste depends on is declared
# once, and cut hands off to paste rather than leaving the operator stranded.
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
end
