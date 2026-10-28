class Validation < ActiveRecord::Base
  include Owned

  belongs_to :job
  belongs_to :candidate, optional: true

  STATES = %w[pending running done error].freeze

  # THE EPISTEMIC FLAGS (#9) -- the two ways a proof's CLAIM LAYER can be
  # unverified. A proof's findings and its Jev answers were accept-as-stated:
  # nothing said "nobody has checked this", so an unchecked claim and a verified
  # one read identically. These two words are the studio's answer, and they are
  # the ONLY two: a third would be a state nobody reads.
  #
  #   needs_factcheck  the claim has not been checked against its source
  #   disputed         two readings of the claim disagree
  #
  # Both are stored as their own column on THIS row rather than written into
  # `manifest` or `jev_answers`: those are the RUNNER's and the ANNOTATOR's own
  # records, and stamping an opinion into a finding's hash would forge the
  # source's file. The proof row is the one place the studio can hold its own
  # verdict about the claims the run produced.
  #
  # Keyed to the chip class and the label the chip renders, so the view never
  # restates either: `.chip.needs_factcheck` says "needs factcheck".
  EPISTEMIC_FLAGS = {
    needs_factcheck: "needs factcheck",
    disputed: "disputed"
  }.freeze

  # The flags THIS proof carries, in EPISTEMIC_FLAGS' own order, as symbols --
  # what the chip partial renders. Empty for an accepted proof, which is the
  # state every existing row is in.
  def epistemic_flags
    EPISTEMIC_FLAGS.keys.select { |flag| public_send(flag) }
  end

  # Whether ANY flag is set. The audit's predicate and the chip's trigger are
  # this ONE question, so a proof cannot be counted as unverified while
  # rendering no chip (or the reverse).
  def flagged?
    epistemic_flags.any?
  end

  def sync_from_runner!
    return unless runner_validation_id
    data = RunnerClient.get_validation(self)
    self.state = data[:state] if data[:state]
    self.manifest = data[:manifest] if data[:manifest]
    self.error = data[:error] if data.key?(:error)
    self.finished_at = Time.current if state == "done"
    save!
    self
  end
end
