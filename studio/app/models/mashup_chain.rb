# The iterative mashup state (#51): a chain of synthesis results the operator
# can walk back and forth over, with temperature escalation on each advance.
#
# The chain lives inside a SessionDraft row (kind: MASHUP) so the state
# survives navigation and reload for free — the same unbounded-text handoff the
# datasets prompt uses. The body is JSON:
#
#   {
#     "sources": [{ "id": 12, "text": "a red phoenix" }],
#     "chain": [{ "prompt": "...", "rationale": "...", "temp": 0.2, "seed": 202600101 }],
#     "position": 0
#   }
#
# One row per mashup session; the token in the URL is the hand-off key.
class MashupChain
  # The escalation step: each re-mash raises the temperature by this much.
  STEP = 0.15
  # The cap. Beyond ~1.0 the model's output becomes unreliable.
  MAX_TEMP = 1.0
  # The base temperature for the first mashup — the same value MashupClient
  # uses by default, so the first synthesize call matches what the client
  # would send on its own.
  BASE_TEMP = MashupClient::DEFAULT_TEMPERATURE
  # Cap the chain length to bound storage. At the default step this is ~5
  # advances from the base temperature before hitting the cap.
  MAX_ENTRIES = 10

  attr_reader :draft

  def initialize(draft)
    @draft = draft
  end

  # --- serialisation --------------------------------------------------------

  def body
    JSON.parse(draft.body)
  end

  def sources
    body["sources"] || []
  end

  def chain
    body["chain"] || []
  end

  def position
    body["position"] || 0
  end

  # The entry the operator is currently looking at.
  def current
    chain[position]
  end

  def current_temp
    current ? current["temp"] : BASE_TEMP
  end

  def current_prompt
    current ? current["prompt"] : nil
  end

  def current_rationale
    current ? current["rationale"] : nil
  end

  # Whether the operator can revert (walk the pointer back).
  def can_revert?
    position > 0
  end

  # --- mutations ------------------------------------------------------------

  # Create a new mashup chain from source prompts and the first synthesis
  # result. Stores it as a MASHUP-kind SessionDraft.
  def self.start(sources:, prompt:, rationale:)
    draft = SessionDraft.create!(
      kind: SessionDraft::MASHUP,
      body: JSON.generate({
        "sources" => sources,
        "chain" => [{ "prompt" => prompt, "rationale" => rationale,
                      "temp" => BASE_TEMP, "seed" => MashupClient::DEFAULT_SEED }],
        "position" => 0
      }),
      token: SecureRandom.urlsafe_base64(9)
    )
    new(draft)
  end

  # Find an existing chain by its SessionDraft token. Returns nil when the
  # token is blank, unknown, or the body is malformed.
  def self.fetch(token)
    return nil if token.blank?
    draft = SessionDraft.fetch(token, kind: SessionDraft::MASHUP)
    return nil unless draft

    new(draft)
  rescue JSON::ParserError
    nil
  end

  # Advance: append a new chain entry at the escalated temperature.
  # The escalation is always chain[position].temp + STEP, capped at MAX_TEMP.
  # Returns the new MashupResult, or nil when the chain is already at the cap.
  def remash(prompt:, rationale:)
    return nil if chain.length >= MAX_ENTRIES

    new_temp = [(current_temp + STEP).round(2), MAX_TEMP].min
    entry = { "prompt" => prompt, "rationale" => rationale,
              "temp" => new_temp, "seed" => MashupClient::DEFAULT_SEED }
    new_chain = chain + [entry]
    new_body = body.merge("chain" => new_chain, "position" => new_chain.length - 1)
    update_draft!(new_body)
    entry
  end

  # Walk the pointer back one step. No-op when already at the start.
  def revert
    return false unless can_revert?

    new_body = body.merge("position" => position - 1)
    update_draft!(new_body)
    true
  end

  # The temperature the next re-mash will use, for the button label.
  def next_temp
    [(current_temp + STEP).round(2), MAX_TEMP].min
  end

  private

  def update_draft!(new_body)
    draft.update!(body: JSON.generate(new_body))
    # Re-read so the in-memory draft matches what was written.
    @draft = SessionDraft.find(draft.id)
  end
end
