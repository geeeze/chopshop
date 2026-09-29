require "test_helper"

# The FRAME: one left column holding two panels — the scrapbook drawer and the
# composites panel — with a single close orb that cycles between them.
#
# It is pinned here because it shipped DEAD once and every test stayed green: the
# panel was in the DOM, the cycle script was in the layout, and the only thing
# that ever revealed a panel was the `.open` class — which nothing added to the
# composites panel, while the script toggled the `hidden` attribute instead. A
# `hidden` panel is still at `translateX(-100%)`, so it is off-screen either way
# and no server-side assertion could tell the difference. These tests assert the
# MECHANISM (which class, which states, which control) rather than the presence of
# markup, so the same silence cannot come back.
class FrameCycleTest < ActiveSupport::TestCase
  def layout
    Rails.root.join("app/views/layouts/application.html.erb").read
  end

  def css
    Rails.root.join("app/assets/stylesheets/application.css").read(encoding: "UTF-8")
  end

  def js
    Rails.root.join("app/javascript/aether.js").read
  end

  # The cycle order, as the module's own table. Parsed from source so the test
  # follows the code rather than a copy of it.
  def frame_next
    body = js[/var FRAME_NEXT = \{(.*?)\};/m, 1]
    refute_nil body, "the frame's state table is gone: the cycle has no order"
    pairs = body.scan(/(\w+):\s*'(\w+)'/)
    refute_empty pairs, "the state table is unreadable"
    pairs.to_h
  end

  # --- the two panels ---

  test "both panels are panels of the frame, each carrying the frame's orb" do
    doc = Nokogiri::HTML(layout)
    panels = doc.css("aside.scrapbook-sidebar")
    assert_equal 2, panels.size,
      "the frame is two panels; a third would need its own state and cycle step"

    %w[scrapbookSidebar compositeSidebar].each do |id|
      panel = doc.at_css("aside##{id}")
      refute_nil panel, "#{id} is one of the frame's panels"
      orb = panel.at_css("> .scrapbook-close[data-scrap-close]")
      refute_nil orb, "#{id} needs the orbit control: in its own state it is the " \
        "only panel on screen, so an orb living on its sibling would strand it"
      refute_nil orb.at_css(".scrapbook-close-orb"), "#{id}'s orb keeps the halo"
      %w[login-sun-layer login-sun-burst login-sun-pink].each do |layer|
        assert_equal 1, orb.css(".#{layer}").size,
          "#{id}'s orb keeps #{layer}: the shared sunspot recipe " \
          "(FavouriteOrbTest pins the other copy of it)"
      end
    end
  end

  # --- one mechanism, or the frame is a lie ---

  test "a panel is revealed by the open class, never by the hidden attribute" do
    # The scrapbook drawer's mechanism (and the one the page-share CSS reads).
    assert_match(/\.scrapbook-sidebar\.open\s*\{[^}]*transform:\s*translateX\(0\)/,
                 css, "the drawer is shown by .open")
    # The composites panel must use the SAME one.
    rule = css[/\n\.composite-sidebar\.open\s*\{(.*?)\n\}/m, 1]
    refute_nil rule, "the composites panel is styled for its open state"
    assert_includes rule, "display: flex"
    assert_includes rule, "transform: translateX(0)",
      "without this the panel keeps the drawer's translateX(-100%) and stays off-screen"

    closed = css[/\n\.composite-sidebar\s*\{(.*?)\n\}/m, 1]
    refute_nil closed, "and it has a closed state"
    assert_includes closed, "display: none", "closed means out of the flow"

    # The dead version: an inline script flipping `hidden` on both panels.
    refute_match(/\.hidden\s*=\s*(true|false)/, layout,
      "the frame's visibility is the class, not the attribute")

    # SCOPED to the frame's own function, because the page uses the `hidden`
    # attribute for plenty of other things (popups, toolbox buttons, the
    # reference image). A file-wide grep for `.hidden =` is a check that cannot
    # pass — it fails against correct code and says nothing about the frame.
    apply = js[/function frameApply\(state, persist\) \{(.*?)\n  \}/m, 1]
    refute_nil apply, "the frame's apply() is the one writer of a panel's visibility"
    assert_match(/classList\.toggle\('open'/, apply,
      "it drives the same class the CSS reads")
    refute_match(/\.hidden\s*=/, apply,
      "and it never reaches for the attribute instead")
  end

  test "both panels up splits the column into two bands" do
    assert_match(/body\.frame-split\s+\.scrapbook-sidebar:not\(\.composite-sidebar\)\s*\{[^}]*bottom:/,
                 css, "the scrapbook yields the column's lower band")
    assert_match(/body\.frame-split\s+\.composite-sidebar\s*\{[^}]*height:/,
                 css, "and the composites take it")
    assert_includes js, "classList.toggle('frame-split'",
      "the split marker is written by the frame, so it cannot outlive the state"
  end

  # --- the cycle, and why its order is the order ---

  test "the orb cycles the frame and a double-click closes it" do
    order = frame_next
    assert_equal %w[scrap both comp none].sort, order.keys.sort,
      "four states, named for what is open"
    assert_equal order.keys.sort, order.values.sort,
      "every state must BE a state (a typo here strands the cycle on a value " \
      "the apply() call would reject and default away from)"

    assert_match(/if \(e\.detail === 2\) frameApply\('none'\); else frameCycle\(\);/,
                 js, "one click advances, a double-click closes the frame")
    assert_match(/e\.target\.closest\('\[data-scrap-close\]'\)/, js,
      "the orb's click is the frame's control (ScrapbookShareScreenTest pins this too)")
    refute_match(/data-scrap-close\]'\)\) \{ scrapbookClose\(\)/, js,
      "an orb that only closes the drawer cannot reach the second panel")
  end

  test "every state is reachable from a control that is on screen in it" do
    order = frame_next
    # The star opens 'scrap'. From there the cycle must reach 'comp' — the
    # composite-only state. The first committed order (both -> comp -> scrap ->
    # close) ran 'scrap' straight to 'none', so BOTH panels were shut and the
    # orb (which only exists on an open panel) was gone with them: 'comp' was
    # unreachable, and the panel's whole point with it.
    assert_equal "both", order["scrap"],
      "from the star-opened state the orb must widen the frame, not shut it"
    assert_equal "comp", order["both"], "and from both panels, the composites alone"
    assert_equal "none", order["comp"], "then closed, which hands back to the star"
    assert_equal "scrap", order["none"], "and the star's state is where it resumes"

    # The orb really is only on an open panel, which is what makes 'none' a
    # hand-off rather than a dead end.
    assert_match(/\.scrapbook-sidebar\.open \.scrapbook-close\s*\{[^}]*display: flex/,
                 css, "the orb rides the open panel")
  end

  # --- what the second panel is for ---

  test "the composites panel is the navigation frame over the composites table" do
    doc = Nokogiri::HTML(layout)
    refute_nil doc.at_css("aside#compositeSidebar #compositeBody"),
      "the panel's body is the mount point the renderer fills"
    assert_includes js, "'/composite/list'",
      "it reads the composites through the builder's own JSON route, not a second reader"
    assert_includes js, "/composite?id=",
      "and a row OPENS the composite in the builder: the panel navigates, it is not a store"
    assert_includes js, "renderComposites(",
      "the renderer it fills the body with"
    assert_match(/function loadComposites\(\)/, js,
      "and the frame loads it when the panel comes up")
    assert_match(/if \(compOn\) loadComposites\(\);/, js,
      "only when the panel is actually showing")
  end
end
