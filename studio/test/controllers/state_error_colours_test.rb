require "test_helper"

# The semantic state tokens: `error` is urgent (#6).
#
# Option A (the operator's pick): `error` and `fail` both take the DANGER red,
# `warn` keeps the AMBER. Before the pick, `--state-error-*` was byte-equivalent
# to the warn band, so a job that ERRORED read as "warning" and the vocabulary
# had two words for one colour.
#
# The contracts pinned here:
#
#   * `--state-error-fg` resolves to the DANGER colour, not the warning colour.
#   * `--band-warn-fg` still resolves to the AMBER colour.
#   * `error` and `warn` resolve to DIFFERENT colours (error != warn).
#   * `error` and `fail` resolve to the SAME colour (both urgent/red).
#   * the `.status-error` / `.badge.error` rule reads the `--state-error-*`
#     tokens, so every pill, badge and chart swatch naming the class follows.
#
# The colours are RESOLVED through var() rather than matched textually, so a
# token that aliases the wrong band is caught even when its own spelling looks
# plausible.
class StateErrorColoursTest < ActionDispatch::IntegrationTest
  CSS = Rails.root.join("app/assets/stylesheets/application.css")
             .read(encoding: "UTF-8").freeze

  # The :root block, comments stripped, as a token => value map.
  def tokens
    root = CSS[/:root\s*\{(.*?)\n\}/m, 1]
    refute_nil root, ":root must declare the semantic tokens"
    root.gsub(%r{/\*.*?\*/}m, "")
        .scan(/(--[\w-]+)\s*:\s*([^;]+);/)
        .to_h
  end

  # Follow var() references to a literal colour.
  def resolve(name, depth = 0)
    assert_operator depth, :<, 20, "token #{name} is a var() cycle"
    value = tokens.fetch(name, nil)
    refute_nil value, "token #{name} must be declared"
    if (ref = value[/var\((--[\w-]+)/, 1])
      resolve(ref, depth + 1)
    else
      value.strip
    end
  end

  test "error takes the danger red and warn stays amber" do
    danger  = resolve("--danger")
    warning = resolve("--warning")
    assert_equal "#ef4444", danger, "--danger is the red band"
    assert_equal "#f59e0b", warning, "--warning is the amber band"

    assert_equal danger, resolve("--state-error-fg"),
                 "error must be the danger red, not the warn amber (#6)"
    assert_equal danger, resolve("--band-fail-fg"), "fail is the danger red too"
    assert_equal warning, resolve("--band-warn-fg"), "warn keeps the amber"
  end

  test "error and warn are different colours; error and fail are the same" do
    refute_equal resolve("--band-warn-fg"), resolve("--state-error-fg"),
                 "error must not read as a warning (#6)"
    assert_equal resolve("--band-fail-fg"), resolve("--state-error-fg"),
                 "error and fail both read urgent"
  end

  test "the error pill and the graph ring follow the error token" do
    pill = CSS[/\.status-error,\s+\.badge\.error\s+\{[^}]*\}/]
    refute_nil pill, "the .status-error / .badge.error rule must exist"
    assert_match(/background: var\(--state-error-bg, rgba\(239, 68, 68, 0\.15\)\)/,
                 pill)
    assert_match(/color: var\(--state-error-fg, var\(--danger\)\)/, pill)

    ring = CSS[/\.g-node\[data-state="error"\]\s+\.g-halo\s+\{[^}]*\}/]
    refute_nil ring, "the graph must colour the error ring"
    assert_match(/stroke: var\(--state-error-fg\)/, ring)
  end
end
