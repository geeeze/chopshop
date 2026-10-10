# The iterative mashup UX (#51): an explore-and-settle loop over
# MashupClient.synthesize.
#
# STATE lives in a MashupChain (SessionDraft, kind: MASHUP) so it survives
# navigation and reload. The chain is a list of {prompt, rationale, temp, seed}
# entries with a position pointer. The operator re-mashes (escalating
# temperature), reverts (walks the pointer back), or uses the chosen result.
#
# The flow:
#   1. POST /mashup — first mashup from source prompts (library rows or typed
#      text). Calls MashupClient at the deterministic base temperature.
#   2. GET /mashup/:token — the current state as JSON, for the result panel.
#   3. POST /mashup/:token/remash — synthesize again at an escalated
#      temperature. The button label shows what it's doing.
#   4. POST /mashup/:token/revert — walk the pointer back to an earlier result.
#   5. POST /mashup/:token/use — hand the pointed-at prompt to the Run Job
#      form via a PROMPT SessionDraft, exactly like datasets#use.
class MashupsController < ApplicationController
  before_action :require_login

  # The first mashup. Accepts source prompts as either library row ids or
  # typed text. Calls MashupClient.synthesize at the base temperature and
  # stores the chain.
  def create
    sources = resolve_sources
    return render json: { error: sources }, status: :unprocessable_entity if sources.is_a?(String)

    result = synthesize(sources)
    return render json: { error: result }, status: :bad_gateway if result.is_a?(String)

    chain = MashupChain.start(
      sources: sources.map { |s| { "id" => s[:id], "text" => s[:text] } },
      prompt: result.prompt,
      rationale: result.rationale
    )
    render json: {
      token: chain.draft.token,
      prompt: result.prompt,
      rationale: result.rationale,
      temp: MashupChain::BASE_TEMP,
      position: 0,
      chain_length: 1,
      can_revert: false,
      next_temp: chain.next_temp
    }
  end

  # The current state as JSON, for the result panel.
  def show
    chain = MashupChain.fetch(params[:token])
    return render json: { error: "no such mashup" }, status: :not_found unless chain

    render json: {
      token: chain.draft.token,
      prompt: chain.current_prompt,
      rationale: chain.current_rationale,
      temp: chain.current_temp,
      position: chain.position,
      chain_length: chain.chain.length,
      can_revert: chain.can_revert?,
      next_temp: chain.next_temp
    }
  end

  # Re-mash: synthesize again at the escalated temperature. The escalation
  # tracks the pointer (chain[position].temp + STEP), not a global counter —
  # retreat then re-advance works as expected.
  def remash
    chain = MashupChain.fetch(params[:token])
    return render json: { error: "no such mashup" }, status: :not_found unless chain

    sources = chain.sources.map { |s| s["text"] }
    new_temp = chain.next_temp
    result = synthesize(sources, temperature: new_temp)
    return render json: { error: result }, status: :bad_gateway if result.is_a?(String)

    entry = chain.remash(prompt: result.prompt, rationale: result.rationale)
    return render json: { error: "the chain is at its length cap" }, status: :unprocessable_entity unless entry

    render json: {
      token: chain.draft.token,
      prompt: result.prompt,
      rationale: result.rationale,
      temp: entry["temp"],
      position: chain.position,
      chain_length: chain.chain.length,
      can_revert: chain.can_revert?,
      next_temp: chain.next_temp
    }
  end

  # Revert: walk the pointer back one step. No-op at the start.
  def revert
    chain = MashupChain.fetch(params[:token])
    return render json: { error: "no such mashup" }, status: :not_found unless chain

    unless chain.revert
      return render json: { error: "already at the first result" }, status: :unprocessable_entity
    end

    render json: {
      token: chain.draft.token,
      prompt: chain.current_prompt,
      rationale: chain.current_rationale,
      temp: chain.current_temp,
      position: chain.position,
      chain_length: chain.chain.length,
      can_revert: chain.can_revert?,
      next_temp: chain.next_temp
    }
  end

  # Use the pointed-at result: hand it to the Run Job form via a PROMPT
  # SessionDraft, exactly like datasets#use. The redirect carries the token.
  def use
    chain = MashupChain.fetch(params[:token])
    return redirect_to datasets_path, alert: "no such mashup" unless chain

    prompt = chain.current_prompt
    return redirect_to datasets_path, alert: "this mashup has no result yet" unless prompt

    token = SessionDraft.store(
      kind: SessionDraft::PROMPT,
      body: prompt,
      source: "mashup"
    )
    redirect_to new_job_path(prompt_draft_token: token),
                notice: "Mashup result carried to the Run Job form"
  end

  private

  # Resolve source prompts from params. Accepts either `source_ids` (PromptSource
  # ids) or `sources` (typed text). Returns an array of hashes with :id and :text,
  # or an error string when the input is invalid.
  def resolve_sources
    if params[:source_ids].present?
      ids = Array(params[:source_ids]).map(&:to_i).reject(&:zero?)
      rows = PromptSource.where(id: ids).order(:id).to_a
      if rows.empty?
        return "no library prompts found for the given ids"
      end
      rows.map { |r| { id: r.id, text: r.prompt } }
    elsif params[:sources].present?
      texts = Array(params[:sources]).map(&:to_s).map(&:strip).reject(&:empty?)
      if texts.empty?
        return "at least one source prompt is required"
      end
      texts.map { |t| { id: nil, text: t } }
    else
      "provide source_ids or sources"
    end
  end

  # Call MashupClient.synthesize, returning the MashupResult or an error string.
  # Stubs the client in tests by replacing the singleton method.
  # `sources` may be an array of source hashes (the create path passes
  # resolve_sources' {id:, text:} hashes) OR an array of already-extracted
  # prompt strings (remash pre-maps chain.sources to text). Accept both: a
  # String passes through, a Hash is read under either key style.
  def synthesize(sources, temperature: MashupChain::BASE_TEMP)
    texts = Array(sources).map { |s| s.is_a?(String) ? s : (s[:text] || s["text"]) }
    MashupClient.synthesize(texts, temperature: temperature)
  rescue MashupClient::MashupError => e
    e.message
  end
end
