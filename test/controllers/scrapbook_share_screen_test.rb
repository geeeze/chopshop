require "test_helper"

# The scrapbook drawer is not a popup: it is a persistent store that SHARES the
# screen with the page rather than overlaying it. These pin the three behaviours
# that make that work, none of which are obvious from the CSS alone.
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

  test "the drawer closes with a text Close button, not the popup × glyph" do
    assert_includes layout, "data-scrap-close"
    assert_match(/data-scrap-close[^>]*>Close</, layout,
      "the drawer's close is a word button")
    # And it must NOT be a popup close — that carries the × and is governed by
    # PopupCloseStandardTest, a separate convention for a separate control.
    refute_match(/data-popup-close[^>]*>\s*Close</, layout,
      "the drawer is not a popup; keep the two close conventions separate")
  end

  test "the star disappears while the drawer is open" do
    assert_includes css, "body.scrapbook-open .scrapbook-toggle { display: none; }",
      "the star is the drawer's opener and must not float over the open drawer"
    assert_includes js, "document.body.classList.add('scrapbook-open');"
    assert_includes js, "document.body.classList.remove('scrapbook-open');",
      "closing must take the class back off, or the page stays padded forever"
  end

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
end
