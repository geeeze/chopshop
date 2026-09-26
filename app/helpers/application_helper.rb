module ApplicationHelper
  # Render one Jev answer into the three fields the card needs.
  #
  # A live Jev response is TYPED, and the three types carry their certainty in
  # different places (verified against api.typesafe.ai, model jev-1.13.0):
  #
  #   choice -> { choice:, confidence: }              confidence is real
  #   score  -> { score:, probabilities:, legend: }   confidence is reported 0.0
  #   noul   -> { noul: 0.1 }                         P(true); no confidence field
  #
  # Reading `ans["choice"]` for all of them (what the view did) renders two of
  # the four cards blank, and reading `ans["confidence"]` prints "confidence 0%"
  # on a score answer, because Ruby treats 0.0 as truthy.
  def jev_answer_view(ans)
    return { value: ans.to_s, note: nil, confidence: nil } unless ans.is_a?(Hash)

    case ans["type"]
    when "score"
      score = ans["score"]
      # Mirror the annotator's `_fraction_label`: a fractional score maps onto
      # the NEAREST described level (0.35 -> level 0), not the exact key, so the
      # label matches the verdict Jev itself folded.
      level = score.is_a?(Numeric) ? score.round.to_s : score.to_s
      legend = ans["legend"].is_a?(Hash) ? ans["legend"][level] : nil
      { value: jev_words(score), note: legend, confidence: jev_max_probability(ans) }
    when "noul"
      p_true = ans["noul"]
      { value: "P(true) #{percent(p_true)}",
        note: jev_noul_note(p_true),
        confidence: jev_noul_confidence(p_true) }
    else # "choice", and older answers that predate the type field
      confidence = ans["confidence"]
      { value: jev_words(ans["choice"]),
        note: nil,
        confidence: confidence.is_a?(Numeric) && confidence.positive? ? confidence : nil }
    end
  end

  def jev_words(value)
    value.to_s.tr("_", " ")
  end

  def percent(value)
    return "–" unless value.is_a?(Numeric)

    "#{(value * 100).round}%"
  end

  private

  def jev_max_probability(ans)
    probabilities = ans["probabilities"]
    return nil unless probabilities.is_a?(Hash) && probabilities.any?

    probabilities.values.map { |v| v.is_a?(Numeric) ? v : 0 }.max
  end

  # Certainty for a noul answer is distance from a coin flip: 0.5 -> 0, 0/1 -> 1.
  def jev_noul_confidence(value)
    return nil unless value.is_a?(Numeric)

    2 * (value - 0.5).abs
  end

  def jev_noul_note(value)
    return nil unless value.is_a?(Numeric)

    case value
    when 0.0..0.35 then "the measurements are not enough on their own"
    when 0.35..0.65 then "the measurements are borderline"
    else "the measurements support a production call"
    end
  end
end
