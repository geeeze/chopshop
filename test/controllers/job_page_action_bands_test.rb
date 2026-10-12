require "test_helper"

# THE TWO ACTION BANDS on the job page, and the duplicate that was removed.
#
# Issue #67: band 1 (.job-keep-row) and the sticky band 2 (.job-persist) each
# carried a link to `new_job_path` with the SAME four params — same target, same
# query, different word ("RUN JOB" vs "Run Job") and different class. One link
# to one destination, offered twice on one screen: the operator reads two
# controls as two destinations and then has to work out that they are the same
# form. The duplicate is gone; band 1 is now SCRAPBOOK / COMPOSITE / JOB TYPE
# and the sticky bar keeps the one persistent Run Job.
#
# Asserted on the SERVED page, not on the template source: the count is a
# property of the rendered output, and a template grep cannot tell the reader
# that both copies actually rendered.
class JobPageActionBandsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # A done job with a source, so both bands render at all: both are wrapped in
  # one condition on `input_path` existing, and a bar offering "Download" for a
  # file that is not there is worse than no bar.
  def job_with_source
    Job.create!(name: "ring", state: "done", source_kind: "raster",
                input_path: "storage/uploads/ring.png", stem: "ring",
                spec: {}, runner: "mock", comparison: { "candidates" => [] })
  end

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def doc
    get job_path(@job), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  setup do
    @job = job_with_source
    login!
  end

  # Every link to the Run Job form carrying THIS job's input AND name -- the
  # exact pair the removed band-1 copy and the surviving sticky copy share, so
  # the count catches a re-added duplicate and nothing else. Matching on
  # input_path alone would also count JOB TYPE, which is a DIFFERENT control
  # (it changes the job kind and deliberately carries no name); matching on the
  # label alone would miss a re-added copy that was renamed.
  def run_job_links(page)
    page.css("a").select do |a|
      href = a["href"].to_s
      href.include?("/jobs/new") &&
        href.include?("input_path=#{CGI.escape(@job.input_path)}") &&
        href.include?("name=#{CGI.escape(@job.name)}")
    end
  end

  test "the Run Job form is reachable from exactly one link" do
    links = run_job_links(doc)
    assert_equal 1, links.size,
      "two links to the same new-job form is the duplicate this issue removed — " \
      "found #{links.size}: #{links.map { |l| l.text.strip }.inspect}"

    # And the one that remains is the STICKY one, which is the persistent
    # control: a long candidate table must not scroll the way to run it away.
    remaining = links.first
    assert remaining.at_xpath("ancestor::div[contains(@class,'job-persist')]"),
      "the surviving Run Job link must be the sticky band's, not a band-1 one"
    assert_equal "Run Job", remaining.text.strip,
      "the sticky control keeps its own label"
  end

  test "band 1 still offers SCRAPBOOK, COMPOSITE and JOB TYPE" do
    band = doc.at_css(".job-keep-row")
    refute_nil band, "band 1 must still render"
    labels = band.css("a, button").map { |n| n.text.strip }

    assert_includes labels, "SCRAPBOOK", "the scrapbook save stays in band 1"
    assert_includes labels, "COMPOSITE", "the composite builder stays in band 1"
    assert_includes labels, "JOB TYPE", "the job-type change stays in band 1"
    refute_includes labels, "RUN JOB",
      "the band-1 duplicate is gone — Run Job is the sticky band's job"
  end

  test "COMPOSITE and JOB TYPE keep their own destinations" do
    band = doc.at_css(".job-keep-row")
    composite = band.css("a").find { |a| a.text.strip == "COMPOSITE" }
    refute_nil composite, "COMPOSITE must render"
    assert_includes composite["href"].to_s, composite_path(name: @job.name),
      "COMPOSITE navigates to the builder and deliberately carries no source"

    # JOB TYPE is the band-1 control that DOES carry the source, and it is not
    # the removed link: it has no `name` param, so its href differs from the
    # sticky Run Job's.
    job_type = band.css("a").find { |a| a.text.strip == "JOB TYPE" }
    refute_nil job_type, "JOB TYPE must render"
    refute_includes job_type["href"].to_s, "name=#{CGI.escape(@job.name)}",
      "JOB TYPE is the job-KIND change, not a second copy of the run link"
    assert_includes job_type["href"].to_s, "input_path=#{CGI.escape(@job.input_path)}",
      "and it is the band-1 control that DOES carry the source"
  end

  test "the sticky band keeps its full set: back, Run Job, download" do
    persist = doc.at_css(".job-persist")
    refute_nil persist, "the persistent band must render"
    labels = persist.css("a").map { |n| n.text.strip }
    assert_equal ["← Project", "Run Job", "Download"], labels,
      "the sticky bar is the way out, the run and the file — nothing else"
  end
end
