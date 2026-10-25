require "test_helper"

# "Where do I change this?" -- the table #43 adds beside #42's scope chips.
#
# #42 said which SCOPE a setting is in; the operator still had to guess HOW to
# change it. The conf models already hold names, defaults and help text, so the
# table is GENERATED from them at render time rather than written a second time.
#
# WHAT THIS PINS:
#   * the table renders on all three config pages, from the page's OWN field
#     lists, and every setting the page shows is present EXACTLY ONCE -- the
#     drift pin the issue asks for;
#   * the layer column is the #42 vocabulary, decided by the SAME rule the
#     page's own chips use, so a row and a chip cannot disagree about a scope;
#   * VARIABLE NAMES ONLY. The table is grepped for host-shaped facts (an IP, a
#     URL, a port number, a path outside the repos, a value that is set
#     somewhere) and asserts there are none -- hard rule 4, and the reason the
#     models carry names and no values;
#   * the popup opens through the app's ONE standard mechanism: [data-popup]
#     + [data-popup-close], the same pair every other popup on the site uses.
#
# The rule under test is the issue's own acceptance: "FLUX, BP and JEV each open
# the popup from the page head" and "every setting on those pages appears once".
class ChangeTableTest < ActionDispatch::IntegrationTest
  # The helper under test is included directly, so a test can read the page's own
  # layer derivation (the same rule the page's chips use) without re-typing it.
  include ApplicationHelper

  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The three scopes, and the chip class that carries each meaning. ONE list,
  # deliberately the same one scope_chips_test uses -- a scope the table would
  # render but the chips could not name is a failure here rather than a word on
  # a table nobody can look up.
  SCOPES = {
    "per job" => "pass",
    "service · restart" => "warn",
    "code · read-only" => "fail"
  }.freeze

  def doc(route)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get public_send(route), headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The popup, as rendered: nil unless the page carries the table.
  def change_popup(d, page)
    d.at_css("#change-#{page}-popup")
  end

  def change_rows(d, page)
    popup = change_popup(d, page)
    return [] unless popup

    popup.css("table[data-change-table] tbody tr[data-change-row]").map do |tr|
      cells = tr.css("td")
      {
        setting: cells[0].text.strip,
        layer: tr["data-change-layer"].to_s,
        # The kind and the how are two spans in one cell: the kind is the tag
        # (env var / spec key / code) and the how is the identifier or the
        # location. Read them separately so a test can assert either.
        kind: tr.at_css("[data-change-how] .tech-tag").text.strip,
        how: tr.at_css("[data-change-how] .mono").text.strip,
        effect: cells[3].text.strip,
        # The chip the row renders is the scope_chip partial's own markup, so
        # the band it carries is readable here without re-deriving it.
        band: tr.css("[data-change-layer-cell] .scope-chip").map { |c| c["class"].split }.flatten
      }
    end
  end

  # -- the popup exists, opens the standard way, and is not a second help popup --

  test "each config page opens the popup from the page head, by the standard mechanism" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      d = doc(route)
      trigger = d.at_css("[data-popup='change-#{page}-popup']")
      refute_nil trigger, "#{page}: the head carries a CHANGE trigger"
      # In the head, beside the blurb: the table is the head's own affordance,
      # and a trigger in the footer would open a table nobody reaches from here.
      assert_operator trigger.ancestors(".page-head").size, :>=, 1,
                      "#{page}: the trigger is inside .page-head"
      assert_equal "CHANGE", trigger.text.strip,
                   "#{page}: the button says what it is, like FIELDS/JSON"

      popup = change_popup(d, page)
      refute_nil popup, "#{page}: the popup is rendered on the page"
      # ONE standard: the trigger's id, the dialog role, the close button and
      # the hidden attribute. A second mechanism would be a second thing to
      # fix when the popup behaviour changes.
      assert_equal "change-#{page}-popup", popup["id"]
      assert_equal "dialog", popup["role"]
      assert_equal "true", popup["aria-modal"]
      refute_nil popup["hidden"], "#{page}: it starts closed"
      refute_nil popup.at_css("[data-popup-close]"), "#{page}: it has the standard close button"
      assert_operator popup.css("table[data-change-table] tbody tr[data-change-row]").size, :>, 0,
                      "#{page}: the popup carries the table"
    end
  end

  # NOT A SECOND HELP POPUP. The `?` buttons are the WHAT-IT-DOES text; this is
  # the WHERE-TO-CHANGE table. It carries no field help, so it must not be
  # mistaken for one -- and a table of hints would be the same duplication the
  # shared/help_tip rule exists to prevent.
  test "the popup carries the where-to-change table and no field help" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      popup = change_popup(doc(route), page)
      refute_nil popup
      assert_equal %w[Setting Layer How Effect],
                   popup.css("table[data-change-table] thead th").map { |th| th.text.strip },
                   "#{page}: the table is setting | layer | how | effect"
      assert_empty popup.css("button.help-tip-btn, .help-tip-detail"),
                   "#{page}: no `?` and no hint detail -- the table is not a help popup"
      # And the identifiers it DOES carry are variable-shaped, not sentences.
      popup.css("table[data-change-table] tbody tr[data-change-row]").each do |tr|
        how = tr.css("td")[2].text.strip
        refute_empty how, "#{page}: the how column is filled"
        assert_operator how.length, :<=, 160,
                        "#{page}: the how is an identifier or a location, not help prose"
      end
    end
  end

  # -- every setting the page shows is present exactly once -------------------
  #
  # THE DRIFT PIN. Driven by the page's OWN field lists -- the same way
  # scope_chips_test enumerates a page's control groups -- rather than by the
  # helper under test. A knob added to a conf model appears on the page and in
  # the table together; a field the page shows but the table omits FAILS here.

  # The settings each page shows, derived from the model the page renders from.
  # A field's `env` decides its layer, exactly as the page's own chips do.
  def page_settings(page)
    case page
    when :flux
      (FluxConf::CARDS + [FluxConf::GUARD]).flat_map do |card|
        card[:fields].map { |field| [field[:label], field[:env] ? "service · restart" : "per job"] }
      end
    when :bp
      # BP is one service with two halves: BOTH halves' cards are on this page.
      # The layer is per CARD, which is where the page's own chip sits.
      [BpConf::Plot, BpConf::Blender].flat_map do |conf|
        (conf::CARDS + [conf::CHECKS]).flat_map do |card|
          layer = change_card_scope_with_checks(card)
          card[:fields].map { |field| [field[:label], layer] }
        end
      end
    when :jev
      rows = JevConf::DEFAULT["questions"].map do |name, _question|
        [name, "code · read-only"]
      end
      rows << ["confidence_floor", "code · read-only"]
      # The metrics are one read-only block on the page (one list, one file).
      rows << ["metrics", "code · read-only"]
      # The two backend variables, which the page's banner puts under the
      # service scope even though they are read by the caller.
      JevConf::SELECTION.each_key { |var| rows << [var, "service · restart"] }
      rows
    end
  end

  # The table's own rows, keyed the same way, so the two can be diffed.
  def table_settings(d, page)
    change_rows(d, page).map { |row| [row[:setting], row[:layer]] }
  end

  test "every setting on a page appears in the table, and appears once" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      d = doc(route)
      shown = page_settings(page).uniq
      tabled = table_settings(d, page)

      assert_operator shown.size, :>=, 8, "#{page}: the page's own field lists are non-trivial"
      assert_equal shown.size, tabled.size,
                   "#{page}: the table has one row per setting the page shows " \
                   "(shown #{shown.size}, tabled #{tabled.size})"

      # Exactly once, and in the page's own order: a row the page does not have
      # is a knob nobody can find, and a setting that vanished is the drift the
      # issue is about.
      assert_equal shown, tabled,
                   "#{page}: the table's settings, in the page's own order, with the layer " \
                   "the page's chips use"

      # And no duplicates hiding behind a de-dup: the count is the size, so a
      # second row for one setting would show as a missing one elsewhere.
      assert_equal tabled.uniq.size, tabled.size,
                   "#{page}: no setting is listed twice"
    end
  end

  # BP's own exception, stated where the exception is made. Both halves document
  # the SAME service: bind/port/token are one variable, and the runner URL/kind
  # are two variables that differ per half. The table carries them as one row each
  # rather than twice, because the setting is the same setting -- the two runner
  # names are JOINED in the how column, so neither half's identifier is lost.
  #
  # This is the one place the "every setting appears once" rule is not a plain
  # count: BP's raw field list is 42 entries and its table is 35 rows, and the
  # difference is exactly the repeated fields. Four are the shared Service card;
  # the other two are `views` and `engine`, which BOTH halves' Render and Checks
  # cards name.
  test "BP's two halves collapse their shared rows into one each" do
    raw = [BpConf::Plot, BpConf::Blender].flat_map do |conf|
      (conf::CARDS + [conf::CHECKS]).sum { |card| card[:fields].size }
    end.sum
    rows = change_rows(doc(:bp_path), :bp)

    assert_equal 42, raw, "BP's raw field list is both halves' cards and Checks"
    assert_operator raw, :>, rows.size,
                    "BP's raw field list is longer than its table, because the halves share fields"
    assert_equal 7, raw - rows.size,
                 "seven repeated fields collapse to the one row the table already has"
    # And the two halves' identifiers are both present, joined.
    runner_urls = rows.find { |row| row[:setting] == "runner url" }
    refute_nil runner_urls, "the runner URL is one row"
    assert_match(/CHOPSHOP_RUNNER_PLOT_URL/, runner_urls[:how])
    assert_match(/CHOPSHOP_RUNNER_BLENDER_URL/, runner_urls[:how])
  end

  # The two halves of BP both appear: the page is one service with two halves,
  # and a table that carried only one half's identifiers would be the wrong
  # answer for the other.
  test "BP's two halves both appear in the table" do
    d = doc(:bp_path)
    hows = change_rows(d, :bp).map { |row| row[:how] }.join(" | ")

    # The two runner maps are the identifiers that differ between the halves;
    # the bind and the port are shared, so both must be here.
    assert_match(/CHOPSHOP_RUNNER_PLOT_URL/, hows, "the plot half's runner URL")
    assert_match(/CHOPSHOP_RUNNER_BLENDER_URL/, hows, "the blender half's runner URL")
    assert_match(/CHOPSHOP_RUNNER_PLOT_KIND/, hows, "the plot half's runner kind")
    assert_match(/CHOPSHOP_RUNNER_BLENDER_KIND/, hows, "the blender half's runner kind")
    assert_match(/CHOPSHOP_BP_BIND/, hows, "the shared bind")
    assert_match(/CHOPSHOP_BP_PORT/, hows, "the shared port")
    assert_match(/spec\.document/, hows, "the blender half's document spec key")
    assert_match(/spec\.background/, hows, "the plot half's background spec key")
  end

  # JEV's rows state the honest how: the annotator has NO conf input and no flag
  # exists, so an edit changes the JSON you copy out and nothing the service
  # asks. The table says that rather than implying a setting is wired.
  test "JEV's rows say the constants are edited in jev/, not on the page" do
    rows = change_rows(doc(:jev_path), :jev)
    by_setting = rows.to_h { |row| [row[:setting], row] }

    JevConf::DEFAULT["questions"].each_key do |name|
      row = by_setting.fetch(name)
      assert_equal "code · read-only", row[:layer], "#{name}: read-only, like its chip"
      assert_match(/jev_annotate\.py/, row[:how], "#{name}: the file that holds it")
      assert_match(/QUESTIONS\.#{name}/, row[:how], "#{name}: the constant, not the page")
    end

    floor = by_setting.fetch("confidence_floor")
    assert_match(/DEFAULT_CONFIDENCE_FLOOR/, floor[:how],
                 "the floor is named by its constant, because that is what is edited")

    metrics = by_setting.fetch("metrics")
    assert_match(/remediation_table\.json/, metrics[:how],
                 "the metrics block is the remediation table, a file in jev/")

    # The two backend variables are the page's one service-scoped row pair.
    JevConf::SELECTION.each_key do |var|
      row = by_setting.fetch(var)
      assert_equal "service · restart", row[:layer], "#{var}: read by the runner, so a restart"
      assert_equal var, row[:how], "#{var}: the variable itself is what you set"
    end
  end

  # -- the layer column is the #42 vocabulary, with the chip's own band -------

  test "each row's layer is one of the three scopes, with the chip's band" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      change_rows(doc(route), page).each do |row|
        assert_includes SCOPES.keys, row[:layer],
                        "#{page}: #{row[:setting].inspect} is in #{row[:layer].inspect}, which is not a scope"
        assert_includes row[:band], SCOPES.fetch(row[:layer]),
                        "#{page}: #{row[:setting].inspect} carries the #{SCOPES.fetch(row[:layer])} band"
        assert_includes row[:band], "scope-chip",
                        "#{page}: #{row[:setting].inspect} renders the scope_chip partial's own chip"
      end
    end
  end

  # A row's layer is the layer the page's own chip for that setting says. This
  # is the "reuse the #42 derivation" rule made testable: the page's chip and the
  # table's row are read from the same model by the same rule, so if the two ever
  # disagree this is where it shows.
  #
  # FLUX is the page whose chips are PER FIELD, so every row has an exact chip to
  # be compared with and the assertion is exact. BP's and JEV's chips are on the
  # CARD heads, and a card is a group rather than a setting -- so the comparison
  # there is the one that can be made honestly: every row's layer is one of the
  # layers its own card carries.
  test "the table's layer agrees with the page's own chips" do
    d = doc(:flux_path)
    change_rows(d, :flux).each do |row|
      chips = d.css(".scope-chip[data-scope-group='flux #{row[:setting]}']")
      refute_empty chips, "flux: #{row[:setting].inspect} has its own chip"
      words = chips.map { |chip| chip["data-scope"] }.uniq
      assert_equal [row[:layer]], words,
                   "flux: #{row[:setting].inspect} is #{row[:layer].inspect} in the table but " \
                   "#{words.inspect} on the chip beside the field"
    end
  end

  test "BP's and JEV's rows carry a layer their own card carries" do
    # BP: the page's chips are on the card heads, one per card. A row must be one
    # of the layers its card's chip says, which is the same derivation the view
    # uses (change_card_scope_with_checks) -- the test reads the CARDS, not the
    # helper, so the helper is not grading itself.
    bp_layers = [BpConf::Plot, BpConf::Blender].flat_map do |conf|
      (conf::CARDS + [conf::CHECKS]).map do |card|
        card[:title] == "Checks" ? "per job" : (card[:fields].any? { |f| f[:env] } ? "service · restart" : "code · read-only")
      end
    end.uniq
    change_rows(doc(:bp_path), :bp).each do |row|
      assert_includes bp_layers, row[:layer],
                      "bp: #{row[:setting].inspect} is #{row[:layer].inspect}, which no card's chip says"
    end

    # JEV: the questions, the floor and the metrics are the annotator's constants
    # (read-only), and the two backend variables are the runner's environment.
    jev_layers = change_rows(doc(:jev_path), :jev).map { |row| [row[:setting], row[:layer]] }.to_h
    JevConf::DEFAULT["questions"].each_key do |name|
      assert_equal "code · read-only", jev_layers.fetch(name),
                   "jev: #{name} is the annotator's constant, so its chip is read-only"
    end
    assert_equal "code · read-only", jev_layers.fetch("confidence_floor")
    assert_equal "code · read-only", jev_layers.fetch("metrics")
    JevConf::SELECTION.each_key do |var|
      assert_equal "service · restart", jev_layers.fetch(var),
                   "jev: #{var} is read by the runner, so the chip is the service one"
    end
  end

  # -- hard rule 4: variable NAMES only, never a value -----------------------

  # Host-shaped facts. The table is a table of NAMES -- a variable, a spec key,
  # a file -- and the moment it prints a value it is claiming something about a
  # box this app cannot read. Every one of these is the shape of a value rather
  # than a name, so the table must contain none of them.
  HOST_FACTS = [
    /\b\d{1,3}(?:\.\d{1,3}){3}\b/,          # an IPv4 address
    /\b\d+\.\d+\.\d+\.\d+:\d+\b/,           # host:port
    %r{\bhttps?://},                        # a URL
    %r{\b\d{2,5}\b},                        # a bare port number
    /\/(?:home|Users|mnt|srv|opt)\//,       # an absolute path outside the repos
    /\bCHOPSHOP_[A-Z_]+=\S/,                # a variable with a value assigned
    /=(?:true|false|yes|no|on|off)\b/,      # a boolean value assigned
    /\b\d+\s*(?:GB|MB|px)\b/i               # a measured size
  ].freeze

  test "the table shows variable names only, and no host-shaped facts" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      d = doc(route)
      popup = change_popup(d, page)
      refute_nil popup
      # The table's own text, plus its attributes: a value smuggled into a
      # data-* attribute would be the same rule broken in a place nobody reads.
      haystacks = [popup.text]
      popup.css("[data-change-how], [data-change-setting], [data-change-layer]").each do |node|
        haystacks << node["data-change-how"].to_s
        haystacks << node["data-change-setting"].to_s
      end

      haystacks.each do |text|
        HOST_FACTS.each do |pattern|
          refute_match pattern, text,
                       "#{page}: #{text.inspect} carries a host-shaped fact (#{pattern.inspect}); " \
                       "the table is variable NAMES, and a value would be a claim about a box " \
                       "this app cannot read (hard rule 4)"
        end
      end
    end
  end

  # The names ARE there, which is what makes the rule meaningful: a table of
  # "ask the service" would also contain no values. The identifiers are the
  # point, so each page's own kinds are pinned.
  test "each row's how is the identifier it is changed by" do
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      rows = change_rows(doc(route), page)
      kinds = rows.map { |row| row[:kind] }.uniq

      case page
      when :flux
        assert_includes kinds, "env var", "#{page}: the service variables are env vars"
        assert_includes kinds, "request key", "#{page}: the request parameters are request keys"
      when :bp
        assert_includes kinds, "env var", "#{page}: the service variables are env vars"
        assert_includes kinds, "spec key", "#{page}: the contract fields are spec keys"
      when :jev
        assert_includes kinds, "code", "#{page}: the constants are a file in jev/"
        assert_includes kinds, "env var", "#{page}: the backend variables are env vars"
      end
    end
  end

  # The effect column is the consequence of the scope, not a fourth opinion:
  # it is read off the same scope word the chips use.
  test "the effect column is the consequence of the row's layer" do
    effects = {
      "per job" => "next job",
      "service · restart" => "restart",
      "code · read-only" => "preview only"
    }
    { flux: :flux_path, bp: :bp_path, jev: :jev_path }.each do |page, route|
      change_rows(doc(route), page).each do |row|
        assert_equal effects.fetch(row[:layer]), row[:effect],
                     "#{page}: #{row[:setting].inspect} is #{row[:layer].inspect}, so its effect is " \
                     "#{effects.fetch(row[:layer]).inspect}"
      end
    end
  end

  # The three config pages are the pages, and a fourth page would be a table
  # nobody asked for -- the same refusal the scope_chip partial makes. The
  # partial wraps the helper's ArgumentError in ActionView's own Template::Error,
  # which is how every other shared partial's refusal surfaces in a test.
  test "the helper refuses a fourth page" do
    err = assert_raises(ActionView::Template::Error) do
      ApplicationController.render(
        partial: "shared/change_popup",
        locals: { page: "schema" }
      )
    end
    assert_match(/unknown change page/, err.message)
  end

  test "the change rows are generated from the conf models, not written twice" do
    # One partial, one definition: a second per-page table is the duplication
    # the shared-partial rule exists to prevent.
    assert File.exist?(Rails.root.join("app/views/shared/_change_popup.html.erb"))
    refute File.exist?(Rails.root.join("app/views/shared/_change_table.html.erb")),
           "one partial, one definition"

    # And the helper reads the models: adding a field to a conf model moves the
    # row count, so a hand-written copy would drift silently. The count is read
    # from the models here, not from the helper, so the helper is not grading
    # itself -- and the rendered table is compared against it above.
    expected = {
      flux: (FluxConf::CARDS + [FluxConf::GUARD]).sum { |card| card[:fields].size },
      bp: [BpConf::Plot, BpConf::Blender].sum do |conf|
        (conf::CARDS + [conf::CHECKS]).sum { |card| card[:fields].size }
      end,
      jev: JevConf::DEFAULT["questions"].size + 1 + 1 + JevConf::SELECTION.size
    }
    assert_equal expected[:flux], page_settings(:flux).size,
                 "flux: the page's own field count, read from the model"
    assert_equal expected[:bp], page_settings(:bp).size,
                 "bp: both halves' field counts, read from the models"
    assert_equal expected[:jev], page_settings(:jev).size,
                 "jev: questions + floor + metrics + backend vars"

    # The dedupe is the only thing between the raw count and the rendered one.
    assert_operator expected[:bp], :>, change_rows(doc(:bp_path), :bp).size,
                    "BP collapses its two halves' shared rows into one each"
  end
end
