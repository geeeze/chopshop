require "test_helper"

# The ONE hint registry (HelpTips, app/lib/help_tips.rb) is the only place a
# long hint lives. Two directions have to hold:
#
#   every `help_tip("key")` call in a view names a key that exists there;
#   every key there is used by some view -- no orphans.
#
# A key used in a view but missing there renders NOTHING (help_tip returns an
# empty string for an unknown key), so the failure is a silently blank hint. A
# key present but unused is a second copy no reader will ever see. Both are
# drift, so both are pinned.
class HelpTipsTest < ActiveSupport::TestCase
  VIEWS = Dir[Rails.root.join("app/views/**/*.erb")].freeze

  # Every literal help_tip("key") call in a view.
  def literal_keys
    VIEWS.flat_map do |path|
      File.read(path).scan(/help_tip\(\s*"([^"]+)"/).flatten
    end
  end

  # Keys a view reaches without a literal: _flux_fields renders
  # help_tip(f[:help_key]) for whichever FluxConf field carries one.
  def dynamic_keys
    (FluxConf::CARDS.flat_map { |c| c[:fields] } + FluxConf::GUARD[:fields])
      .filter_map { |f| f[:help_key] }
  end

  def used_keys
    (literal_keys + dynamic_keys).uniq
  end

  test "every help_tip key used in a view exists in the registry" do
    missing = used_keys - HelpTips.keys
    assert_empty missing,
                 "used by a view but absent from HelpTips: #{missing.inspect}"
  end

  test "every registry key is used by a view (no orphans)" do
    orphans = HelpTips.keys - used_keys
    assert_empty orphans, "HelpTips keys used nowhere: #{orphans.inspect}"
  end

  test "every entry carries a one-line line and a detail" do
    HelpTips::REGISTRY.each do |key, tip|
      assert tip[:line].present?, "#{key} has no line"
      assert tip[:detail].present?, "#{key} has no detail"
      assert_operator tip[:line].length, :<=, 60,
                      "#{key}'s line is #{tip[:line].length} chars -- the inline " \
                      "sentence must be one line"
    end
  end

  test "help_tip renders the ? and the standard popup for a known key" do
    doc = Nokogiri::HTML(ApplicationController.render(inline: '<%= help_tip("jev.metrics") %>'))

    button = doc.at_css("button.help-tip-btn")
    refute_nil button, "the ? control renders"
    assert_equal "?", button.text.strip
    assert_equal "jev.metrics", button["data-popup"].sub(/\Ahelp-tip-/, "").tr("-", ".")

    popup = doc.at_css("#help-tip-jev-metrics")
    refute_nil popup, "the button names an existing popup"
    assert_includes popup["class"].split, "popup"
    assert_equal 1, popup.css("[data-popup-close]").size,
                 "exactly one close, the app's standard"
    assert_equal 1, popup.css(".popup-head [data-popup-close]").size,
                 "and it lives in the head"
    refute_nil popup.at_css(".popup-panel > .popup-head"), "the standard head"
    refute_nil popup.at_css(".popup-panel > .popup-body"), "the standard body"
    assert_includes popup.at_css(".popup-body").text, "remediation_table.json"
  end

  test "help_tip renders nothing for an unknown key" do
    assert_equal "", ApplicationController.render(inline: '<%= help_tip("no.such.key") %>')
  end
end
