require "test_helper"

# The About page is the high-level overview of the -studio and the stack it
# sits on (-svg / -jev / -flux). Two things are easy to lose and both are pinned
# here: the nav link has a real name instead of the "???" placeholder it shipped
# with, and the Flux section names the generation layer the way the Jev card
# names the decision one.
class AboutPageTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def fetch(path)
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    Nokogiri::HTML(response.body)
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  def about
    @about ||= fetch(about_path)
  end

  test "the nav names the About link, not the ??? placeholder" do
    links = about.css("nav.topbar .nav-links a").map { |a| [a.text.strip, a["href"]] }
    labels = links.map(&:first)
    assert_includes labels, "About"
    refute_includes labels, "???", "the placeholder label is gone"
    assert_equal about_path, links.assoc("About").last
  end

  test "the About page carries a Flux section shaped like the Jev one" do
    titles = about.css(".grid-2 .card h3").map { |h| h.text.strip }
    assert_includes titles, "Jev · System One"
    assert_includes titles, "Flux · generation service"

    # The naming shape is "<layer> · <what it is>", not a bare product name.
    jev = titles.find { |t| t.start_with?("Jev") }
    flux = titles.find { |t| t.start_with?("Flux") }
    assert_match(/\A\w+ · \w+/, jev)
    assert_match(/\A\w+ · \w+/, flux)
  end

  test "the Flux section names the stack repo and the licence split" do
    body = about.text.gsub(/\s+/, " ")
    assert_includes body, "chopshop-flux"
    assert_includes body, "klein-4b"
    assert_includes body, "klein-9b"
    assert_includes body, "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1"
    assert_includes body, "chopshop-svg"
    assert_includes body, "chopshop-jev"
  end

  test "the FLUX help targets still resolve to rendered help blocks" do
    targets = fetch(flux_path).css(".help-btn[data-help-target]").map { |b| b["data-help-target"] }
    assert_includes targets, FluxConf::CARDS.find { |c| c[:title] == "Service" }[:help]
    assert_includes targets, FluxConf::CHECKS[:help]

    flux = fetch(flux_path)
    [FluxConf::CARDS.find { |c| c[:title] == "Service" }[:help], FluxConf::CHECKS[:help]].each do |id|
      refute_nil flux.at_css("##{id}"), "##{id} must exist as rendered help"
      assert flux.at_css("##{id}").css("dt").any?, "##{id} must carry help entries"
    end
  end
end
