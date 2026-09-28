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
  end

  def job_with_candidate
    job = Job.create!(name: "scrap", state: "done", source_kind: "svg",
                      input_path: "/data/x.svg", stem: "scrap", spec: {}, runner: "mock")
    [job, job.candidates.create!(file: "candidate_01.svg")]
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
    with_get_file do
      post scrapbook_path, params: { job_id: job.id, name: "source.inverse.png" },
                           headers: { "User-Agent" => MODERN_UA }
      assert_equal "invert", ScrapbookItem.order(:id).last.kind
      post scrapbook_path, params: { job_id: job.id, name: "source.png" },
                           headers: { "User-Agent" => MODERN_UA }
      assert_equal "source", ScrapbookItem.order(:id).last.kind
      post scrapbook_path, params: { job_id: job.id, name: "candidate_01.proof.png" },
                           headers: { "User-Agent" => MODERN_UA }
      assert_equal "proof", ScrapbookItem.order(:id).last.kind
    end
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
end
