require "test_helper"

# The JSON page's four cards each carry a "?" that opens that card's help block.
# An audit found one stray: help-print documented `sweep_max_candidates` — a
# Sweep concern under a key the builder no longer emits (the Sweep card's field
# is `max_candidates`, already documented in help-sweep). So the rule is:
# a card's help documents that card's fields, and nothing else.
class JsonHelpPlacementTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def page
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get json_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    response.body
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The field labels of a card, as the help block names them.
  #
  # Two normalisations, both because the raw label text is not the key:
  #   "colour palette — pick"  -> "colour palette"   (an em-dash suffix)
  #   "ink_limit_percent (TAC)" -> "ink_limit_percent" (a parenthetical)
  # Checkbox OPTION labels are skipped: bw/poster/photo/cutout/stacked are the
  # options of one documented key (presets, hierarchical), not separate fields.
  def card_field_labels(doc, heading)
    card = doc.css(".card").find { |c| c.at_css("h3")&.text&.strip == heading }
    refute_nil card, "the #{heading} card must exist"
    card.css("label").reject { |l| l["class"].to_s.include?("check") }
        .map { |l| l.text.strip.split(/\s+—\s+|\s*\(/).first }
        .reject(&:empty?).uniq - VIEW_LABELS
  end

  # Labels that are a VIEW of another field, not a spec key in their own right.
  # Empty: it held "current selected colours", which the help documented as
  # "colour palette" because the card's own palette control was labelled
  # "colour palette — pick". That label belonged to the row of 19 predefined
  # spot colours, which is gone -- the strip IS the palette now and is labelled
  # as one, and the help entry is named after it.
  VIEW_LABELS = [].freeze

  def help_entries(doc, help_id)
    block = doc.at_css("##{help_id}")
    refute_nil block, "##{help_id} must exist"
    block.css("dt").map { |d| d.text.strip }
  end

  test "every card documents all of its own fields" do
    doc = Nokogiri::HTML(page)

    {
      "Job Spec" => "help-job-spec",
      "Prep" => "help-prep",
      "Print & tolerances" => "help-print",
      "Sweep" => "help-sweep",
      "Colour Spec" => "help-colour-spec"
    }.each do |heading, help_id|
      fields = card_field_labels(doc, heading)
      entries = help_entries(doc, help_id)

      fields.each do |f|
        next if f == "Artwork" # not a spec field
        assert entries.any? { |e| e.start_with?(f.split(" (").first) },
          "#{heading} is missing help for its own field #{f.inspect} " \
          "(##{help_id} documents #{entries.inspect})"
      end
    end
  end

  test "no card documents a field that is not its own" do
    doc = Nokogiri::HTML(page)

    {
      "Job Spec" => "help-job-spec",
      "Prep" => "help-prep",
      "Print & tolerances" => "help-print",
      "Sweep" => "help-sweep",
      "Colour Spec" => "help-colour-spec"
    }.each do |heading, help_id|
      fields = card_field_labels(doc, heading)
      entries = help_entries(doc, help_id)

      entries.each do |e|
        # "colour palette" is the card's own <label> for the palette control.
        assert fields.any? { |f| e.start_with?(f) },
          "#{help_id} documents #{e.inspect}, which is not a field of the " \
          "#{heading} card (its fields are #{fields.inspect})"
      end
    end
  end

  test "the stale sweep_max_candidates entry is gone from the Print help" do
    html = page
    doc = Nokogiri::HTML(html)

    refute_includes help_entries(doc, "help-print").join(" "), "sweep_max_candidates",
      "it is a Sweep concern under a key the builder no longer emits -- the " \
      "Sweep card's field is max_candidates, documented in help-sweep"
    assert_includes help_entries(doc, "help-sweep").join(" "), "max_candidates",
      "the real cap stays documented where the field lives"
  end

  test "every card has a help button pointing at its own help block" do
    doc = Nokogiri::HTML(page)

    doc.css(".card .card-head").each do |head|
      title = head.at_css("h3").text.strip
      btn = head.at_css(".help-btn")
      refute_nil btn, "#{title} must have a ? button"
      target = btn["data-help-target"]
      refute_nil doc.at_css("##{target}"),
        "#{title}'s ? button points at ##{target}, which does not exist"
    end
  end
end
