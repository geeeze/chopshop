require "test_helper"

# The MashupChain (#51): the iterative mashup state stored in a SessionDraft.
# MashupClient.synthesize is stubbed so no live LM Studio server is contacted.
class MashupChainTest < ActiveSupport::TestCase
  SOURCES = [
    { "id" => 1, "text" => "a red phoenix rising from ashes" },
    { "id" => 2, "text" => "flat ink, three colours" }
  ].freeze

  PROMPT = "a red phoenix rising from ashes, flat ink three colours".freeze
  RATIONALE = "Both sources name the phoenix; the flat ink style is kept.".freeze

  # Stub MashupClient.synthesize for the duration of the block.
  def stub_mashup(prompt: PROMPT, rationale: RATIONALE)
    original = MashupClient.method(:synthesize)
    MashupClient.define_singleton_method(:synthesize) { |*_args, **_kw|
      MashupClient::MashupResult.new(prompt: prompt, rationale: rationale)
    }
    yield
  ensure
    MashupClient.define_singleton_method(:synthesize, original)
  end

  def start_chain
    stub_mashup do
      MashupChain.start(sources: SOURCES, prompt: PROMPT, rationale: RATIONALE)
    end
  end

  test "a new chain has one entry at the base temperature" do
    chain = start_chain
    assert_equal 1, chain.chain.length
    assert_equal 0, chain.position
    assert_equal MashupChain::BASE_TEMP, chain.current_temp
    assert_equal PROMPT, chain.current_prompt
    assert chain.draft.persisted?, "the chain is stored as a SessionDraft"
    assert_equal SessionDraft::MASHUP, chain.draft.kind
  end

  test "sources are recorded in the chain" do
    chain = start_chain
    assert_equal SOURCES, chain.sources
  end

  test "re-mash escalates temperature and appends an entry" do
    chain = start_chain
    stub_mashup(prompt: "a bolder phoenix, wider wingspan") do
      entry = chain.remash(prompt: "a bolder phoenix, wider wingspan",
                           rationale: "escalated exploration")
      assert entry, "remash returns the new entry"
      assert_equal 0.35, entry["temp"]
      assert_equal 2, chain.chain.length
      assert_equal 1, chain.position
      assert_equal "a bolder phoenix, wider wingspan", chain.current_prompt
    end
  end

  test "re-mash after revert escalates from the reverted position" do
    chain = start_chain
    stub_mashup do
      chain.remash(prompt: "first advance", rationale: "r")
      chain.remash(prompt: "second advance", rationale: "r")
      assert_equal 0.5, chain.current_temp

      chain.revert
      assert_equal 1, chain.position
      assert_equal 0.35, chain.current_temp

      entry = chain.remash(prompt: "re-advance", rationale: "r")
      assert_equal 0.5, entry["temp"],
        "escalation tracks the pointer, not a global counter"
    end
  end

  test "revert walks the pointer back to the first entry" do
    chain = start_chain
    stub_mashup do
      chain.remash(prompt: "v2", rationale: "r")
      chain.remash(prompt: "v3", rationale: "r")
      assert chain.can_revert?

      assert chain.revert
      assert_equal 1, chain.position
      assert chain.revert
      assert_equal 0, chain.position
      refute chain.can_revert?
    end
  end

  test "revert at the start is a no-op" do
    chain = start_chain
    assert_not chain.revert
    assert_equal 0, chain.position
  end

  test "the temperature is capped at MAX_TEMP" do
    chain = start_chain
    stub_mashup do
      # Advance until the cap is reached.
      entries = []
      loop do
        entry = chain.remash(prompt: "p", rationale: "r")
        break unless entry
        entries << entry["temp"]
        break if entries.length >= MashupChain::MAX_ENTRIES
      end
      assert_equal MashupChain::MAX_TEMP, entries.last
    end
  end

  test "the chain stops accepting entries at MAX_ENTRIES" do
    chain = start_chain
    stub_mashup do
      (MashupChain::MAX_ENTRIES - 1).times do
        chain.remash(prompt: "p", rationale: "r")
      end
      assert_equal MashupChain::MAX_ENTRIES, chain.chain.length
      assert_nil chain.remash(prompt: "overflow", rationale: "r"),
        "no entry is appended past the cap"
    end
  end

  test "fetch returns nil for an unknown token" do
    assert_nil MashupChain.fetch("no-such-token")
  end

  test "fetch returns nil for a blank token" do
    assert_nil MashupChain.fetch(nil)
    assert_nil MashupChain.fetch("")
  end

  test "fetch returns a chain for a valid token" do
    chain = start_chain
    fetched = MashupChain.fetch(chain.draft.token)
    assert fetched, "the chain is fetched by token"
    assert_equal chain.chain, fetched.chain
    assert_equal chain.position, fetched.position
  end

  test "next_temp reports the temperature the next re-mash will use" do
    chain = start_chain
    assert_equal 0.35, chain.next_temp
    stub_mashup do
      chain.remash(prompt: "v2", rationale: "r")
      assert_equal 0.5, chain.next_temp
    end
  end

  test "the stored draft body is valid JSON with the expected shape" do
    chain = start_chain
    parsed = JSON.parse(chain.draft.body)
    assert_equal 2, parsed["sources"].length
    assert_equal 1, parsed["chain"].length
    assert_equal 0, parsed["position"]
    assert_equal PROMPT, parsed["chain"].first["prompt"]
    assert_equal MashupChain::BASE_TEMP, parsed["chain"].first["temp"]
    assert_equal MashupClient::DEFAULT_SEED, parsed["chain"].first["seed"]
  end
end
