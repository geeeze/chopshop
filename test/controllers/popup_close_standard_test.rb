require "test_helper"

# One close mechanism for every popup: the × glyph in the head's top-right,
# plus backdrop click and Escape. This pins the MARKUP so no popup drifts back
# to a "Close" word button or a different close icon — the whole point is that
# there is exactly one, and a dismissal works the same way everywhere.
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
end
