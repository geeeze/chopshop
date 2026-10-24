require "test_helper"

# DRAGGING A SCRAPBOOK ITEM ONTO A PAGE.
#
# Two surfaces accept it, and both were broken or missing:
#
#   1. The COMPOSITE canvas could not accept a layer by ANY route — drag, the
#      file picker, or "add blank". `keyOf(null)` threw
#      "Cannot read properties of null (reading 'key')" on every call, because
#      `addLayer` asks for a key for a layer that does not exist yet. The throw
#      happened after the caller's handler returned, so the failure was silent:
#      no console error the operator would see, just a button that did nothing.
#      That helper and its call site arrived together and never changed, so this
#      had never worked.
#   2. The RUN JOB page only accepted a drop on the flux reference tile. There
#      was no handler on the artwork tile at all, so dragging a scrapbook image
#      in did nothing.
#
# The gesture is now PAGE-LEVEL on both: on these pages a dragged source has one
# meaning, so requiring a precise hit on a 200px tile was a gratuitous target.
class ScrapbookDragTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  COMPOSITE = "app/views/composites/show.html.erb".freeze
  RUN_JOB = "app/views/jobs/new.html.erb".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def source(path)
    File.read(Rails.root.join(path))
  end

  # --- the blocker ---------------------------------------------------------

  test "keyOf tolerates the null a new layer has" do
    composite_js = source(COMPOSITE)
    key_of = composite_js[/function keyOf\(l\)\s*\{[^}]*\}/m]
    refute_nil key_of, "the page must still define keyOf"
    assert_match(/l\s*&&\s*l\.key/, key_of,
      "keyOf must guard against a null argument: addLayer asks it for the key of "\
      "a layer that does not exist yet, and an unguarded `l.key` throws — which "\
      "is what made every add-a-layer route silently dead")

    # ...and the call site that needs it is still there, so the guard is not
    # protecting nothing (that would be a check that cannot fail).
    assert_match(/keyOf\(null\)/, composite_js,
      "addLayer still mints a fresh key, which is the case the guard exists for")
  end

  # --- the composite page: drop anywhere -----------------------------------

  test "the composite page accepts a drop anywhere, not just on the canvas" do
    composite_js = source(COMPOSITE)

    refute_match(/canvas\.addEventListener\('drop'/, composite_js,
      "the canvas-only drop target is what required a precise hit on a 600px "\
      "canvas; the handler moved to the page")
    assert_match(/document\.body\.addEventListener\('drop'/, composite_js,
      "the drop listener must be page-level")

    # Bound to body, not document: Turbo replaces the body on every navigation,
    # so these bindings are fresh per page rather than surviving the swap with a
    # closure over a canvas that is no longer in the document.
    refute_match(/document\.addEventListener\('drop'/, composite_js,
      "a document-level listener would outlive the body it closes over")

    # Only OUR typed payload counts, so a stray text drag cannot become a layer.
    assert_match(/x-scrapbook\+json/, composite_js)
    assert_match(/carriesLayer/, composite_js, "the payload is checked before it is used")
  end

  test "the composite page really renders a draggable drawer item to drag" do
    # The drag SOURCE is the drawer's own thumb, built in aether.js. If that
    # markup loses draggable or the typed payload attribute, the gesture dies at
    # the other end and no test on the page would notice.
    js = File.read(Rails.root.join("app/javascript/aether.js"))
    thumb = js[/class="scrap-thumb"[^']*/]
    refute_nil thumb, "the drawer's thumb markup"
    assert_includes thumb, 'draggable="true"'
    assert_includes thumb, "data-scrap-item="
    assert_includes js, "SCRAP_DRAG_LAYER", "and the delegated dragstart writes the typed payload"
  end

  # --- the Run Job page ----------------------------------------------------

  test "the Run Job page accepts a drop anywhere and puts it in the source" do
    js = source(RUN_JOB)

    assert_match(/document\.body\.addEventListener\('drop'/, js,
      "a drop anywhere on the page must become the job's source")
    assert_match(%r{/scrapbook/' \+ encodeURIComponent\(item\.id\) \+ '/artwork'}, js,
      "and it must go through the artwork route, which answers JSON")
    assert_match(/applySource\(/, js,
      "the dropped file must land through the SAME state setter the file picker uses")

    # The picker's own success path must use that setter too, or the two can
    # drift and a dropped file could place differently from an uploaded one.
    picker = js[/fileInput\.addEventListener\('change'.*?\n  \}\);/m]
    refute_nil picker, "the file picker's change handler"
    assert_match(/applySource\(/, picker,
      "the picker sets its state through applySource as well")
  end

  test "a drop on the reference tile keeps its own meaning and does not also set the source" do
    js = source(RUN_JOB)
    ref_block = js[/\[refTile, refThumb\]\.forEach\(function \(target\) \{.*?\n  \}\);/m]
    refute_nil ref_block, "the reference tile's bindings"

    assert_match(/e\.stopPropagation\(\)/, ref_block,
      "the tile must stop the event reaching the page-level handler: an item "\
      "accepted as the edit REFERENCE must not also become the job's source")
    # Both handlers, not just one: a dragover that bubbles would still let the
    # page handler claim the drop.
    assert_operator ref_block.scan(/e\.stopPropagation\(\)/).size, :>=, 2,
      "both the dragover and the drop must stop propagation"
  end

  # --- the route the drop calls --------------------------------------------

  test "the artwork route copies a raster item into uploads with the kind the trace stage reads" do
    sign_in
    scrap = Rails.root.join("storage", "scrapbook")
    uploads = Rails.root.join("storage", "uploads")
    scrap.mkpath
    uploads.mkpath

    name = "artwork_probe_#{SecureRandom.hex(4)}.png"
    File.binwrite(scrap.join(name), "\x89PNG\r\n\x1a\n".b + ("\x00" * 32))
    item = ScrapbookItem.create!(name: "probe.png", kind: "upload", file: name)

    before = Dir.glob(uploads.join("upload_*")).size
    post scrapbook_item_artwork_path(item), headers: { "User-Agent" => MODERN_UA }

    assert_response :success
    json = JSON.parse(response.body)
    assert json["path"].to_s.start_with?(uploads.to_s),
      "the source must be copied into storage/uploads, the only input location the runner reads"
    assert File.file?(json["path"]), "and the copied file must exist"
    assert_equal "raster", json["source_kind"]
    assert_equal File.size(json["path"]), json["size"]
    assert json["preview_url"].present?
    assert_equal before + 1, Dir.glob(uploads.join("upload_*")).size
  ensure
    File.delete(scrap.join(name)) if name && File.exist?(scrap.join(name))
  end

  # An SVG is a legitimate SCRAPBOOK artefact (a traced candidate, a plot, a
  # vector-flattened composite) and NOT a job's source: the trace stage preps the
  # source with PIL, which has no SVG reader. This route used to accept one, which
  # is how a vector-flattened composite reached the runner as an
  # `UnidentifiedImageError`. The refusal is the same sentence the create path
  # uses, so a dropped SVG and a posted one are told the same thing.
  test "the artwork route refuses an SVG, naming the way out" do
    sign_in
    scrap = Rails.root.join("storage", "scrapbook")
    scrap.mkpath
    name = "artwork_probe_#{SecureRandom.hex(4)}.svg"
    File.binwrite(scrap.join(name), '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"></svg>')
    item = ScrapbookItem.create!(name: "probe.svg", kind: "svg", file: name)

    post scrapbook_item_artwork_path(item), headers: { "User-Agent" => MODERN_UA }

    assert_response :unprocessable_entity
    error = JSON.parse(response.body)["error"].to_s
    assert_match(/must be a \.png \/ \.jpg \/ \.jpeg/, error)
    assert_match(/render the drawing to PNG first/, error, "the remedy is named")
    assert_equal Job.trace_source_refusal("x.svg"), error,
      "one voice: the same wording the create path refuses with"
  ensure
    File.delete(scrap.join(name)) if name && File.exist?(scrap.join(name))
  end

  test "the artwork route still refuses a file the pipeline cannot read" do
    sign_in
    scrap = Rails.root.join("storage", "scrapbook")
    scrap.mkpath
    name = "artwork_probe_#{SecureRandom.hex(4)}.pdf"
    File.binwrite(scrap.join(name), "%PDF-1.4")
    item = ScrapbookItem.create!(name: "probe.pdf", kind: "upload", file: name)

    post scrapbook_item_artwork_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :unprocessable_entity
    assert_match(/must be a \.png \/ \.jpg \/ \.jpeg/, JSON.parse(response.body)["error"])
  ensure
    File.delete(scrap.join(name)) if name && File.exist?(scrap.join(name))
  end
end
