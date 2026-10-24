require "test_helper"

# In the candidates table the third action is either a "Proof" button (no proof
# yet) or a download of the generated proof PNG. They must be the SAME SIZE: the
# download replaced the Proof button, and it was 32px where the Proof button was
# 82px, so the column changed width the moment a proof was generated.
class ProofButtonSizeTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
    @view = File.read(Rails.root.join("app/views/jobs/show.html.erb"))
  end

  test "both states of the proof control are sized explicitly" do
    # A label-length difference is not a size: "PNG" measured 62.8px and "Proof"
    # 82.0px on the same btn-sm. Width AND height on both, so the box holds
    # either label and a proofed row sits level with a bare one.
    %w[.cs-job-proof-download .cs-proof-btn].each do |sel|
      rule = @css[/#{Regexp.escape(sel)} \{([^}]*)\}/m, 1]
      refute_nil rule, "#{sel} has no rule"
      assert_match(/width:\s*82px/, rule, "#{sel} width")
      assert_match(/min-width:\s*82px/, rule, "#{sel} min-width")
      assert_match(/height:\s*32px/, rule, "#{sel} height")
    end
  end

  test "the download is a labelled button, not an icon-only control" do
    # It used to be `btn btn-icon` with a 14x14 SVG -- measured 32.0 x 32.0.
    # An icon-only control was also the only way to fetch a proof, with nothing
    # on the row saying so.
    refute_match(/btn btn-icon cs-job-proof"/, @view, "the old icon-only button")
    assert_includes @view, %q{link_to "PNG"}
    assert_includes @view, "btn-secondary btn-sm cs-proof-btn cs-job-proof-download"
  end

  test "the Proof button and the download are the same control in two states" do
    # Same class list on both branches, so they cannot drift again: the bare
    # branch renders via button_to, the proofed branch via link_to, and both
    # must carry cs-proof-btn.
    # In the class attribute, not in prose: the comment above the download
    # mentions cs-proof-btn too, and counting comments counts nothing. These are
    # Ruby class: hashes, not HTML attributes -- the class is a hash value here.
    assert_equal 2, @view.scan(/class:\s*"[^"]*\bcs-proof-btn\b/).size,
      "cs-proof-btn on both branches -- the bare Proof button and the download"
    assert_includes @view, "cs-job-proof-download"
  end

  test "the download still names its file for assistive tech" do
    assert_match(/"aria-label" => "Download proof PNG for #\{c\["file"\]\}"/, @view)
    assert_includes @view, %q{title: "Download proof PNG"}
  end
end
