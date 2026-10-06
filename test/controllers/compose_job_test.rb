require "test_helper"

# A FLATTENED COMPOSITE IS A JOB.
#
# Compose work used to live only as a Composite row plus a scrapbook item, so an
# agent-made composite or album appeared NOWHERE in the Jobs history and clicking
# its image led to no results page at all. A flatten now records a Job: the same
# lineage every other run has (a name, an owner, a state, a preview, a page), and
# the provenance a reader needs -- which composite it came from and what that
# composite was made of.
#
# The job is created ALREADY DONE, because nothing is dispatched: the merge has
# happened by the time the row is written. That is why it must also answer
# `locally_produced?` -- a job with no runner job id must never have an archive
# or a dataset URL built for it.
class ComposeJobTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  SVG_LAYER = "data:image/svg+xml;base64," \
              "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCI+PHJlY3Qgd2lkdGg9IjUiIGhlaWdodD0iNSIvPjwvc3ZnPg==".freeze

  def with_runners
    saved = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| saved[k] = ENV.delete(k) }
    begin
      ENV["CHOPSHOP_RUNNER_SVG_URL"] = "http://pipeline.invalid:8787"
      ENV.delete("CHOPSHOP_COMPOSE_URL")
      Job.reset_runners_cache!
      yield
    ensure
      ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |k| ENV.delete(k) }
      saved.each { |k, v| ENV[k] = v }
      Job.reset_runners_cache!
    end
  end

  def layer(src: SVG_LAYER, w: 40, h: 40)
    { "name" => "piece", "kind" => "vector", "src" => src,
      "x" => 5, "y" => 7, "w" => w, "h" => h }
  end

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The compose itself is the SVG RUNNER's /compose route, and these tests must
  # not need one: stub the client the same way blender_job_test stubs its own
  # (define_singleton_method, restored in an ensure) rather than reaching for
  # minitest/mock, which this suite does not carry.
  def stubbing_compose(bytes: "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"60\" height=\"60\"><rect width=\"6\" height=\"6\"/></svg>")
    original = ComposeClient.method(:compose)
    ComposeClient.define_singleton_method(:compose) do |_base, _spec, **_kw|
      { bytes: bytes, content_type: "image/svg+xml", name: "merged.svg" }
    end
    yield
  ensure
    ComposeClient.define_singleton_method(:compose, original)
  end

  def flatten(composite)
    stubbing_compose do
      post flatten_composite_path(composite), headers: { "User-Agent" => MODERN_UA }
    end
  end

  # --- the model's own answers ---------------------------------------------

  test "a job carrying a compose block is a compose job, and knows it is local" do
    job = Job.new(name: "x", runner: "mock", spec: { "compose" => { "mode" => "vector" } })
    assert job.compose?
    assert job.locally_produced?,
      "a compose job dispatched nothing, so no runner-backed URL may be built for it"
    assert_equal "vector", job.compose_mode
    assert_nil job.compose_output_file

    plain = Job.new(name: "y", runner: "mock", spec: {})
    refute plain.compose?, "a spec with no compose block is not a compose job"
    refute plain.locally_produced?, "and it is not locally produced"
  end

  test "a compose job's preview is the merged artefact, from uploads" do
    job = Job.new(name: "x", runner: "mock", state: "done",
                  spec: { "compose" => { "rendered" => { "file" => "upload_abc.svg",
                                                         "mode" => "vector" } } })
    assert_equal "upload_abc.svg", job.preview_file,
      "the composed artefact is what the row shows"
    assert job.preview_from_upload?,
      "it is a storage/uploads file, so it is served through upload_preview"
  end

  test "a finished proof still outranks a compose job's own artefact" do
    job = Job.new(name: "x", runner: "mock", state: "done",
                  spec: { "compose" => { "rendered" => { "file" => "upload_abc.svg" } } })
    job.validations = [ Validation.new(file: "candidate_01.svg", state: "done",
                                      manifest: { "proof" => "proof_01.png" }) ]
    assert_equal "proof_01.png", job.preview_file,
      "the proof rule holds for every kind, compose included"
  end

  # --- the flatten records it ----------------------------------------------

  test "flattening a composite records a Job with its provenance" do
    with_runners do
      sign_in
      composite = Composite.create!(name: "agent album", width: 100, height: 100,
                                    layers: [ layer ])

      assert_difference -> { Job.count }, 1 do
        flatten(composite)
      end
      assert_response :success

      job = Job.order(:id).last
      assert_equal "agent album", job.name
      assert job.compose?, "the job is marked by its own spec block"
      assert_equal "done", job.state, "the merge already happened: nothing is dispatched"
      assert_equal composite.id, job.compose_composite_id
      assert_equal 1, job.compose_layer_count
      assert job.compose_output_file.present?, "and it records the file it published"
      assert_equal "svg", job.runner,
        "filed against the label whose URL owns the /compose route (the pipeline " \
        "runner configured by CHOPSHOP_RUNNER_SVG_URL)"

      # The JSON answer carries the way to the new page, so a caller (an agent)
      # does not have to guess the id back out of the database.
      body = JSON.parse(response.body)
      assert_equal job.id, body["job_id"]
      assert_equal job_path(job), body["job_url"]
    end
  end

  # The Jobs list lost its own page in the Projects redesign: a composed run is
  # listed in the PROJECT WORKSPACE, which is where its thumbnail is shown.
  test "the new job appears in the project workspace's job list with a working thumbnail" do
    with_runners do
      sign_in
      project = Project.create!(name: "compose-history", is_test: true)
      composite = Composite.create!(name: "agent composite", width: 60, height: 60,
                                    layers: [ layer ], project_id: project.id)
      flatten(composite)
      job = Job.order(:id).last

      get project_path(project), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      doc = Nokogiri::HTML(response.body)

      row = doc.css("#jobs-list tr").find { |tr| tr.text.include?("agent composite") }
      refute_nil row, "the composed run is in the history, not only the scrapbook"

      img = row.at_css("img[alt='Preview for agent composite']")
      refute_nil img, "and it has a thumbnail"
      assert_equal upload_preview_jobs_path(name: job.compose_output_file), img["src"],
        "served from uploads, because the artefact is local"
    end
  end

  test "the compose job's results page shows the merged artefact and its provenance" do
    with_runners do
      sign_in
      composite = Composite.create!(name: "page composite", width: 60, height: 60,
                                    layers: [ layer ])
      flatten(composite)
      job = Job.order(:id).last

      get job_path(job), headers: { "User-Agent" => MODERN_UA }
      assert_response :success
      doc = Nokogiri::HTML(response.body)

      card = doc.at_css("[data-compose-output]")
      refute_nil card, "the page renders the composed artefact, not an empty results shell"
      img = card.at_css("img")
      assert_equal upload_preview_jobs_path(name: job.compose_output_file), img["src"]
      assert_includes card.text, "1 layer"
      assert_includes card.to_html, composite_path(id: composite.id),
        "provenance: a link back to the composite it was merged from"
    end
  end
end
