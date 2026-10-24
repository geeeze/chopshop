require "test_helper"
require "uri"

# THE TRAINING SET CARD on the proof page.
#
# The whole point of this card is that it is CONDITIONAL: the opt-in is off by
# default, so a proof that did not ask for a dataset must render exactly as it
# did before the feature existed. Both directions are asserted here for that
# reason — the absence case is the default one, and it is the one an "always
# render the card" regression would break without anything else noticing.
class ProofDatasetCardTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  CANDIDATE = "candidate_01.svg".freeze
  SHEET = "candidate_01.dataset-contact-sheet.png".freeze
  MANIFEST = "candidate_01.dataset.json".freeze
  PACKAGE = "candidate_01.dataset.7z".freeze
  TRANSFORMS = %w[flip-h flip-v rot180 invert hue-90 channel-swap].freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def manifest(dataset: nil)
    base = { "proof" => "proof_01.png", "print_pdf" => "proof_01.pdf",
             "summary" => { "hard" => 0, "advisory" => 1 },
             "stats" => { "dpi" => 300, "rendered_ink_colors" => 3,
                          "static" => { "path_nodes_total" => 812 } },
             "findings" => [] }
    dataset ? base.merge("dataset" => dataset) : base
  end

  def dataset_block
    { "dir" => "candidate_01.dataset", "manifest" => MANIFEST, "sheet" => SHEET,
      "count" => TRANSFORMS.size, "transforms" => TRANSFORMS, "package" => PACKAGE }
  end

  def proof(manifest_hash)
    job = Job.create!(name: "proved-artwork", state: "done", source_kind: "raster",
                      runner: "mock", input_path: "/tmp/x.png", stem: "proved-artwork")
    job.validations.create!(file: CANDIDATE, state: "done", manifest: manifest_hash)
  end

  def query_of(path)
    Rack::Utils.parse_nested_query(URI(path).query.to_s)
  end

  # --- when the manifest HAS a dataset -------------------------------------

  test "a proof that asked for variants grows a Training set card" do
    sign_in
    v = proof(manifest(dataset: dataset_block))
    get validation_path(v), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    card = doc.at_css("[data-proof-dataset]")
    refute_nil card, "the manifest carries a dataset, so the card belongs on the page"
    assert_equal "Training set", card.at_css("h3").text.strip

    # The count and the names, as chips — the two things the card is for.
    assert_match(/6 transforms/, card.text)
    assert_match(/6 similar copies/, card.text)
    chips = card.css(".screen-chip").map(&:text).map(&:strip)
    assert_equal TRANSFORMS, chips, "every transform is named, in the manifest's order"

    # The contact sheet comes through the SAME file proxy the proof render uses,
    # so it opens in the glass popup and can be favourited like anything else.
    #
    # FLAT, with NO `candidate` -- and that detail is a regression test, not
    # decoration. The runner writes `<stem>.dataset-contact-sheet.png` at the JOB
    # ROOT (runner.py publishes the three flat names there so the existing
    # three-segment route serves them); only the per-transform variants live in
    # `<stem>.dataset/raster|vector/`. This assertion used to require a
    # `candidate` query here, which pinned a nested path the runner has nothing
    # at: the card rendered a broken <img> on a real runner, and the test agreed
    # with it. The proof render's URL and this one must be the same SHAPE.
    frame = card.at_css("a.art-frame")
    refute_nil frame
    assert_equal "/jobs/#{v.job_id}/file", URI(frame["href"]).path
    assert_equal({ "name" => SHEET }, query_of(frame["href"]),
                 "the contact sheet is a FLAT job-root name, so no candidate rides along")
    assert_equal frame["href"], frame.at_css("img")["src"],
                 "the thumbnail and the popup open the same bytes"
    assert_equal "svg", frame["data-cs-view"]
    assert_equal frame["href"], frame["data-cs-url"]

    links = card.css("a.btn").map { |a| [a.text.strip, a["href"]] }
    package = links.find { |text, _| text.include?("Training set 7z") }
    refute_nil package, "the 7z package must be downloadable from the card"
    assert_equal "/jobs/#{v.job_id}/dataset", URI(package.last).path
    assert_equal({ "candidate" => CANDIDATE }, query_of(package.last))

    manifest_link = links.find { |text, _| text.include?("Dataset manifest") }
    refute_nil manifest_link
    assert_equal({ "name" => MANIFEST, "download" => "1" },
                 query_of(manifest_link.last),
                 "the dataset manifest is ALSO a flat job-root name: attached, but not nested")

    # And the card says what these files ARE. Plainly, because the temptation to
    # read them as a shortlist is exactly what the sentence is for.
    text = card.text.gsub(/\s+/, " ")
    assert_match(/SIMILAR COPIES/, text)
    assert_match(/did not pick or rank/i, text)
  end

  test "the card is absent when the manifest has no dataset key" do
    sign_in
    v = proof(manifest)
    get validation_path(v), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    assert_nil doc.at_css("[data-proof-dataset]"),
               "the opt-in is off by default: no dataset key means NO card"
    refute_includes doc.text, "Training set",
                    "not an empty card and not a 'did not run' note either"
    refute_includes doc.text, "SIMILAR COPIES"

    # The rest of the proof page is untouched by the feature.
    refute_nil doc.at_css(".card") # the Proof render and Findings cards are still there
    refute_nil doc.at_css("a[data-cs-view='svg']"), "the proof render still opens in the popup"
  end

  test "a proof that is still running has neither the card nor a stale one" do
    sign_in
    v = proof(manifest(dataset: dataset_block))
    v.update!(state: "running")
    get validation_path(v), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    assert_nil doc.at_css("[data-proof-dataset]"),
               "a running proof has not proved anything yet, so it has no training set"
  end

  test "a dataset whose key is not a hash is treated as no dataset rather than as a crash" do
    sign_in
    v = proof(manifest.merge("dataset" => "yes"))
    get validation_path(v), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_nil Nokogiri::HTML(response.body).at_css("[data-proof-dataset]")
  end
end
