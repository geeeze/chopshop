require "test_helper"

# The three pages migrated to the hint registry (HelpTips, #41): JEV, FLUX and
# the JSON page. Two things are pinned:
#
#   the `?` renders and its popup is in the page payload, so a hint cannot be
#   registered and then silently not shown;
#   no inline `.hint` on these pages is longer than one line -- the acceptance
#   rule. The long account moved into the registry, it was not just shortened.
class HelpTipPagesTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  # The one-line ceiling, in collapsed characters. The `.hint` is a 0.75rem
  # column roughly 45-50 characters wide, so 60 is the longest sentence that
  # reads as one line.
  ONE_LINE = 60

  PAGES = {
    "jev" => :jev_path,
    "flux" => :flux_path,
    "json" => :json_path
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

  test "each migrated page renders its registered hints with their details" do
    PAGES.each do |prefix, route|
      d = doc(route)
      keys = HelpTips.keys.select { |k| k.start_with?("#{prefix}.") }
      refute_empty keys, "#{prefix} has no registry keys"

      keys.each do |key|
        id = "help-tip-#{key.tr('.', '-')}"
        button = d.at_css("button.help-tip-btn[data-popup='#{id}']")
        refute_nil button, "#{prefix}: the ? for #{key} renders"

        popup = d.at_css("##{id}")
        refute_nil popup, "#{prefix}: #{key}'s popup is in the page payload"
        assert popup.text.include?(HelpTips.fetch(key)[:line]),
               "#{prefix}: #{key}'s line is shown inline"
      end
    end
  end

  test "no inline hint on a migrated page is longer than one line" do
    PAGES.each do |prefix, route|
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

  test "each migrated page carries at least one registered hint" do
    PAGES.each do |prefix, route|
      d = doc(route)
      assert_operator d.css("button.help-tip-btn").size, :>=, 1,
                      "#{prefix} renders no help_tip at all"
    end
  end
end
