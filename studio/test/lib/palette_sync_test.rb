require "test_helper"

# DRIFT PIN for config/palettes.json.
#
# `config/palettes.json` is a checked-in COPY of chopshop-svg's
# `scripts/palettes.json`: the pipeline owns those colours, and the studio reads
# its own copy so the JSON page renders without reaching into another checkout
# at request time. `bin/sync-palettes --check` can report the two being out of
# sync — and nothing ran it. A hand-edit to the studio's copy (or a palette
# change in the pipeline that was never copied) was therefore invisible: the
# page rendered, the swatches were simply no longer the pipeline's.
#
# THE COMPARISON IS BYTE-IDENTITY, deliberately, and for the same reason
# `bin/sync-palettes` uses it: the copy is not an interpretation, it is a copy.
# `File.binread` on both sides, so a re-formatted or re-ordered file is drift
# even if every colour still parses the same.
#
# THE PATH IS RESOLVED THE SAME WAY bin/sync-palettes RESOLVES IT:
# `CHOPSHOP_SVG_DIR` if set, else the sibling checkout at ../chopshop-svg. The
# test therefore checks exactly what the sync script would copy — not a
# near-enough guess at it.
#
# SKIP, NOT FAIL, WHEN THE SOURCE IS ABSENT: a machine without the sibling
# checkout has nothing to compare against, which is a missing environment, not a
# disagreement — the same rule flux_repo_parity_test applies. A source that is
# PRESENT and DIFFERS is a failure, and that is the whole point of the test.
class PaletteSyncTest < ActiveSupport::TestCase
  TARGET = Rails.root.join("config", "palettes.json").freeze

  # Resolved the way bin/sync-palettes resolves it (its `source_root`):
  # CHOPSHOP_SVG_DIR if set, else the sibling checkout relative to this repo.
  def source
    root = ENV["CHOPSHOP_SVG_DIR"].to_s.strip
    root = File.expand_path("../chopshop-svg", Rails.root) if root.empty?
    Pathname.new(root).join("scripts", "palettes.json")
  end

  test "config/palettes.json is byte-identical to chopshop-svg's scripts/palettes.json" do
    assert TARGET.file?, "#{TARGET} must exist: the JSON page reads it"

    src = source
    unless src.file?
      skip "no chopshop-svg palette library at #{src} — set CHOPSHOP_SVG_DIR to pin the sync"
    end

    assert_equal File.binread(src), File.binread(TARGET),
      "config/palettes.json has drifted from #{src}. The pipeline owns these " \
      "colours and this copy is not edited by hand: run bin/sync-palettes"
  end
end
