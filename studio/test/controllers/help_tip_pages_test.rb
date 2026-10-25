require "test_helper"

# Every page that carries hints, and the hint registry (HelpTips, #41) they
# draw from. Three things are pinned:
#
#   a page renders at least one `?` -- a hint cannot be registered and then
#   silently not shown;
#   every `?` a page renders has its popup in the page payload, and the popup
#   carries the registry's own `line`, so the popup cannot drift from the hint
#   it explains;
#   no inline `.hint` on any page is longer than one line -- the acceptance
#   rule. The long account moved into the registry, it was not just shortened.
class HelpTipPagesTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The one-line ceiling, in collapsed characters. The `.hint` is a 0.75rem
  # column roughly 45-50 characters wide, so 60 is the longest sentence that
  # reads as one line.
  ONE_LINE = 60

  # page name -> [route helper, the registry key prefix the page's hints use].
  # Run Job's keys are `runjob.*` because the page composes a job.
  PAGES = {
    "jev" => [:jev_path, "jev."],
    "flux" => [:flux_path, "flux."],
    "json" => [:json_path, "json."],
    "bp" => [:bp_path, "bp."],
    "runjob" => [:new_job_path, "runjob."]
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

  # The key a `?` names, read back off its popup id.
  def key_for(button)
    button["data-popup"].sub(/\Ahelp-tip-/, "").tr("-", ".")
  end

  test "each page carries registry keys and renders at least one help_tip" do
    PAGES.each do |prefix, (route, key_prefix)|
      d = doc(route)
      refute_empty HelpTips.keys.select { |k| k.start_with?(key_prefix) },
                   "#{prefix} has no registry keys"
      assert_operator d.css("button.help-tip-btn").size, :>=, 1,
                      "#{prefix} renders no help_tip at all"
    end
  end

  test "every help_tip a page renders has its popup, with the registry's line" do
    PAGES.each do |prefix, (route, _)|
      d = doc(route)
      d.css("button.help-tip-btn").each do |button|
        key = key_for(button)
        id = button["data-popup"]
        popup = d.at_css("##{id}")
        refute_nil popup, "#{prefix}: #{key}'s popup is in the page payload"
        assert popup.text.include?(HelpTips.fetch(key)[:line]),
               "#{prefix}: #{key}'s line is shown in its popup"
      end
    end
  end

  test "no inline hint on any page is longer than one line" do
    PAGES.each do |prefix, (route, _)|
      d = doc(route)
      d.css(".hint").each do |hint|
        # A hint that IS a help_tip carries the registry's one-line `line`; the
        # long detail is in its popup, which is a child of this div, so it is
        # skipped here -- the registry test caps the line.
        next if hint.at_css("button.help-tip-btn")

        text = hint.text.gsub(/\s+/, " ").strip
        assert_operator text.length, :<=, ONE_LINE,
                        "#{prefix}: an inline hint runs #{text.length} chars -- move " \
                        "it into HelpTips: #{text.inspect}"
      end
    end
  end
end
