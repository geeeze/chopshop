require "test_helper"

# The footer's check-engine light: a small round orb in the status bar that
# LINKS to the STATUS page, and the ML/ranking configuration that page reports.
# Three contracts are pinned here.
#
#   * The orb is a status control, not a word button and not a popup trigger. It
#     carries an engine glyph and a dot whose colour is gated on whether the
#     owner has recorded anything to train on -- amber with zero events, green
#     the moment one star, pick or delete exists -- and it is gated on
#     current_user, because the footer bar itself renders on EVERY page,
#     /login included.
#
#   * STATUS left the sticky header, so the orb is now the only way to that
#     page.
#
#   * The shipped constants are reported VERBATIM on the page. Re-wording a
#     number would make the panel a page that lies about the pipeline it
#     describes -- the failure mode plot_page_test.rb pins for the same reason.
#     Nothing there configures anything.
class EngineLightTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def page(path)
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  end

  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  # The light's own markup, on whatever page it is rendered.
  def light(doc)
    node = doc.at_css(".engine-light")
    refute_nil node, "the footer must carry the check-engine light"
    node
  end

  # One telemetry number, read back by the key the page publishes -- so the
  # assertions are about the FIELD, not about a column's position in the strip.
  def stat(doc, key)
    node = doc.at_css("[data-telemetry-count='#{key}']")
    refute_nil node, "the page must report #{key}"
    node.text.strip.to_i
  end

  # The ML / ranking panel as one string: whitespace collapsed, so a phrase that
  # wraps across source lines still reads as the phrase it is.
  def ml_text(doc)
    section = doc.at_css("[data-status-panel='ml']")
    refute_nil section, "the STATUS page must carry the ML / ranking panel"
    section.text.gsub(/\s+/, " ")
  end

  # -- the footer light ----------------------------------------------------

  test "the light renders for a signed-in owner and never on the login page" do
    anon = page(login_path)
    assert_nil anon.at_css(".engine-light"), "the logged-out page gets no orb"

    sign_in
    orb = light(page(root_path))
    assert_equal status_path, orb["href"],
      "the light navigates to STATUS; it is a link, not a popup trigger"
    assert_nil orb["data-popup"], "no popup wiring on it"
    refute_nil orb.at_css("svg"), "the engine glyph"
    refute_nil orb.at_css(".engine-light-dot"), "and the status dot beside it"
    assert_equal "", orb.text.strip, "the orb carries no word on it"
    assert_match(/Engine \/ telemetry/, orb["aria-label"])
    assert_equal orb["aria-label"], orb["title"],
      "the title and the accessible name are the same statement"
  end

  test "the dot is amber with no recorded events and green once there is one" do
    sign_in
    cold = light(page(root_path))
    assert_includes cold["class"].split, "is-cold"
    assert_match(/no training signal yet/, cold["title"],
      "the cold state is said in words, not only in the dot's colour")

    Event.create!(event: "star", owner: "test")
    live = light(page(root_path))
    assert_includes live["class"].split, "is-live"
    refute_includes live["class"].split, "is-cold"
    refute_match(/no training signal yet/, live["title"])
  end

  test "the light is the only way to STATUS, which left the header nav" do
    sign_in
    doc = page(root_path)

    labels = doc.css("nav.topbar .nav-links a").map { |a| a.text.strip }
    refute_includes labels, "STATUS", "STATUS is out of the sticky header"
    assert_equal "BLENDER", labels.last,
      "the newest sidecar is the last link, and PLOT was before it"
    refute_nil doc.at_css("a.engine-light[href='#{status_path}']"),
      "and the footer light is what carries you there"
  end

  test "the CSS styles the orb and both light states" do
    css = css_without_comments

    rule = css[/\n\.engine-light \{[^}]*\}/m]
    refute_nil rule, "the orb must be styled"
    assert_match(/border-radius: 50%/, rule,
      "a round orb, in the family of the app's other round controls")
    assert_match(/width: 1\.35rem/, rule,
      "small: a footer control, not a primary button")
    assert_match(/text-decoration: none/, rule,
      "it must not read as the footer's underlined link")

    cold = css[/\.engine-light\.is-cold \.engine-light-dot \{[^}]*\}/m]
    refute_nil cold, "the cold state must colour the dot"
    assert_match(/background: var\(--warning/, cold, "amber while there is no signal")

    live = css[/\.engine-light\.is-live \.engine-light-dot \{[^}]*\}/m]
    refute_nil live, "the live state must colour the dot"
    assert_match(/background: var\(--success/, live, "green once one event exists")

    # The orb rides in the bar's right-hand chrome, beside the About link.
    assert_match(/\n\.footer-chrome \{[^}]*display: flex/m, css)

    # The popup this used to open is gone, rules and all.
    refute_includes css, ".popup-engine"
    refute_includes css, ".engine-grid"
  end

  # -- the STATUS page carries the configuration ---------------------------

  test "the telemetry strip counts this owner's recorded signal" do
    job = Job.create!(name: "signal", state: "done", source_kind: "svg",
                      input_path: "/data/signal.svg", stem: "signal", spec: {},
                      runner: "mock")
    job.candidates.create!(file: "candidate_01.svg")
    job.candidates.create!(file: "candidate_02.svg")
    ScrapbookItem.create!(name: "candidate_01.svg", kind: "candidate",
                          file: "fav_01.svg", job_id: job.id)
    Event.create!(event: "star", owner: "test", job_id: job.id)
    Event.create!(event: "star", owner: "test", job_id: job.id)
    Event.create!(event: "pick", owner: "test", job_id: job.id)

    sign_in
    doc = page(status_path)

    assert_equal 3, stat(doc, "events"), "two stars and one pick"
    assert_equal 2, stat(doc, "star")
    assert_equal 1, stat(doc, "pick")
    assert_equal 0, stat(doc, "unstar")
    assert_equal 0, stat(doc, "delete")
    assert_equal 1, stat(doc, "jobs")
    assert_equal 2, stat(doc, "candidates")
    assert_equal 1, stat(doc, "scrapbook")
  end

  test "the strip says so in words when there is nothing to train on yet" do
    sign_in
    doc = page(status_path)
    strip = doc.at_css("[data-telemetry-strip]")
    refute_nil strip
    assert_equal 0, stat(doc, "events")
    assert_includes strip.text, "no training signal yet"

    Event.create!(event: "pick", owner: "test")
    refute_includes page(status_path).at_css("[data-telemetry-strip]").text,
                    "no training signal yet"
  end

  test "every count is the signed-in owner's; another owner's rows stay invisible" do
    User.create!(handle: "other", password: "other-password")
    theirs = Job.new(name: "theirs", state: "done", source_kind: "svg",
                     input_path: "/data/theirs.svg", stem: "theirs", spec: {},
                     runner: "mock", owner: "other")
    theirs.save!
    theirs.candidates.create!(file: "candidate_01.svg")
    ScrapbookItem.create!(name: "theirs.svg", kind: "source",
                          file: "theirs_fav.svg", owner: "other", job_id: theirs.id)
    Event.create!(event: "pick", owner: "other", job_id: theirs.id)

    sign_in
    doc = page(status_path)

    %w[events star unstar pick delete jobs candidates scrapbook].each do |key|
      assert_equal 0, stat(doc, key), "#{key} must not count another operator's rows"
    end
  end

  test "the counts come from one owner-scoped source, read once per page" do
    # The layout renders on every authed page, so the footer's read is memoized
    # and both surfaces read the SAME source -- a second copy of these counts
    # would be free to drift from the strip.
    src = Rails.root.join("app/helpers/application_helper.rb").read
    assert_match(/def engine_light_metrics\n\s+@engine_light_metrics \|\|= Telemetry\.metrics/,
                 src, "the footer's read must memoize Telemetry.metrics")

    model = Rails.root.join("app/models/telemetry.rb").read
    assert_includes model, "Event.of_kind(kind).count"
    assert_includes model, "Candidate.where(job_id: Job.select(:id)).count",
                    "candidates are owner-scoped through their job"
  end

  # -- the ML / ranking panel ----------------------------------------------

  test "the STATUS page reports the ranker's shipped configuration" do
    sign_in
    body = ml_text(page(status_path))

    assert_includes body, "learn_min_picks=30", "the cold-start pick threshold"
    assert_includes body, "learn_min_jobs=2", "the cold-start job threshold"

    %w[bias hard advisory node_count_max mae_art colours speckles
       bucket_speckle_bin bucket_colour_bin].each do |feature|
      assert_includes body, feature, "#{feature} is one of the ranker's features"
    end
    assert_includes body, "per-preset one-hot"

    assert_includes body, "Fewest hard gates, then advisories, then artwork MAE",
                    "the hand-order fallback, in order"
    assert_includes body, "sorts last", "a missing reading is not a good reading"

    assert_includes body, "1 slot", "the reserved anti-feedback slot"
    assert_includes body, "top-8", "inside the visible window"
    assert_includes body, "n_random_slots=1"
    assert_includes body, "window=8"

    assert_includes body, "never picks a winner",
                    "the rule the whole ranking stack rests on"
  end

  test "the STATUS page reports the bandit's shipped configuration" do
    sign_in
    body = ml_text(page(status_path))

    assert_includes body, "Beta-Bernoulli Thompson sampling"
    assert_includes body, "bucket keys", "sampled over buckets, never over candidates"
    assert_includes body, "epsilon 0.1"
    assert_includes body, "30 days", "the bucket TTL"
    assert_includes body, "veto list"
    assert_includes body, "successes and attempts"
  end

  test "the STATUS page reports the triage gate defaults verbatim" do
    sign_in
    body = ml_text(page(status_path))

    assert_includes body, "max_unique_colors 8"
    assert_includes body, "max_speckles 40"
    assert_includes body, "max_glow_area_pct 8"
    assert_includes body, "min_silhouette_iou 0.85"
    assert_includes body, "min_luma_delta 12"
    assert_includes body, "weak_needed 3"
    assert_includes body, "bucket_cap 2"

    assert_includes body, "HARD gate", "a hard hit drops"
    assert_includes body, "WEAK gate", "a weak hit demotes"
  end

  test "the STATUS page says where the learned files live and what they learn from" do
    sign_in
    body = ml_text(page(status_path))

    assert_includes body, "learned_ranker.json"
    assert_includes body, "learned_buckets.json"
    assert_includes body, "PIPELINE_LEARNING_DIR"
    assert_includes body, "event log", "the signal is THIS studio's own recorded actions"
    assert_includes body, "GET /events"
  end

  test "the panel is read-only and configures nothing" do
    sign_in
    doc = page(status_path)

    section = doc.at_css("[data-status-panel='ml']")
    # No form control of any kind: the constants are reported, not set. A field
    # here would be a control that appears to write configuration this app
    # cannot write.
    assert_empty section.css("input, select, textarea, button"),
      "the panel must carry no controls"
    assert_includes section.text, "nothing on this page can change any of it"
    assert_equal 4, section.css("[data-telemetry-group]").size,
      "ranker, bandit, gates, learned files"
  end
end
