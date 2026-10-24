require "test_helper"

# One close mechanism for every popup: the × glyph in the head's top-right,
# plus backdrop click and Escape. This pins the MARKUP so no popup drifts back
# to a "Close" word button or a different close icon — the whole point is that
# there is exactly one, and a dismissal works the same way everywhere.
#
# It also pins the SHARED SHAPE every popup is built from: .popup > .popup-panel
# > (.popup-head with the one close) + .popup-body. The popups all happen to
# match it today; the point of asserting it is that the next one is written from
# the same shape rather than inventing a second head, and that the JS (which
# closes on [data-popup-close], the backdrop and Escape) keeps finding what it
# looks for.
class PopupCloseStandardTest < ActiveSupport::TestCase
  def views
    Dir[Rails.root.join("app/views/**/*.erb")]
  end

  test "every popup close is the × button, never a word" do
    popups = views.select { |p| File.read(p).include?("data-popup-close") }
    refute_empty popups, "there are popups to check"

    popups.each do |path|

      src = File.read(path)
      # The word-button style is gone: it was a second close mechanism, and a
      # second mechanism is exactly how the close drifts per popup.
      refute_includes src, "popup-close-text",
        "#{path}: the word-button class is back"
      # No close control is labelled "Close" — the label is the × glyph.
      refute_match(/data-popup-close[^>]*>Close</, src,
        "#{path}: a close button is labelled Close, not the × glyph")
      # And every one carries the standard class (top-right, styled below it).
      assert_includes src, 'class="popup-close"',
        "#{path}: the close button must carry the standard popup-close class"
      assert_includes src, "&times;",
        "#{path}: the close glyph is &times;"
    end
  end

  test "every popup is the same head / close / body shape" do
    checked = 0
    views.each do |path|
      src = File.read(path)
      next unless src.include?('class="popup"')

      doc = Nokogiri::HTML(src)
      popups = doc.css("div.popup")
      refute_empty popups, "#{path}: a .popup must parse"

      popups.each do |popup|
        panel = popup.element_children.find { |c| (c["class"] || "").split.include?("popup-panel") }
        refute_nil panel, "#{path}: .popup wraps a .popup-panel"
        head = panel.element_children.find { |c| (c["class"] || "").split.include?("popup-head") }
        refute_nil head, "#{path}: the panel opens with a .popup-head"
        refute_nil panel.element_children.find { |c| (c["class"] || "").split.include?("popup-body") },
          "#{path}: the panel carries the .popup-body"
        # Exactly one close, and it lives in the head where the standard puts it.
        assert_equal 1, head.css("[data-popup-close]").size,
          "#{path}: the head carries exactly one close"
        assert_equal 1, popup.css("[data-popup-close]").size,
          "#{path}: and the popup has no second close"
        checked += 1
      end
    end
    assert_operator checked, :>=, 10, "the popups are being found (#{checked})"
  end

  # The root IS the backdrop: `position: fixed` with `inset: 0`. A
  # width on that box is over-constrained (left, right AND width all
  # set), so the width wins and `right` is dropped — the backdrop stops
  # short of the right viewport edge, and the panel centres inside the
  # short box instead of the viewport. Measured with `popup-wide` on
  # the Run Job page's JSON popup at 1280px: a 1088px backdrop, its
  # panel 96px left of centre, and the right 192px of the screen
  # neither darkened nor blurred (#82). The width modifiers
  # (.popup-wide, .popup-terminal, .popup-remediation, .popup-report)
  # belong on the PANEL, which is where every working popup carries
  # them — the root carries `popup` alone.
  test "the popup root carries the popup class alone" do
    views.each do |path|
      src = File.read(path)
      next unless src.include?('class="popup')

      doc = Nokogiri::HTML(src)
      doc.css("div.popup").each do |popup|
        classes = (popup["class"] || "").split
        assert_equal ["popup"], classes,
          "#{path}: the .popup root must carry `popup` alone, not " \
          "#{classes.join(' ')} — a panel-width class on the root " \
          "breaks the full-viewport backdrop and off-centres the panel"
      end
    end
  end
end
