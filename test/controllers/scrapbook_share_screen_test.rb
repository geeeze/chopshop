require "test_helper"

# The scrapbook drawer is not a popup: it is a persistent store that SHARES the
# screen with the page rather than overlaying it. These pin the behaviours that
# make that work, none of which are obvious from the CSS alone -- including the
# content floor that keeps the page usable while the drawer takes its share.
class ScrapbookShareScreenTest < ActiveSupport::TestCase
  def layout
    Rails.root.join("app/views/layouts/application.html.erb").read
  end

  def css
    # Forced UTF-8: read plain would tag it with the locale default, and a
    # regexp literal (which is UTF-8) then refuses to match it.
    Rails.root.join("app/assets/stylesheets/application.css").read(encoding: "UTF-8")
  end

  def js
    Rails.root.join("app/javascript/aether.js").read
  end

  # --- the drawer's close: an X on the edge it shares with the page ---

  test "the drawer closes with an X on the vertical edge it shares with the page" do
    doc = Nokogiri::HTML(layout)
    head = doc.at_css(".scrapbook-head")
    refute_nil head, "the drawer still has its header"
    assert_nil head.at_css("[data-scrap-close]"),
      "the close left the header for the drawer's own edge"

    close = doc.at_css(".scrapbook-sidebar > .scrapbook-close[data-scrap-close]")
    refute_nil close, "the close rides the drawer's panel, not the top bar"
    refute_nil close.at_css("svg"), "the ✕ is an inline SVG, like the app's other icons"
    refute_includes close.to_html, ">Close<",
      "an icon, not the word the header button used to carry"
    refute_nil close.at_css(".scrapbook-close-orb"), "a ring behind the ✕"

    # Where it sits: the VERTICAL CENTRE of the drawer's outer edge, straddling
    # the boundary (transform, not an offset, so its centre is on the edge).
    rule = css[/\n\.scrapbook-close\s*\{(.*?)\n\}/m, 1]
    refute_nil rule, "the edge close is styled"
    assert_includes rule, "position: absolute"
    assert_includes rule, "top: 50%"
    assert_includes rule, "right: 0"
    assert_includes rule, "translate(50%, -50%)"
    assert_includes rule, "border-radius: 50%"
    # Closed, the drawer is off-screen and this button hangs half outside it --
    # without the rule a stray ✕ would sit on the page's edge over the star.
    assert_includes rule, "display: none"
    assert_match(/\.scrapbook-sidebar\.open \.scrapbook-close\s*\{[^}]*display: flex/,
                 css, "the close appears with the open drawer")

    orb = css[/\n\.scrapbook-close-orb\s*\{(.*?)\n\}/m, 1]
    refute_nil orb, "the orb accent behind the ✕"
    assert_includes orb, "border-radius: 50%"
    assert_match(/radial-gradient|box-shadow/, orb)

    # And it stays the DRAWER's close: not a popup close, which is a different
    # convention governed by PopupCloseStandardTest.
    refute_includes layout, "data-popup-close"
    # The delegated handler still recognises it, so nothing else had to change.
    assert_includes js, "e.target.closest('[data-scrap-close]')"
  end

  test "the star disappears while the drawer is open" do
    assert_includes css, "body.scrapbook-open .scrapbook-toggle { display: none; }",
      "the star is the drawer's opener and must not float over the open drawer"
    assert_includes js, "document.body.classList.add('scrapbook-open');"
    assert_includes js, "document.body.classList.remove('scrapbook-open');",
      "closing must take the class back off, or the page stays padded forever"
  end

  # --- sharing the screen, including when the screen is narrow ---

  test "the open drawer shares the screen instead of covering the page" do
    # The page is padded aside by the drawer's width, not covered by it.
    rule = css[/body\.scrapbook-open main\.container[^{]*\{(.*?)\n\}/m, 1]
    refute_nil rule, "main must slide aside for the open drawer"
    assert_includes rule, "--scrapbook-w"
    # The width is published as a custom property, so the padding and the drawer
    # cannot drift apart when the drawer is resized or capped at 85vw.
    assert_includes css, "--scrapbook-w"
    assert_includes js, "--scrapbook-w"
  end

  test "the drawer width and the page padding read the same custom property" do
    # One source of truth. A bare 320px in the padding rule would leave a gap
    # whenever the drawer is capped by its 85vw max-width on a narrow window.
    # A FALLBACK inside var() is fine and expected — it is what makes the rule
    # work before the script has run once.
    rule = css[/body\.scrapbook-open main\.container[^{]*\{(.*?)\n\}/m, 1]
    refute_nil rule
    stripped = rule.gsub(/var\(--scrapbook-w[^)]*\)/, "")
    refute_includes stripped, "px",
      "the padding must derive from --scrapbook-w, not a duplicated literal"
  end

  test "an open drawer keeps a usable content width in a narrow window" do
    # `main.container` is `width: 100%` and box-sizing: border-box, so the
    # drawer-sized padding-left is taken OUT of the content box: at 700px wide
    # the content measured 332px and the run-job form's fields collapsed to a
    # few characters each. The floor reserves a usable width and lets the page
    # scroll sideways instead of squashing.
    rule = css[/body\.scrapbook-open main\.container[^{]*\{(.*?)\n\}/m, 1]
    refute_nil rule
    assert_match(/min-width:\s*calc\([^;]*var\(--scrapbook-w/, rule,
      "the content floor must derive from the drawer's own width")
    assert_match(/min-width:\s*[^;]*rem/, rule,
      "and reserve a real, usable width rather than nothing")
    # The property is on the SAME rule that owns the padding, so the two cannot
    # be edited apart, and it applies to the element the layout renders.
    doc = Nokogiri::HTML(layout)
    refute_nil doc.at_css("main.container"), "the layout renders main.container"
    assert_includes js, "document.body.classList.add('scrapbook-open');",
      "the floor only matters while the drawer is open"
  end
end
