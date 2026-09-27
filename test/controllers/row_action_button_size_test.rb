require "test_helper"

# Every icon button in the job results page is the SAME size, and the Proof
# button in the narrow proofs table is the one that used to break.
#
# The bug: .cs-row-actions .btn-icon set only `width: 2rem`. A flex item
# defaults to flex-shrink: 1, so that width is a REQUEST, not a size. The
# proofs table is table-layout: fixed with an explicit narrow actions column, and
# .proofs-tbl .cs-row-actions is nowrap -- so the Proof button shrank to fit
# instead of overflowing, measuring 7.48 x 32.00 while the Download button
# beside it in the candidates table stayed 32.00 x 32.00.
#
# Found by measuring in a browser, not by reading the CSS: the class list and
# the declarations were identical on all four buttons, so nothing in the markup
# distinguished them. The fix is flex: 0 0 auto, which makes the width a size.
#
# A Rails test cannot measure layout, so the numeric check lives in the browser
# probe. What this file pins is the CAUSE -- the shrink that made the size a
# request -- plus the structure that produced the narrow column in the first
# place, so a future width change cannot silently reintroduce it.
class RowActionButtonSizeTest < ActionDispatch::IntegrationTest
  def css
    File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  def show_view
    File.read(Rails.root.join("app/views/jobs/show.html.erb"))
  end

  test "icon buttons do not shrink below their width" do
    rule = css[/\.cs-row-actions \.btn-icon \{[^}]*\}/]
    refute_nil rule, "the rule must exist"
    assert_match(/flex:\s*0 0 auto/, rule,
      "flex: 0 0 auto is the fix. width alone is only a request: a flex item " \
      "defaults to flex-shrink: 1, and in the proofs table's nowrap actions " \
      "cell the Proof button shrank to 7.48px wide while Download stayed 32px.")
    assert_match(/width:\s*2rem/, rule)
    assert_match(/height:\s*2rem/, rule)
  end

  test "the proofs actions cell is nowrap, which is what made the shrink bite" do
    # If this ever becomes wrap, flex: 0 0 auto would push the button out of a
    # fixed-layout table rather than shrink it -- and the column would need
    # widening instead. Pin it so the change is deliberate.
    assert_match(/\.proofs-tbl \.cs-row-actions \{[^}]*flex-wrap:\s*nowrap/,
                 css)
    assert_match(/table\.candidates\.proofs-tbl/, css,
      "the proofs table is table-layout: fixed with explicit widths, which is " \
      "why the actions column can be narrower than one button")
  end

  test "every icon button on the page carries the same classes" do
    # The four buttons differed only in an extra modifier (cs-job-download,
    # cs-job-proof), never in sizing -- which is exactly why the CSS alone could
    # not explain the mismatch.
    btns = show_view.scan(/class="btn btn-icon[^"]*"/)
    assert btns.any?, "the page has icon buttons"
    btns.each do |cls|
      assert_includes cls, "btn-icon"
      refute_match(/width|height|size|style=/, cls,
        "no inline sizing: a button that carries its own size cannot be held " \
        "to a common one")
    end
  end

  test "the Proof button and the Download button are the same element shape" do
    # The class attribute is on its own line for the proof button, so a
    # single-line regex misses it -- scan for the class anywhere on a line.
    assert_includes show_view, "btn btn-icon cs-job-proof",
      "the proof download button is on the candidates row"
    assert_includes show_view, "btn btn-icon cs-job-download",
      "and the SVG download beside it"
    # Both are link_to with a download attribute, so both render as <a>: the
    # proof button being a <button> would have made it a different box model.
    assert_equal 1, show_view.scan(/link_to file_job_path\(@job, name: proof\["proof"\], download: 1\)/).size
    assert_equal 1, show_view.scan(/link_to file_job_path\(@job, name: c\["file"\], download: 1\)/).size
  end
end
