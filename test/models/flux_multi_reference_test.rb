require "test_helper"

# MULTI-REFERENCE: the rule that decides whether a request may name more than
# one reference image, and the order they are sent in.
#
# Multi-reference is a property of the CHECKPOINT, not a studio preference. The
# service reads `multi_reference` off the model spec and refuses a second
# reference on a family that takes one -- a 400 naming the model, before the GPU
# is touched (engine.py). The studio mirrors that flag (FluxConf::MODELS), so it
# can do two things the service alone cannot:
#
#   1. NOT OFFER a second slot on a model that would refuse one, so the operator
#      is not walked into a failure the form could have prevented;
#   2. REFUSE a hand-edited list in the form, in the SERVICE's own sentence,
#      instead of spending a round trip to a GPU box to be told the same thing.
#
# What it must NOT do is decide the list is invalid on its own authority and
# quietly drop the extra references -- that would turn a clear refusal into a
# render that silently conditioned on fewer images than the spec asked for, and
# the provenance would then record a count nobody can reconcile with the request.
class FluxMultiReferenceTest < ActiveSupport::TestCase
  # A runner LABEL is data, not a KIND. `Job.flux?` asks
  # `self.class.flux_runner?(runner)`, and that resolves the label through the
  # deployment's CONFIGURED runners, where a runner with no declared kind is an
  # `svg` pipeline runner. So `runner: "flux"` is NOT a flux job on its own: the
  # label has to exist AND declare `CHOPSHOP_RUNNER_FLUX_KIND=flux`.
  #
  # The first draft of this file got that wrong, and the result was worse than a
  # failure: every accessor test below returned `[]` and PASSED, because the
  # accessor was correctly declining to answer for a non-flux job. A vacuous
  # green is the expensive kind of bug, so the fixture is asserted against first
  # and the arrangement is set up for the whole file rather than per test.
  RUNNER_ENV = { "CHOPSHOP_RUNNER_FLUX_URL" => "http://127.0.0.1:65535",
                 "CHOPSHOP_RUNNER_FLUX_KIND" => "flux" }.freeze

  def setup
    super
    # EVERY `CHOPSHOP_RUNNER_*` variable is cleared, not just the one being set:
    # the suite runs in one process, so a runner another file configured would
    # otherwise still be in `runner_urls` and change what "the configured
  #   runners" means. Saved and restored, so this file leaves no trace either.
    @saved_runner_env = {}
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| @saved_runner_env[key] = ENV.delete(key) }
    RUNNER_ENV.each { |key, value| ENV[key] = value }
    # The app's own invalidation, not the ivars by name: `runner_urls` is a lazily
    # BUILT cache, so assigning nil to it is a corruption rather than a reset and
    # the next reader calls `.keys` on nil. The ivar names are an implementation
    # detail the app is free to change; this method is not.
    Job.reset_runners_cache!
  end

  def teardown
    ENV.keys.grep(/\ACHOPSHOP_RUNNER_/).each { |key| ENV.delete(key) }
    @saved_runner_env.each { |key, value| ENV[key] = value }
    Job.reset_runners_cache!
    super
  end

  def validate(**over)
    FluxConf.validate(
      width: "1024", height: "1024", images: "1",
      model_key: "klein-4b", guidance: "1.0", ack: "0", **over
    )
  end

  def problems(**over) = validate(**over)[:problems].join(" ")

  def job(spec_flux)
    Job.new(name: "multi-ref", runner: "flux", source_kind: "raster",
            input_path: "", spec: { "flux" => spec_flux })
  end

  test "the fixture is a real flux job, so nothing below is vacuous" do
    assert job("image" => "a.png").flux?,
           "the label must resolve to kind flux -- otherwise flux_reference_names " \
           "returns [] for every spec and every accessor test in this file is " \
           "asserting that a non-flux job has no references, which is trivially true"
    assert_equal %w[a.png], job("image" => "a.png").flux_reference_names
  end

  # --- the registry says which models may take several ---------------------

  test "the mirror carries multi_reference, and it is true for exactly the models that take a list" do
    # The field is what the whole feature is gated on, so a model entry missing it
    # would read as "takes one" by default and quietly hide the capability.
    FluxConf::MODELS.each do |key, entry|
      assert entry.key?("multi_reference"),
             "#{key} does not mirror multi_reference, so the form cannot know whether " \
             "to offer a second slot"
    end

    multi = FluxConf::MODELS.select { |_, e| e["multi_reference"] }.keys.sort
    assert_equal %w[klein-4b klein-4b-base], multi,
                 "the FLUX.2 [klein] family is the one that conditions on a list; " \
                 "every img2img family takes a single reference"
  end

  # --- the gate -------------------------------------------------------------

  test "several references on a model that takes one is a problem, in the service's own sentence" do
    sentence = problems(model_key: "sdxl-1.0", guidance: "5.0",
                        references: [ "a.png", "b.png" ])
    # The service's exact wording (engine.py), because the service is what
    # refuses: an operator who hits it in the form and an operator who hits it on
    # the GPU must be reading the same explanation, not two.
    assert_includes sentence, "sdxl-1.0 takes a single reference image, but 2 were given."
    assert_includes sentence, "Multi-reference is a property of the checkpoint"
  end

  test "the count in the sentence is the count sent, not a fixed two" do
    assert_includes problems(model_key: "sd-1.5", guidance: "5.0",
                             references: %w[a b c]),
                    "sd-1.5 takes a single reference image, but 3 were given."
  end

  test "several references on a multi_reference model is not a problem" do
    assert_empty validate(model_key: "klein-4b",
                          references: %w[a b c])[:problems],
                 "klein conditions on all of them at once, which is the whole point " \
                 "of the feature"
  end

  # A blank slot is an empty slot on a form, not a second reference. Counting one
  # would refuse a request the service would happily accept -- and would do it in
  # the service's voice, which is worse than a plain error: it would be a false
  # claim about what the service does.
  test "a blank slot does not make it several references" do
    assert_empty validate(model_key: "sdxl-1.0", guidance: "5.0",
                          references: [ "a.png", "", "  " ])[:problems],
                 "one filled slot and two empty ones is still one reference"
  end

  test "one reference is never a problem, on any model" do
    FluxConf::MODELS.each_key do |key|
      assert_empty validate(model_key: key, guidance: "1.0", ack: licence_ack(key),
                            references: [ "a.png" ])[:problems],
                  "#{key} takes exactly one reference, and this is exactly one"
    end
  end

  test "no references at all is a plain generation, and is not this gate's business" do
    assert_empty validate(model_key: "sdxl-1.0", guidance: "5.0")[:problems]
  end

  # The gate must be a PROBLEM (a 400 the caller must fix), not a warning. The
  # service exits 2 on this and never renders, so a warning here would promise a
  # render that cannot happen.
  test "the refusal is a problem rather than a warning" do
    result = validate(model_key: "sdxl-1.0", guidance: "5.0", references: %w[a b])
    assert_includes result[:problems].join(" "), "takes a single reference image"
    refute_includes result[:warnings].join(" "), "takes a single reference image",
                 "the service refuses rather than warns, so a warning would be a " \
                 "promise of a render that cannot happen"
  end

  # --- the order ------------------------------------------------------------

  test "the singular image key is the FIRST reference and the list follows it" do
    j = job("image" => "pose.png", "references" => %w[palette.png trim.png])
    assert_equal %w[pose.png palette.png trim.png], j.flux_reference_names,
                 "a spec that predates multi-reference means what it meant, and the " \
                 "list is the extra conditioning"
  end

  test "a spec with only the singular key is a one-element list" do
    assert_equal %w[only.png], job("image" => "only.png").flux_reference_names
  end

  test "a spec with only the list is that list, in order" do
    assert_equal %w[a.png b.png], job("references" => %w[a.png b.png]).flux_reference_names
  end

  # A hand-written spec that names one extra image without making a list of it is
  # an obvious thing to write, and it means exactly one more. Rejecting it would
  # refuse a request the service accepts.
  test "a references key holding a bare string means one more reference" do
    assert_equal %w[pose.png palette.png],
                 job("image" => "pose.png", "references" => "palette.png").flux_reference_names
  end

  test "reading the references does not mutate the job's own spec" do
    j = job("image" => "pose.png", "references" => %w[palette.png])
    before = j.spec["flux"]["references"].dup
    3.times { j.flux_reference_names }
    assert_equal before, j.spec["flux"]["references"],
                 "the accessor must be safe to call more than once -- it is called by " \
                 "the controller AND the job, and `<<` into the spec would grow it"
  end

  test "the same reference named twice is two references" do
    assert_equal %w[a.png a.png], job("references" => %w[a.png a.png]).flux_reference_names,
                 "de-duplicating would change what conditioned the render while the " \
                 "spec still said two"
  end

  test "a non-flux job has no references, whatever its spec says" do
    svg = Job.new(name: "x", runner: "svg", source_kind: "svg", input_path: "a.svg",
                  spec: { "flux" => { "image" => "a.png" } })
    assert_empty svg.flux_reference_names,
                 "the accessor is about /edit, and only a flux runner has one"
  end

  # --- the names are held to the containment rule --------------------------

  # TWO LAYERS, and the split is the whole containment story. The first draft of
  # this test asserted that the read side drops a traversing name, and it failed
  # with `["passwd"]` -- which is the correct behaviour of the wrong layer.
  #
  # `flux_reference_names` is the DISPLAY/REQUEST side: it reduces each name to
  # its basename, because that is what a reference resolves to inside
  # storage/uploads. `flux_reference_spec_values` is the GATE side: it hands the
  # names over UNEDITED, so `RunJob.validate_references!` sees
  # "../../../../etc/passwd" and REFUSES it.
  #
  # Reducing first and validating second would be the actual vulnerability: a
  # traversing name would become "passwd", pass a containment test that only ever
  # sees basenames, and be sent to the service as though it were a stored upload.
  # So the order of these two readers is load-bearing and is asserted here from
  # both sides.
  test "the GATE sees the traversing name unedited, so it can be refused" do
    j = job("image" => "../../../../etc/passwd")
    assert_equal %w[../../../../etc/passwd], j.flux_reference_spec_values,
                 "the gate must receive the name as written -- if it were reduced " \
                 "first, \"passwd\" would look like a plain stored upload and the " \
                 "refusal would never fire"

    error = assert_raises(FluxClient::FluxError) do
      RunJob.validate_references!(j.flux_reference_spec_values)
    end
    assert_match(/is not a stored upload/, error.message)
  end

  test "the request side reduces to a basename, which is what a reference resolves to" do
    # The same name, through the OTHER reader. Both halves are pinned because
    # either one alone is a weaker statement than the pair: the reduction is what
    # makes a legitimate `storage/uploads/x.png` work, and the gate is what makes
    # a traversal fail.
    assert_equal %w[real.png], job("image" => "storage/uploads/real.png").flux_reference_names,
                 "a name that names a real stored upload by path is accepted as that file"
    assert_equal %w[passwd], job("image" => "../../../../etc/passwd").flux_reference_names,
                 "and a traversing name reduces to a basename -- harmless ONLY because " \
                 "the gate above refuses the spec before this list is ever used"
  end

  test "a basename that is not a plain file name is not a reference" do
    # `File.basename("some/dir/")` is "dir" -- Ruby strips the trailing slash --
    # so a trailing separator does not produce an empty basename. What the
    # request-side filter actually refuses is a basename that could not name a
    # file in storage/uploads: a shell metacharacter, a space, a slash that
    # survived, a leading dot. Pinned because the filter is a WHITELIST regex,
    # and a whitelist nobody tests is a whitelist that quietly stopped applying.
    assert_empty job("image" => "a b.png").flux_reference_names, "a space cannot be a stored upload"
    assert_empty job("image" => "a;rm.png").flux_reference_names, "nor a shell metacharacter"
    assert_empty job("image" => "").flux_reference_names, "nor a blank"
  end

  test "every reference is held to the same containment rule, not just the first" do
    # The list is new, and a rule applied only to the FIRST element of a list is
    # the shape of bug this feature could easily introduce: `image` was the only
    # key before, so `validate_reference!` was only ever called on one name, and
    # a `references` list that skipped validation would be the hole.
    #
    # REAL files are written for this, because the gate checks that the name
    # resolves to a file INSIDE storage/uploads -- so a fixture that only names
    # plausible-looking basenames would be refused for the wrong reason and the
    # test would prove nothing. They are removed afterwards, and the traversal
    # entry has no file on purpose: its being refused is the assertion.
    Dir.mktmpdir do |dir|
      uploads = Rails.root.join("storage", "uploads")
      uploads.mkpath
      written = %w[pose.png palette.png].map do |name|
        path = uploads.join(name)
        path.binwrite("PNG")
        path
      end
      begin
        j = job("image" => "pose.png", "references" => %w[palette.png ../../etc/shadow])

        # The first two are real and together pass: proving the loop is not just
        # refusing everything, which a single bad entry would also satisfy.
        assert_nothing_raised { RunJob.validate_references!(j.flux_reference_spec_values.first(2)) }

        # The third is refused, and the message names IT.
        error = assert_raises(FluxClient::FluxError) do
          RunJob.validate_references!(j.flux_reference_spec_values)
        end
        assert_match(%r{\.\./\.\./etc/shadow}, error.message,
                     "the refusal must name the offending entry, or an operator " \
                     "cannot tell which of their three references was the problem")
      ensure
        written.each { |path| File.delete(path) if File.exist?(path) }
      end
    end
  end

  private

  # The licence gate is not what this file is about, so a model whose card needs
  # an acknowledgement is given one rather than failing for an unrelated reason.
  def licence_ack(key)
    FluxConf.model(key)["commercial_ok"] == false ? "1" : "0"
  end
end
