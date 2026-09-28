require "test_helper"

# Drag-and-drop between the site and the scrapbook. Two directions:
#   1. a drawer/composite-picker thumbnail is dragged ONTO #compCanvas to become
#      a layer, and
#   2. a job-show thumbnail is dragged ONTO the drawer (or its toggle) to
#      favourite it, the same POST the star fires.
# The server-rendered half is asserted as DOM; the JS half is pinned by reading
# the source, the way ScrapbookEditorToolsTest pins the editor's state.
class ScrapbookDragDropTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def done_job
    Job.create!(name: "drag", state: "done", source_kind: "raster",
                input_path: "/data/x.png", stem: "drag", spec: {}, runner: "mock",
                comparison: { "candidates" => [
                  { "file" => "candidate_01.svg", "sweep" => { "preset" => "bw" },
                    "layer_a" => { "status" => "pass" }, "layer_b" => { "status" => "pass" },
                    "hard" => 0, "advisory" => 0, "fidelity" => {}, "passed" => true }
                ] })
  end

  test "the source, invert, candidate and proof thumbnails are favourite drag sources" do
    sign_in
    job = done_job
    Validation.create!(job: job, file: "candidate_01.svg", state: "done",
                       manifest: { "proof" => "candidate_01.proof.png" })

    get job_path(job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    doc = Nokogiri::HTML(response.body)

    src = doc.at_css('.source-stack a.pv-tile[data-scrap-name="source.png"]')
    refute_nil src, "the source tile must be a drag source"
    assert_equal "true", src["draggable"]

    inv = doc.at_css('.source-stack a.pv-tile[data-scrap-name="source.inverse.png"]')
    refute_nil inv, "the inverse tile must be a drag source"
    assert_equal "true", inv["draggable"]

    cand = doc.at_css('span.cand-thumb[data-scrap-name="candidate_01.svg"]')
    refute_nil cand, "the candidate thumbnail must be a drag source"
    assert_equal "true", cand["draggable"]

    proof = doc.at_css('span.cand-thumb[data-scrap-name="candidate_01.proof.png"]')
    refute_nil proof, "the finished-proof thumbnail must be a drag source"
    assert_equal "true", proof["draggable"]

    # Every drag source carries the job id the favourite POST needs.
    [src, inv, cand, proof].each do |el|
      assert_equal job.id.to_s, el["data-scrap-job"]
    end
  end

  test "a thumbnail drag carries a favourite payload under its own MIME type" do
    js = aether_js
    assert_includes js, "application/x-scrapbook-fav",
      "the favourite drag must use a private MIME type"
    assert_includes js, "data-scrap-job",
      "dragstart must read the job id off the thumbnail"
    assert_includes js, "setData(SCRAP_DRAG_FAV, JSON.stringify(fav))",
      "dragstart must put the favourite payload on the dataTransfer"
  end

  test "a layer drag carries the item JSON under its own MIME type" do
    js = aether_js
    assert_includes js, "application/x-scrapbook+json"
    assert_includes js, "setData('text/plain', item.url"
    assert_includes js, "setData(SCRAP_DRAG_LAYER, JSON.stringify(item))"
  end

  test "the drawer and its toggle are drop targets and light up while hovered" do
    js = aether_js
    assert_match(/\[sidebar, toggle\]\.forEach/, js,
      "both the drawer and the fixed toggle must accept a favourite drop")
    assert_includes js, "classList.add('drop-active')"
    assert_includes js, "classList.remove('drop-active')"
    # dragover must preventDefault or the browser refuses the drop.
    assert_match(/addEventListener\('dragover',[\s\S]*?preventDefault\(\)/, js)
  end

  test "clicking the star and dropping on the drawer share one POST" do
    js = aether_js
    assert_includes js, "function scrapPostFavourite(job, name)",
      "there must be a single favourite POST path"
    assert_match(/scrapPostFavourite\(job, name\)/, js,
      "the star must go through the shared POST")
  end

  test "the composite canvas accepts a scrapbook layer drop and calls addLayer" do
    view = Rails.root.join("app/views/composites/show.html.erb").read(encoding: "UTF-8")
    assert_includes view, "application/x-scrapbook+json"
    assert_includes view, "canvas.addEventListener('dragover'"
    assert_includes view, "canvas.addEventListener('drop'"
    assert_includes view, "addLayer(item.name || item.url.split('/').pop() || 'layer', item.url);"
    # A bare text/plain drop must NOT become a layer — only the typed payload.
    refute_match(/getData\('text\/plain'\)\s*\|\|/, view,
      "the drop must not accept a stray text/plain payload as a layer URL")
  end

  test "the picker is click-to-add, not a drag source" do
    view = Rails.root.join("app/views/composites/show.html.erb").read(encoding: "UTF-8")
    # The picker is a full-screen .popup overlay; a drag out of it can never
    # reach the canvas. It adds on click; the drawer is the drag source.
    assert_includes view, "data-comp-add-scrap="
    refute_includes view, "data-scrap-item=",
      "the picker thumbnails must not masquerade as drag sources (dead path)"
  end

  private

  def aether_js
    Rails.root.join("app/javascript/aether.js").read(encoding: "UTF-8")
  end
end
