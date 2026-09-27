require "test_helper"

# The central background orb moved from dead centre to top centre of the body.
#
# It is the site's one piece of ambient colour. At top:50%/left:50% it landed
# behind the MIDDLE of every long table -- behind the rows being read -- rather
# than behind the head, where it reads as a light source for the page. The user
# named Jobs, Run Job, JSON and Jev; because the orb is a single global element
# created by aether.js (one `div.bg-gradient-orb.orb-3`, prepended to <body>),
# one CSS position covers all four and cannot drift between them.
#
# Measured in headless Chromium at 1500x913 (15px scrollbar):
#   top: 91.3px  = 10vh        centre y = 10.0% down (was 50%)
#   centre x off by 0.00px of the 1485px LAYOUT viewport
class CentralOrbPositionTest < ActionDispatch::IntegrationTest
  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "the central orb is anchored top centre, not dead centre" do
    css = css_without_comments
    orb = css[/\.orb-3 \{[^}]*\}/m]
    refute_nil orb, ".orb-3 must exist"

    assert_match(/top: 10vh/, orb,
      "10vh: near the head, not mid-table. The value is verified as 10.0% down")
    refute_match(/top: 50%/, orb, "the old dead-centre position")
    assert_match(/left: 50%/, orb, "still horizontally centred")
  end

  test "it is one global element, so the four pages cannot disagree" do
    js = Rails.root.join("app/javascript/aether.js").read
    block = js[/function ensureBackground\(\).*?\n  \}/m]
    refute_nil block
    # Exactly one of each orb, created once and prepended to <body>.
    assert_match(/\['orb-1', 'orb-2', 'orb-3'\]/, block)
    assert_equal 1, js.scan(/orb\.className = 'bg-gradient-orb ' \+ cls/).size

    # And no view renders its own central orb that could be positioned per page.
    Dir[Rails.root.join("app/views/**/*.erb")].each do |f|
      src = File.read(f)
      refute_match(/class="[^"]*\borb-3\b/, src,
                   "#{File.basename(f)} must not render its own .orb-3")
    end
  end

  test "only top can move it: float-fast owns transform" do
    css = css_without_comments
    kf = css[/@keyframes float-fast \{.*?\}/m]
    refute_nil kf
    assert_match(/transform:/, kf,
      "the keyframes animate transform, so a base `transform` on .orb-3 would " \
      "be overridden on the first frame -- only top/left are real levers")

    # It is fixed-positioned and behind the content, or "top of the body" would
    # mean nothing and it would paint over the tables.
    base = css[/\.bg-gradient-orb \{[^}]*\}/m]
    assert_match(/position: fixed/, base)
    assert_match(/z-index: 0/, base)
    assert_match(/pointer-events: none/, base)
  end

  test "the login page's pinned orb is not disturbed" do
    login = File.read(Rails.root.join("app/views/application/login.html.erb"))
    # The login page anchors this SAME orb behind its scissor with inline
    # styles, which outrank the stylesheet -- so moving the global position
    # must not drag the login hero with it.
    assert_match(/function pinCentralOrb/, login)
    assert_match(/orb\.classList\.add\('orb-pinned'\)/, login)
    assert_match(/orb\.style\.top = /, login,
      "an inline top is what protects the login hero from the global change")
  end
end
