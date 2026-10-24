# WHERE THE JEV COMPONENT IS. One resolver, used by the app and the tests.
#
# Several things read jev's own files: the remediation table (JevConf), and the
# tests that pin the studio's claims against the annotator's real source.
#
# The path used to be hardcoded as `../chopshop-jev`, a SIBLING CHECKOUT. That
# was true while jev was its own repository beside studio; after the
# consolidation it is `jev/` INSIDE the same repository, one level up from
# studio. Both work here, in one place, because a second hardcoded sibling path
# is how this breaks again the next time a component moves -- and it already
# did: a stock monorepo checkout could not read the remediation table, so the
# jev page rendered an empty <textarea> and the popup tests failed on
# `unexpected end of input`.
#
# Order:
#   1. JEV_REPO env   -- an explicit checkout wins (CI, or a contributor layout)
#   2. ../jev         -- the monorepo (consolidated 2026-10-22)
#   3. ../chopshop-jev -- a legacy sibling checkout of the old split repo
#
# `ROOT` is nil when none of them exist. Callers must handle nil rather than
# raise: the jev add-on is optional, and an unconfigured studio answers 503 with
# its reason instead of failing to boot.
require "pathname"

module JevPaths
  # The file that proves a directory is the jev component, not a lookalike.
  MARKER = File.join("scripts", "jev_annotate.py").freeze

  CANDIDATES = %w[jev chopshop-jev].freeze

  def self.candidates
    explicit = ENV["JEV_REPO"].to_s.strip
    return [Pathname.new(explicit)] unless explicit.empty?

    CANDIDATES.map { |name| Rails.root.parent.join(name) }
  end

  def self.root
    return @root if defined?(@root)

    @root = candidates.find { |dir| dir.join(MARKER).exist? }
  end

  # Reset between tests that set JEV_REPO.
  def self.reset!
    remove_instance_variable(:@root) if defined?(@root)
  end

  def self.annotator
    root&.join("scripts", "jev_annotate.py")
  end

  def self.remediation_table
    root&.join("scripts", "remediation_table.json")
  end

  # For error messages: what was actually looked at.
  def self.checked
    candidates.map(&:to_s)
  end
end
