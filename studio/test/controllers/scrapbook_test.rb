require "test_helper"

# The scrapbook: favouriting a runner artifact COPIES its bytes into
# storage/scrapbook, so the store is its own data and survives deleting the job
# it came from. The controller is login-gated like every other authed surface.
class ScrapbookTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
    @uploads&.each { |f| f.close! }
  end

  def job_with_candidate
    job = Job.create!(name: "scrap", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "scrap", spec: {}, runner: "mock")
    [job, job.candidates.create!(file: "candidate_01.svg")]
  end

  # The scrapbook's own directory. File assertions are counted AROUND a request
  # rather than as absolute totals: the DB rolls back between tests, storage
  # does not, so another test's leftovers are already in there.
  def scrapbook_dir
    Rails.root.join("storage", "scrapbook")
  end

  def stored_file_count
    Dir.glob(scrapbook_dir.join("*")).size
  end

  # An upload of exact bytes for the import path, built from a tracked tempfile
  # so teardown can close it even when the controller deleted it as a duplicate.
  def uploaded_png(bytes)
    file = Tempfile.new(["dedupe", ".png"])
    file.binmode
    file.write(bytes)
    file.rewind
    (@uploads ||= []) << file
    Rack::Test::UploadedFile.new(file.path, "image/png")
  end

  # Minitest 6 dropped minitest/mock, so swap the singleton method and restore it.
  def with_get_file(status: 200, body: "<svg/>")
    original = RunnerClient.method(:get_file)
    RunnerClient.define_singleton_method(:get_file, ->(*) {
      { status: status, body: body, content_type: "image/svg+xml" }
    })
    yield
  ensure
    RunnerClient.define_singleton_method(:get_file, original)
  end

  test "the scrapbook is login-gated" do
    get scrapbook_path
    assert_redirected_to login_path
  end

  test "favouriting a candidate stores a copy that survives the job" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file(body: "<svg>bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :created

    item = ScrapbookItem.order(:id).last
    assert_equal "candidate_01.svg", item.name
    assert_equal "candidate", item.kind
    stored = item.stored_path
    assert stored.file?, "the bytes must be copied into storage/scrapbook"

    # Deleting the job must not touch the scrapbook item or its file — that is
    # the whole requirement.
    job.destroy
    assert ScrapbookItem.exists?(item.id), "the scrapbook survives deleting the job"
    assert stored.file?, "the stored file survives deleting the job"
  end

  test "derives the kind from the runner filename, not from the client" do
    sign_in
    job, = job_with_candidate
    # Each favourite carries DIFFERENT bytes: identical content is deduped (see
    # the content-dedupe tests below), and this test is about the kind of the
    # row each POST actually creates.
    [["source.inverse.png", "invert"], ["source.png", "source"],
     ["candidate_01.proof.png", "proof"]].each do |name, kind|
      with_get_file(body: "<svg>#{name}</svg>") do
        post scrapbook_path, params: { job_id: job.id, name: name },
                             headers: { "User-Agent" => MODERN_UA }
        assert_response :created
      end
      assert_equal kind, ScrapbookItem.order(:id).last.kind
    end
  end

  # ---------- content dedupe: identical bytes are stored once ----------
  #
  # The sha256 taken at creation is the artifact's identity, so a second
  # favourite of the same bytes under the same owner returns the row that is
  # already there — no second row, no second file, no second star event. Only an
  # explicit override=1 makes another copy, which is what the front end's
  # "save another copy?" confirm sends.

  test "identical bytes are stored once and the second favourite reports the duplicate" do
    sign_in
    job, candidate = job_with_candidate
    before = stored_file_count

    with_get_file(body: "<svg>same bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created
      first = JSON.parse(response.body)

      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :ok, "a duplicate is not an error"
      second = JSON.parse(response.body)
      assert_equal true, second["duplicate"], "the UI must be told the bytes are already saved"
      assert_equal first["id"], second["id"], "the row already holding the bytes is returned"
    end

    assert_equal 1, ScrapbookItem.count, "identical bytes are one item"
    assert_equal before + 1, stored_file_count, "the second POST must not write a second file"
  end

  test "override=1 saves another copy of the same bytes" do
    sign_in
    job, candidate = job_with_candidate
    before = stored_file_count

    with_get_file(body: "<svg>same bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created

      post scrapbook_path, params: { job_id: job.id, name: candidate.file, override: "1" },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created, "an explicit override creates the copy as before"
      refute JSON.parse(response.body)["duplicate"]
    end

    assert_equal 2, ScrapbookItem.count
    assert_equal before + 2, stored_file_count
    assert_equal 2, ScrapbookItem.pluck(:file).uniq.size, "the two copies are separate files"
  end

  test "different bytes are not a duplicate" do
    sign_in
    job, candidate = job_with_candidate

    with_get_file(body: "<svg>one</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created
    end

    with_get_file(body: "<svg>two</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created
      refute JSON.parse(response.body)["duplicate"]
    end

    assert_equal 2, ScrapbookItem.count
  end

  test "another operator's copy of the same bytes is not a duplicate" do
    sign_in
    bytes = "<svg>same bytes</svg>"
    job, candidate = job_with_candidate
    with_get_file(body: bytes) do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created
    end

    # A second password IS a second identity. The bytes are the same but the
    # workspace is not, so this favourite must still land a copy of its own.
    User.create!(handle: "other", password: "other-password")
    Current.user_handle = "other"
    other_job = Job.create!(name: "other-scrap", state: "done", source_kind: "svg",
                            input_path: "/data/y.svg", stem: "other-scrap", spec: {},
                            runner: "mock")

    post login_path, params: { password: "other-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect

    with_get_file(body: bytes) do
      post scrapbook_path, params: { job_id: other_job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
      assert_response :created
      refute JSON.parse(response.body)["duplicate"]
    end

    # unscoped on purpose: a request resets Current, and the point is which ROWS
    # exist, not what the scope would show now.
    rows = ScrapbookItem.unscoped.where(sha256: Digest::SHA256.hexdigest(bytes))
    assert_equal 1, rows.where(owner: "test").count
    assert_equal 1, rows.where(owner: "other").count
  end

  test "serves the stored file inline behind the gate" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file(body: "<svg>bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last
    get scrapbook_item_file_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_equal "image/svg+xml", response.media_type
  end

  test "destroy removes the record and its file" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last
    stored = item.stored_path

    delete scrapbook_item_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    refute ScrapbookItem.exists?(item.id)
    refute stored.file?, "destroy must also remove the stored bytes"
  end

  test "rejects a path-traversal name" do
    sign_in
    job, = job_with_candidate
    post scrapbook_path, params: { job_id: job.id, name: "../../etc/passwd" },
                         headers: { "User-Agent" => MODERN_UA }
    assert_response :bad_request
    assert_equal 0, ScrapbookItem.count
  end

  test "reports a runner that cannot serve the file" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file(status: 404, body: "") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    assert_response :bad_gateway
    assert_equal 0, ScrapbookItem.count
  end

  test "use copies the item into uploads and preloads the new-job form" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file(body: "<svg>bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last

    post use_scrapbook_item_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_match %r{/jobs/new\?.*input_path=}, response.location
  end

  test "import stores an edited PNG as a new scrapbook item" do
    sign_in
    png = "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)
    file = Tempfile.new(["edit", ".png"])
    file.binmode
    file.write(png)
    file.rewind

    post scrapbook_import_path,
         params: { file: Rack::Test::UploadedFile.new(file.path, "image/png") },
         headers: { "User-Agent" => MODERN_UA }

    assert_response :created
    item = ScrapbookItem.order(:id).last
    assert_equal "upload", item.kind
    assert item.stored_path.file?, "the exported bytes must be stored"
  ensure
    file.close! if file
  end

  test "importing the same edited bytes twice stores one copy" do
    sign_in
    png = "\x89PNG\r\n\x1a\n".b + ("\x07" * 64)
    before = stored_file_count

    post scrapbook_import_path, params: { file: uploaded_png(png) },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :created
    first = JSON.parse(response.body)

    post scrapbook_import_path, params: { file: uploaded_png(png) },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :ok, "a duplicate export is not an error"
    second = JSON.parse(response.body)
    assert_equal true, second["duplicate"]
    assert_equal first["id"], second["id"]

    assert_equal 1, ScrapbookItem.count, "the second export must not become a second item"
    assert_equal before + 1, stored_file_count, "the second export must not be written to storage"
  end

  test "import override=1 saves another copy of the same edited bytes" do
    sign_in
    png = "\x89PNG\r\n\x1a\n".b + ("\x08" * 64)
    before = stored_file_count

    post scrapbook_import_path, params: { file: uploaded_png(png) },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :created

    post scrapbook_import_path, params: { file: uploaded_png(png), override: "1" },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :created
    refute JSON.parse(response.body)["duplicate"]

    assert_equal 2, ScrapbookItem.count
    assert_equal before + 2, stored_file_count
  end

  test "import rejects non-image bytes" do
    sign_in
    file = Tempfile.new(["edit", ".png"])
    file.binmode
    file.write("not an image at all")
    file.rewind

    post scrapbook_import_path,
         params: { file: Rack::Test::UploadedFile.new(file.path, "image/png") },
         headers: { "User-Agent" => MODERN_UA }

    assert_response :bad_request
    assert_equal 0, ScrapbookItem.count
  ensure
    file.close! if file
  end

  test "reference copies a raster scrapbook item into uploads" do
    sign_in
    png = "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)
    job, = job_with_candidate
    with_get_file(body: png) do
      post scrapbook_path, params: { job_id: job.id, name: "source.png" },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last

    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    before = Dir.glob(uploads.join("upload_*")).size

    post scrapbook_item_reference_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    json = JSON.parse(response.body)
    assert json["path"].to_s.start_with?(uploads.to_s),
           "the reference must be copied into storage/uploads, not served from the scrapbook"
    assert File.file?(json["path"]), "the copied file must exist"
    assert_equal File.size(json["path"]), json["size"]
    assert json["preview_url"].present?
    assert_equal before + 1, Dir.glob(uploads.join("upload_*")).size
  end

  test "reference refuses a non-raster scrapbook item" do
    sign_in
    job, candidate = job_with_candidate
    with_get_file(body: "<svg>bytes</svg>") do
      post scrapbook_path, params: { job_id: job.id, name: candidate.file },
                           headers: { "User-Agent" => MODERN_UA }
    end
    item = ScrapbookItem.order(:id).last

    post scrapbook_item_reference_path(item), headers: { "User-Agent" => MODERN_UA }
    assert_response :unprocessable_entity
    assert_match(/PNG or JPEG/, JSON.parse(response.body)["error"])
  end

  test "save_upload copies a generated flux raster into the scrapbook" do
    sign_in
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    png = "\x89PNG\r\n\x1a\n".b + ("\x00" * 64)
    src = uploads.join("flux_abc123.png")
    File.binwrite(src, png)

    begin
      post scrapbook_save_upload_path, params: { name: "flux_abc123.png", job_id: 42 },
           headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect

      item = ScrapbookItem.order(:id).last
      assert_equal "flux_abc123.png", item.name
      assert_equal "flux", item.kind
      assert_equal 42, item.job_id
      assert item.stored_path.file?, "the bytes must be copied into storage/scrapbook"
      assert_equal png, File.binread(item.stored_path)
    ensure
      File.delete(src) if File.exist?(src)
    end
  end

  test "save_upload stores the same generated raster once" do
    sign_in
    uploads = Rails.root.join("storage", "uploads")
    uploads.mkpath
    png = "\x89PNG\r\n\x1a\n".b + ("\x09" * 64)
    src = uploads.join("flux_dedupe.png")
    File.binwrite(src, png)
    before = stored_file_count

    begin
      post scrapbook_save_upload_path, params: { name: "flux_dedupe.png", job_id: 7 },
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_response :created
      first = JSON.parse(response.body)

      post scrapbook_save_upload_path, params: { name: "flux_dedupe.png", job_id: 7 },
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_response :ok
      second = JSON.parse(response.body)
      assert_equal true, second["duplicate"]
      assert_equal first["id"], second["id"]

      # The HTML caller (the variations grid's save button) gets the same news
      # as a notice, not a silent no-op.
      post scrapbook_save_upload_path, params: { name: "flux_dedupe.png", job_id: 7 },
           headers: { "User-Agent" => MODERN_UA }
      assert_response :redirect
      assert_match(/Already in the scrapbook/, flash[:notice].to_s)

      # An explicit override is the one thing that makes a second copy.
      post scrapbook_save_upload_path, params: { name: "flux_dedupe.png", job_id: 7, override: "1" },
           headers: { "User-Agent" => MODERN_UA, "Accept" => "application/json" }
      assert_response :created
      refute JSON.parse(response.body)["duplicate"]
    ensure
      File.delete(src) if File.exist?(src)
    end

    assert_equal 2, ScrapbookItem.count
    assert_equal before + 2, stored_file_count
  end

  test "save_upload refuses a name that would leave storage/uploads" do
    sign_in
    post scrapbook_save_upload_path, params: { name: "../../etc/passwd" },
         headers: { "User-Agent" => MODERN_UA }
    assert_response :bad_request
    assert_equal 0, ScrapbookItem.count
  end
end
