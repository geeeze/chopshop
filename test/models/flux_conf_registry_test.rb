require "test_helper"

# The modifier and VAE registries, and the sentences validate produces for them.
#
# Two things are worth pinning here, and neither is decoration:
#
#   1. THE TARGETS GATE. A LoRA that cannot load against the chosen model is a
#      caller error, not a no-op, so it has to be caught BEFORE a GPU is loaded
#      — which means the studio needs the same `targets` rule the service has,
#      and this is where that rule is asserted in the studio.
#   2. THE PER-MODEL RESOLUTION RULES. klein is 16 / 64 / 4 MP, SDXL 8 / 128 /
#      2 MP and Sana 32 / 512 / 1 MP. Applying one family's floor to another is
#      the bug this file exists to catch, in both directions.
class FluxConfRegistryTest < ActiveSupport::TestCase
  def validate(**over)
    FluxConf.validate(
      width: "1024", height: "1024", images: "1",
      model_key: "klein-4b", guidance: "1.0", ack: "0", **over
    )
  end

  def problems(**over) = validate(**over)[:problems].join(" ")
  def warnings(**over) = validate(**over)[:warnings].join(" ")

  # --- the registries themselves -------------------------------------------

  test "the modifier registry is a closed list of keys, each targeting registered models" do
    assert_equal 14, FluxConf::MODIFIERS.size
    FluxConf::MODIFIERS.each do |key, entry|
      assert_equal key, entry["key"], "the entry's own key must match its slot"
      assert entry["repo_id"].present?, "#{key} must name a repo"
      assert entry["weight_name"].present?,
             "#{key} must name the file that is actually loaded"
      assert_operator entry["targets"].size, :>, 0, "#{key} must target something"
      entry["targets"].each do |target|
        refute_nil FluxConf::MODELS[target],
                   "#{key} targets #{target}, which is not a registered model"
      end
      assert_includes [true, false], entry["commercial_ok"]
      assert entry["licence"].present?, "#{key} must carry its licence"
    end
  end

  test "the VAE registry targets registered models too, and says which decodes are tiny" do
    assert_equal 5, FluxConf::VAES.size
    FluxConf::VAES.each do |key, entry|
      assert_equal key, entry["key"]
      assert entry["repo_id"].present?
      assert_includes [true, false], entry["tiny"]
      entry["targets"].each do |target|
        refute_nil FluxConf::MODELS[target], "#{key} targets #{target}, which is not registered"
      end
      assert_equal "MIT", entry["licence"]
    end

    # The tiny ones are the TAESD decoders, and the registry says so rather than
    # leaving the size to speak for itself.
    assert_equal %w[taesd taesdxl], FluxConf::VAES.values.select { |v| v["tiny"] }.map { |v| v["key"] }.sort
    FluxConf::VAES.values.select { |v| v["tiny"] }.each do |entry|
      assert_match(/soft/i, entry["notes"],
                   "#{entry['key']} must say it decodes softer, not sell itself as a free speed-up")
    end
  end

  test "modifiers_for and vaes_for filter on the same targets the service gates on" do
    klein = FluxConf.modifiers_for("klein-4b").map { |m| m["key"] }
    assert_equal %w[klein-background-remove klein-object-remove klein-outpaint klein-spritesheet], klein

    sdxl = FluxConf.modifiers_for("sdxl-1.0").map { |m| m["key"] }
    assert_includes sdxl, "sdxl-lightning-4step"
    refute_includes sdxl, "klein-outpaint",
                    "a klein adapter must not be offered to an SDXL model"

    # Not every model has an adapter — the Sana family has none — and that has to
    # come back as an EMPTY list rather than a fallback list of something else.
    assert_empty FluxConf.modifiers_for("sana-sprint-0.6b")
    assert_empty FluxConf.modifiers_for("sana-sprint-1.6b")
    assert_empty FluxConf.modifiers_for("no-such-model")

    assert_equal %w[sdxl-vae sdxl-vae-fp16-fix taesdxl], FluxConf.vaes_for("sdxl-1.0").map { |v| v["key"] }.sort
    assert_equal %w[sd-vae-ft-mse taesd], FluxConf.vaes_for("sd-1.5").map { |v| v["key"] }.sort
    assert_empty FluxConf.vaes_for("sana-sprint-0.6b")
  end

  test "modifier() is strict about an unknown key, unlike model()" do
    refute_nil FluxConf.modifier("pixel-art-xl")
    assert_nil FluxConf.modifier("no-such-lora"),
               "a fallback here would hide the unknown key validate has to report"
    refute_nil FluxConf.model("no-such-model"), "model() is deliberately lenient; modifier() is not"
  end

  test "two entries may share a repo_id, because the weight file is the identity" do
    lightning = FluxConf::MODIFIERS.values.select { |m| m["repo_id"] == "ByteDance/SDXL-Lightning" }
    assert_equal 3, lightning.size
    assert_equal 3, lightning.map { |m| m["weight_name"] }.uniq.size,
                 "three schedules under one repo means three distinct weight files"
    assert_equal %w[sdxl_lightning_2step_lora.safetensors sdxl_lightning_4step_lora.safetensors sdxl_lightning_8step_lora.safetensors],
                 lightning.map { |m| m["weight_name"] }.sort
  end

  # --- validate: the modifiers ---------------------------------------------

  test "an unknown modifier is a problem, and the sentence is the service's own" do
    message = problems(modifiers: ["teh-cool-lora"])
    # The service's sentence, character for character (modifiers._resolve), and
    # its "known:" list is SORTED — a studio that listed the registry in
    # insertion order would be a different sentence.
    assert_includes message, "unknown modifier 'teh-cool-lora' (known: #{FluxConf::MODIFIERS.keys.sort.join(', ')})"
    assert_includes problems(model_key: "sdxl-1.0", guidance: "5.0", vae: "teh-vae"),
                    "unknown vae 'teh-vae' (known: #{FluxConf::VAES.keys.sort.join(', ')})"
  end

  test "the targets refusal names the models the entry DOES target, and the service's behaviour is noted" do
    # The studio is STRICTER here than the service: engine.modifier_warnings
    # accepts an off-target adapter and warns that "it will be applied anyway,
    # but it was not trained for this model". The form refuses instead, so it
    # cannot assemble a request whose output is not what the operator sees. This
    # test pins the studio's side of that difference, because it is a deliberate
    # one and not something to "fix" into agreement by accident.
    message = problems(model_key: "klein-4b", modifiers: ["sdxl-lightning-4step"])
    assert_includes message,
                    "modifier 'sdxl-lightning-4step' does not target klein-4b (it targets sdxl-1.0, ssd-1b)"

    assert_empty validate(model_key: "sdxl-1.0", guidance: "0.0",
                          modifiers: ["sdxl-lightning-4step"])[:problems]
    assert_includes problems(model_key: "sdxl-1.0", guidance: "5.0", vae: "taesd"),
                    "vae 'taesd' does not target sdxl-1.0 (it targets sd-1.5)"
  end

  test "a modifier that carries its own schedule overrides the request's, and warns like a distilled model does" do
    result = validate(model_key: "sdxl-1.0", guidance: "5.0", modifiers: ["sdxl-lightning-4step"])
    assert_empty result[:problems], "it is a warning, not a refusal — the service runs the modifier's schedule"
    assert_includes result[:warnings].join(" "),
                    "guidance_scale 5.0 is ignored: sdxl-lightning-4step runs 4 steps at guidance 0.0, " \
                    "so the modifier's own schedule wins."

    # At the modifier's own recommendation there is nothing to report.
    assert_empty validate(model_key: "sdxl-1.0", guidance: "0.0",
                          modifiers: ["sdxl-lightning-4step"])[:warnings]

    # An adapter with NO schedule of its own says nothing — it rides the model's.
    assert_empty validate(model_key: "klein-4b", guidance: "1.0",
                          modifiers: ["klein-outpaint"])[:warnings]
  end

  test "the licence gate is one implementation, and it clears a modifier or a VAE the same way it clears a model" do
    # No registered modifier or VAE is non-commercial TODAY, so the gate is
    # exercised on the method validate calls rather than by manufacturing a
    # registry entry — and the model path is asserted to use the same sentence,
    # byte for byte, which is what stops the two drifting apart.
    non_commercial = { "key" => "some-noncommercial-lora",
                       "licence" => "Stability AI Non-Commercial Research Community License",
                       "commercial_ok" => false }

    refused = FluxConf.licence_problem(non_commercial, "0")
    refute_nil refused, "a non-commercial entry without the ack must produce the sentence"
    assert_includes refused, "some-noncommercial-lora is Stability AI Non-Commercial Research Community License"
    assert_includes refused, "non-commercial use only"
    assert_includes refused, "CHOPSHOP_FLUX_ACK_NONCOMMERCIAL=1"
    assert_includes refused, "licence from the model's licensor"

    assert_nil FluxConf.licence_problem(non_commercial, "1"), "the acknowledgement is what clears it"
    assert_nil FluxConf.licence_problem({ "key" => "x", "licence" => "MIT", "commercial_ok" => true }, "0")

    # And that IS the model's sentence: the existing refusal for sdxl-turbo is
    # produced by this method, not by a second copy of the wording.
    model_sentence = FluxConf.licence_problem(FluxConf::MODELS["sdxl-turbo"], "0")
    assert_includes problems(model_key: "sdxl-turbo", guidance: "0.0"), model_sentence
  end

  # --- validate: the per-model resolution rules ----------------------------

  test "a size legal for one family is not judged by another family's rules" do
    # 520 is a multiple of 8 (SDXL) and NOT of 16 (klein).
    assert_empty validate(model_key: "sdxl-1.0", width: "520", height: "520",
                          guidance: "5.0")[:problems]
    assert_includes problems(model_key: "klein-4b", width: "520", height: "520"),
                    "width must be a multiple of 16, got 520"

    # 400 is a multiple of 16 (klein) and NOT of 32 (Sana).
    assert_empty validate(width: "400", height: "400")[:problems]
    assert_includes problems(model_key: "sana-sprint-0.6b", width: "400", height: "400", guidance: "4.5"),
                    "width must be a multiple of 32, got 400"

    # Sana's floor is 512, not 64 — the one that would silently pass under klein.
    assert_includes problems(model_key: "sana-sprint-0.6b", width: "64", height: "64", guidance: "4.5"),
                    "width must be at least 512, got 64"
    assert_empty validate(width: "64", height: "64")[:problems]

    # And its cap is 1 MP against klein's 4 MP and SDXL's 2 MP.
    assert_empty validate(model_key: "sana-sprint-0.6b", width: "1024", height: "1024",
                          guidance: "4.5")[:problems]
    assert_includes problems(model_key: "sana-sprint-0.6b", width: "1024", height: "1056",
                             guidance: "4.5"),
                    "over the 1048576 cap"
    assert_empty validate(model_key: "sdxl-1.0", width: "1024", height: "1536",
                          guidance: "5.0")[:problems],
                 "1.5 MP is over Sana's cap and comfortably inside SDXL's"
  end

  test "every model carries its own resolution rules, so validate never reaches past one" do
    FluxConf::MODELS.each do |key, spec|
      %w[dim_multiple min_dim max_pixels].each do |field|
        refute_nil spec[field], "#{key} must carry its own #{field}"
      end
    end
    # The klein family's own values are unchanged by the fix, and the constants
    # still describe that family — they are just no longer applied to everyone.
    assert_equal FluxConf::DIMENSION_MULTIPLE, FluxConf::MODELS["klein-4b"]["dim_multiple"]
    assert_equal FluxConf::MIN_DIMENSION, FluxConf::MODELS["klein-4b"]["min_dim"]
    assert_equal FluxConf::DEFAULT_MAX_PIXELS, FluxConf::MODELS["klein-4b"]["max_pixels"]
    assert_equal [32, 512], [FluxConf::MODELS["sana-sprint-0.6b"]["dim_multiple"],
                             FluxConf::MODELS["sana-sprint-0.6b"]["min_dim"]]
    assert_equal [8, 128, 2 * 1024 * 1024],
                 [FluxConf::MODELS["ssd-1b"]["dim_multiple"], FluxConf::MODELS["ssd-1b"]["min_dim"],
                  FluxConf::MODELS["ssd-1b"]["max_pixels"]]
  end

  test "the three new models carry the licences and the commercial-ok flags they were transcribed with" do
    %w[sana-sprint-0.6b sana-sprint-1.6b ssd-1b].each do |key|
      spec = FluxConf::MODELS[key]
      refute_nil spec, "#{key} must be registered"
      assert_equal "Apache-2.0", spec["licence"]
      assert_equal true, spec["commercial_ok"]
      assert_equal false, spec["gated"]
    end

    # The Sana rows' OTHER licence: Apache-2.0 weights over a Gemma-2 encoder
    # under Google's Gemma Terms of Use. A pass-through condition that has to be
    # on the entry, because "Apache-2.0" alone is not the whole answer.
    #
    # The note is the SERVICE's, transcribed verbatim (runner_conf_drift_test
    # enforces that), so these assert the evidence the service's own text carries
    # rather than a token of my choosing: the rows were RUN on the box, and the
    # note says so with the numbers that prove it.
    %w[sana-sprint-0.6b sana-sprint-1.6b].each do |key|
      assert_match(/Gemma-2/, FluxConf::MODELS[key]["notes"])
      assert_match(/Gemma Terms of Use/, FluxConf::MODELS[key]["notes"])
    end
    # The 0.6B is the sibling that was measured; the timings are the evidence, and
    # asserting on them means the claim cannot be edited away without the test
    # noticing.
    sana = FluxConf::MODELS["sana-sprint-0.6b"]["notes"]
    assert_match(/VERIFIED RUNNING/, sana,
                 "the measured sibling must say it was run, not that it is assumed")
    assert_match(/3\.7s/, sana, "the load timing is the measurement")
    assert_match(/2\.5s/, sana, "the warm-call timing is the measurement")
    assert_match(/1\.6B/, FluxConf::MODELS["sana-sprint-1.6b"]["repo_id"])
    assert_match(/NOT run on this card/,
                 FluxConf::MODELS["sana-sprint-1.6b"]["notes"],
                 "the unmeasured sibling must CONCEDE that, not borrow the 0.6B's numbers")

    # ssd-1b's steps/guidance are MEASURED — the service's box ran it at
    # 1024x1024 and got well-formed frames — so this asserts the evidence is in
    # the note. An earlier version of this test pinned the OPPOSITE claim (that
    # they were estimates), which is what a note written before the model was
    # ever run will do; the assertion moves when the fact does.
    ssd = FluxConf::MODELS["ssd-1b"]["notes"]
    assert_match(/MEASURED/, ssd)
    assert_match(/6\.1s/, ssd)
    assert_match(/4\.4s/, ssd)
    assert_match(/ESTIMATES/, ssd,
                 "vram/repo_bytes were NOT run, so they stay labelled estimates")
    assert_equal false, FluxConf::MODELS["ssd-1b"]["distilled"],
                 "the Segmind name is about how it was pruned from SDXL, not a few-step schedule"
  end

  test "facts hands the browser the modifiers and the vaes, not just the models" do
    facts = FluxConf.facts
    assert_equal FluxConf::MODELS, facts["models"]
    assert_equal FluxConf::MODIFIERS, facts["modifiers"]
    assert_equal FluxConf::VAES, facts["vaes"]
  end

  # The guidance warning is a claim about the SERVICE's behaviour, so getting it
  # wrong tells the operator something false. It was wrong for the Sana family:
  # the rows are `distilled`, but Sana Sprint embeds guidance rather than running
  # CFG, so the service honours the number and does NOT warn. Keying the warning
  # off `distilled` alone made the studio contradict the service on a request it
  # would accept silently.
  test "the guidance warning follows the service: distilled alone is not enough" do
    # A LAMBDA, not a `def`: these two tests would otherwise define the same
    # method name on this class with different arities, and minitest runs tests
    # in a random order -- whichever defined it last would win and the other test
    # would die on an ArgumentError, or worse, silently call the wrong one.
    warn_for = lambda do |model_key, guidance|
      FluxConf.validate(width: "1024", height: "1024", images: "1",
                        model_key: model_key, guidance: guidance, ack: "0")[:warnings]
    end

    # klein-4b is distilled with NO embedded guidance, so a guidance other than
    # its own really is ignored -- the warning must stay.
    klein = warn_for.call("klein-4b", "3.0")
    assert(klein.any? { |w| w.include?("ignored") },
           "klein-4b is distilled without a guidance embedding, so 3.0 IS ignored")

    # The Sana rows are distilled WITH embedded guidance: the number is acted on,
    # so warning would be a lie about the service.
    %w[sana-sprint-0.6b sana-sprint-1.6b].each do |key|
      warnings = warn_for.call(key, "2.0")
      refute(warnings.any? { |w| w.include?("ignored") },
             "#{key} embeds guidance, so 2.0 is honoured and must not be called ignored")
    end

    # And the flag is what drives it, on the mirror as well as the service --
    # otherwise this test would pass for the wrong reason if the rows changed.
    assert_equal true, FluxConf::MODELS["sana-sprint-0.6b"]["guidance_embedded"]
    assert_equal false, FluxConf::MODELS["klein-4b"]["guidance_embedded"]
  end

  test "resolution binning is surfaced, because the size asked for may not be the size returned" do
    warn_for = lambda do |model_key, width, height|
      FluxConf.validate(width: width, height: height, images: "1",
                        model_key: model_key,
                        guidance: FluxConf::MODELS[model_key]["default_guidance"],
                        ack: "0")[:warnings]
    end

    binning = warn_for.call("sana-sprint-0.6b", "1024", "1024")
    assert(binning.any? { |w| w.include?("binning") },
           "a binning pipeline can return a different size than it was asked for")

    plain = warn_for.call("klein-4b", "1024", "1024")
    refute(plain.any? { |w| w.include?("binning") },
           "klein does not re-bin, so it must not carry the warning")
  end
end
