require "test_helper"

# The Colours button is the Colour Spec card's single add-colour control now
# that the hex+orb picker is gone. It is a full .btn — the same height as the
# page-head Run Job button — not btn-sm, and not the orb's 48px (the orb is
# gone with the picker).
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
    assert_match(/align-items:\s*center/, r)
    refute_match(/align-items:\s*baseline/, r,
      "baseline alignment is exactly what put the button 10px high")
  end

  test "the button is a full .btn, not btn-sm and not the orb's 48px" do
    r = rule(".colour-set-lib-cell .btn")
    refute_nil r, "the Colours button is not sized"
    refute_match(/height:\s*48px/, r, "the 48px height matched the orb, which is gone")
    refute_match(/height:/, r,
      "no height override — the button inherits the full .btn padding, " \
      "matching the Run Job button")
  end

  test "it is filled opaque grey, not 3% white" do
    r = rule(".colour-set-lib-cell .btn")
    # btn-secondary's own background is rgba(255,255,255,0.03). Against the
    # panel that is not grey, it is transparent -- and a control that reads as
    # transparent reads as absent. The same opaque grey as the other quiet
    # buttons.
    assert_match(/background:\s*var\(--btn-plain\)/, r)
    refute_match(/background:[^;]*0\.03/, r, "not the 3%-white surface again")
    # And on hover it must stay opaque — a lighter opaque grey, not the
    # 6%-white --surface-hover that would wash the solid fill out.
    hover = rule(".colour-set-lib-cell .btn:hover")
    refute_nil hover
    assert_match(/background:\s*var\(--btn-plain-hover\)/, hover,
      "hover brightens the fill, it does not wash it out")
    assert_match(/transform:\s*translateY\(-1px\)/, hover,
      "the lift is the hover feedback the button was missing beside the orb")
  end

  test "the button is a full-size .btn in the markup, not btn-sm" do
    view = File.read(Rails.root.join("app/views/pages/schema.html.erb"))
    assert_includes view, %q{id="pal_presets_btn"}
    assert_match(/class="btn btn-secondary" id="pal_presets_btn"/, view,
      "full .btn, same height as the Run Job button — btn-sm is gone")
    cell = view[/<div class="colour-set-lib-cell">(.*?)<\/div>/m, 1]
    refute_nil cell
    assert_includes cell, "pal_presets_btn"
  end
end
