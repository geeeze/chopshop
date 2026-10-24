require "test_helper"
require "zlib"
require "tmpdir"

# Pins the no-browser agent path end to end: a local agent authenticates with a
# POST (the shared-password gate, not the browser orb), uploads a raster, and
# creates a job -- then the job is really IN the history, not merely persisted.
# The deployed stack was driven this way with curl; this test holds that
# contract, so a change to the login, upload JSON or create flow that breaks an
# agent is caught here.
#
# THE HISTORY IS THE PROJECT WORKSPACE now: the 2026-09-30 Projects redesign
# deleted GET /jobs, and a job is only visible in the workspace of the project
# it files under (`job[project_id]` is a permitted create param). A job with no
# project is UI-invisible, so every job here is created inside one.
#
# The RunnerClient is stubbed: the API path must not require a live runner. A
# create now enqueues a RunJob (job shows "queued") rather than minting the
# runner_job_id synchronously, but it still lands in the history immediately.
# #index also syncs any in-flight job, so get_job is stubbed as well.
class AgentDrivenJobTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The smallest real PNG: 4x4 opaque red. The controller magic-byte checks the
  # first bytes, so the bytes have to be a PNG, not just a .png name.
  def write_tiny_png(path)
    raw = ("\x00" + ("\xff\x00\x00\xff" * 4)).b * 4
    png = "\x89PNG\r\n\x1a\n".b +
          png_chunk("IHDR", [ 4, 4, 8, 6, 0, 0, 0 ].pack("NNCCCCC")) +
          png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
          png_chunk("IEND", "".b)
    File.binwrite(path, png)
    path
  end

  def png_chunk(type, data)
    [ data.bytesize ].pack("N") + type + data +
      [ Zlib.crc32(type + data) & 0xffffffff ].pack("N")
  end

  # Swap the runner out for the duration of the block, restoring both methods
  # afterwards. Same hand-rolled technique as the other controller tests, since
  # Minitest 6 dropped minitest/mock.
  def with_stubbed_runner
    created = RunnerClient.method(:create_job)
    fetched = RunnerClient.method(:get_job)
    RunnerClient.define_singleton_method(:create_job) { |job| { id: "runner-#{job.id}" } }
    RunnerClient.define_singleton_method(:get_job) do |_job|
      { state: "done", prep_summary: nil, candidate_count: 0, comparison: nil }
    end
    yield
  ensure
    RunnerClient.define_singleton_method(:create_job, created)
    RunnerClient.define_singleton_method(:get_job, fetched)
  end

  def sign_in_as_agent
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  test "an agent session can upload, create a job, and see it in the history" do
    upload_path = nil
    Dir.mktmpdir do |dir|
      source = write_tiny_png(File.join(dir, "agent_probe.png"))

      sign_in_as_agent
      assert_response :redirect, "the agent login POST must be accepted"

      with_stubbed_runner do
        # The workspace the agent files its run into: the history it must show
        # up in is this project's, so the create carries the project_id.
        project = Project.create!(name: "agent-history", is_test: true)

        # --- upload: the JSON contract the agent form posts against ---------
        post upload_jobs_path,
             params: { file: Rack::Test::UploadedFile.new(source, "image/png") },
             headers: { "User-Agent" => MODERN_UA }

        assert_response :success
        upload = JSON.parse(response.body)
        assert_equal %w[path preview_url name size].sort, upload.keys.sort
        assert_equal "agent_probe.png", upload["name"]
        assert upload["size"].to_i.positive?, "the upload reports the stored byte size"
        assert upload["path"].end_with?(".png"), "the stored path is a raster: #{upload['path']}"
        assert_equal upload_preview_jobs_path(name: File.basename(upload["path"])),
                     upload["preview_url"]
        upload_path = upload["path"]

        # --- create: the form route (302 -> /jobs/:id), not the runner's JSON
        post jobs_path,
             params: { job: { name: "agent-curl-probe", source_kind: "raster",
                              runner: "mock", input_path: upload["path"],
                              spec: "{}", project_id: project.id } },
             headers: { "User-Agent" => MODERN_UA }

        assert_response :redirect
        redirect_target = URI.parse(response.location).path
        assert_match(%r{\A/jobs/\d+\z}, redirect_target,
                     "create must land on the job page, got #{response.location}")

        job = Job.find(redirect_target[%r{\d+\z}].to_i)
        assert_equal "agent-curl-probe", job.name
        assert_equal upload["path"], job.input_path
        assert_equal project.id, job.project_id,
                     "the run is filed under the project the agent named"
        assert_equal "queued", job.state, "create queues now; the worker dispatches"

        # --- the history: parse the HTML, do not assume ---------------------
        follow_redirect!
        assert_response :success, "the created job's page must render"

        get project_path(project), headers: { "User-Agent" => MODERN_UA }
        assert_response :success
        doc = Nokogiri::HTML(response.body)
        row = doc.css("tr").find { |r| r.text.include?("agent-curl-probe") }
        refute_nil row, "the agent-set job must appear in the project's history"
        link = row.at_css("a.cs-job-name")
        refute_nil link, "the history row links to the job"
        assert_equal job_path_url(job), link["href"]
      end
    end
  ensure
    File.delete(upload_path) if upload_path && File.exist?(upload_path)
  end

  # The history is the point of the question: a job an agent sets is visible to
  # the same single user, not trapped in the runner. The history is the project
  # workspace, so the job is filed under a project the operator owns.
  test "a job created directly by an agent is listed for the operator" do
    with_stubbed_runner do
      sign_in_as_agent
      project = Project.create!(name: "agent-listed-ws", is_test: true)
      job = Job.create!(name: "agent-listed", state: "done", source_kind: "raster",
                        input_path: "/data/agent.png", stem: "agent-listed",
                        spec: {}, runner: "mock", project: project)

      get project_path(project), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      doc = Nokogiri::HTML(response.body)
      assert(doc.css("tr").any? { |r| r.text.include?(job.name) },
             "a job set without a browser must still show up in the history")
    end
  end

  private

  def job_path_url(job)
    "/jobs/#{job.id}"
  end
end
