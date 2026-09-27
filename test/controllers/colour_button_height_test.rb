require "test_helper"

# The Colours button and the scissor orb share row 3 of the Colour Spec grid, so
# they are the same HEIGHT and their boxes line up.
class ColourButtonHeightTest < ActionDispatch::IntegrationTest
  setup do
    @css = File.read(Rails.root.join("app/assets/stylesheets/application.css"))
  end

  def rule(sel)
    @css[/#{Regexp.escape(sel)}\s*\{([^}]*)\}/m, 1]
  end

  test "the cell centres its contents, it does not baseline them" do
    r = rule(".colour-set-lib-cell")
    refute_nil r, ".colour-set-lib-cell has no rule"
    # `baseline` aligns TEXT baselines, not boxes. A 28px button and a 48px orb
    # then have their centres 10px apart, which reads as the button hovering.
    assert_match(/align-items:\s*center/, r)
    refute_match(/align-items:\s*baseline/, r,
      "baseline alignment is exactly what put the button 10px high")
  end

  test "the button is the orb's height" do
    # .btn-scissor is 48px; the button was on btn-sm and measured 28px, a 20px
    # shortfall that nothing in the sheet ever asked it to close.
    r = rule(".colour-set-lib-cell .btn")
    refute_nil r, "the Colours button is not sized"
    assert_match(/height:\s*48px/, r, "the same height as the scissor orb")
  end

  test "it is filled opaque grey, not 3% white" do
    r = rule(".colour-set-lib-cell .btn")
    # btn-secondary's own background is rgba(255,255,255,0.03). Against the
    # panel that is not grey, it is transparent -- and a control that reads as
    # transparent reads as absent. The same opaque grey as the other quiet
    # buttons.
    assert_match(/background:\s*var\(--btn-plain\)/, r)
    refute_match(/background:[^;]*0\.03/, r, "not the 3%-white surface again")
    # And it must not go back to that on hover either.
    hover = rule(".colour-set-lib-cell .btn:hover")
    refute_nil hover
    assert_match(/background:\s*var\(--btn-plain\)/, hover,
      "hover must not wash the fill out")
  end

  test "the button is still the same control the map opens" do
    view = File.read(Rails.root.join("app/views/pages/schema.html.erb"))
    assert_includes view, %q{id="pal_presets_btn"}
    cell = view[/<div class="colour-set-lib-cell">(.*?)<\/div>/m, 1]
    refute_nil cell
    assert_includes cell, "pal_presets_btn"
  end
end
