require "test_helper"

# The prompt library: a SLICE of somebody else's dataset, kept so that three
# readers cannot disagree — the DATASETS page, the Run Job form, and the JSON
# twin an agent reads.
#
# What is pinned here is the part a dataset slice gets wrong when nobody looks:
# the PROVENANCE (a prompt with no licence and no part is a prompt nobody can
# use), the settings that make a row actionable for the generator, and the
# sampling the map draws from. The ingest is not tested here — it is a task, and
# its output is what these rows are.
class PromptSourceTest < ActiveSupport::TestCase
  def row(attrs = {})
    PromptSource.new({
      dataset: "diffusiondb",
      licence: "CC0-1.0",
      attribution: "DiffusionDB (poloclub), CC0-1.0 — prompts by Stable Diffusion users",
      part: "part-000001",
      prompt: "  a woodcut phoenix emblem, two inks, high contrast  ",
      seed: 12_345, steps: 30, guidance: 7.5, sampler: "k_euler",
      width: 512, height: 512
    }.merge(attrs))
  end

  # --- identity and provenance ----------------------------------------------

  test "the prompt is checksummed at creation, on the STRIPPED text" do
    source = row
    assert source.valid?, source.errors.full_messages.inspect
    assert_equal Digest::SHA256.hexdigest("a woodcut phoenix emblem, two inks, high contrast"),
                 source.prompt_sha
  end

  test "an unchanged checksum is left alone on re-save" do
    source = row
    source.save!
    before = source.prompt_sha
    source.update!(guidance: 9.0)
    assert_equal before, source.reload.prompt_sha,
                 "the checksum is what the row WAS created from, not a moving hash"
  end

  test "a dataset that is not one the studio knows is refused" do
    refute row(dataset: "some-other-corpus").valid?
    assert row(dataset: "some-other-corpus").tap(&:valid?).errors[:dataset].any?,
           "the refusal is filed against :dataset"

    # ...and every dataset the studio DOES know is accepted, so the list is not
    # narrower than the datasets actually ingested.
    PromptSource::DATASETS.each_key do |name|
      assert row(dataset: name).valid?, "#{name} is a dataset this model claims to know"
    end
  end

  test "the prompt is stored as one line, whatever whitespace it arrived with" do
    source = row(prompt: "a woodcut phoenix,\n\n  two inks\tand high contrast ")
    assert source.valid?
    assert_equal "a woodcut phoenix, two inks and high contrast", source.prompt
    assert_equal Digest::SHA256.hexdigest("a woodcut phoenix, two inks and high contrast"),
                 source.prompt_sha
  end

  test "a prompt and a dataset are both required" do
    refute row(prompt: nil).valid?
    refute row(dataset: nil).valid?
  end

  test "the provenance a reader is shown names the source and the part" do
    assert_match(/DiffusionDB/, row.provenance)
    assert_match(/part-000001/, row.provenance)
    assert_equal "DiffusionDB (poloclub), CC0-1.0 — prompts by Stable Diffusion users · part-000002",
                 row(part: "part-000002").provenance
  end

  # --- the bulk write the INGEST goes through --------------------------------

  # `insert_all` runs no callbacks, so the fast path is exactly where a checksum
  # goes missing and text arrives unnormalised. `PromptSource.ingest` is the one
  # door the ingest uses, and these are the two properties it exists to keep.
  test "the bulk write normalises AND checksums, which insert_all would not" do
    PromptSource.delete_all
    written = PromptSource.ingest([
      { dataset: "diffusiondb", part: "part-000001", prompt: "one\n\n  line  ", seed: 7 },
      # A row missing every key the first row carries. The ingest enriches rows
      # unevenly — most prompts have no recorded sampler, and insert_all builds
      # ONE statement — so this is the shape that aborted a 60,000-row slice with
      # "all objects being inserted must have the same keys".
      { dataset: "diffusiondb", prompt: "two" }
    ])

    assert_equal 2, written
    assert_equal 2, PromptSource.count

    first = PromptSource.find_by(prompt: "one line")
    assert_equal "one line", first.prompt, "the text is normalised on the fast path"
    assert_equal Digest::SHA256.hexdigest("one line"), first.prompt_sha,
                 "and the checksum is stamped, because insert_all runs no callbacks"
    assert_equal 7, first.seed

    sparse = PromptSource.find_by(prompt: "two")
    assert_nil sparse.seed, "a key the row did not carry is a NULL, not a refusal"
    assert_equal Digest::SHA256.hexdigest("two"), sparse.prompt_sha
  ensure
    PromptSource.delete_all
  end

  test "the bulk write can slice a large batch without splitting a statement wrong" do
    PromptSource.delete_all
    rows = 25.times.map { |i| { dataset: "diffusiondb", prompt: "p#{i}" } }
    assert_equal 25, PromptSource.ingest(rows, slice: 10)
    assert_equal 25, PromptSource.count
    assert_equal 25, PromptSource.distinct.count(:prompt_sha),
                 "every row is its own prompt, so every checksum differs"
  ensure
    PromptSource.delete_all
  end

  # --- the sampler code, transcribed and PINNED ------------------------------

  # The mapping's fixture is GENERATED from DiffusionDB's own loader
  # (`bin/generate-sampler-fixture`), so this compares a transcription against the
  # source rather than asserting what I happened to type.
  test "the sampler codes match the dataset's own mapping" do
    fixture = JSON.parse(Rails.root.join("test", "fixtures", "diffusiondb_samplers.json").read)
    assert_equal fixture["samplers"], PromptSource::SAMPLER_CODES,
                 "the module and the dataset's loader disagree about a sampler code"
    assert_match(/scripts\/diffusiondb\.py/, fixture["generated_from"],
                 "the fixture says where it came from")
  end

  test "a sampler code resolves to its name, and an unknown one resolves to nothing" do
    assert_equal "k_lms", row(sampler: "8").sampler_name
    assert_equal "k_euler", row(sampler: "3").sampler_name
    assert_nil row(sampler: "99").sampler_name, "a code the source does not define is not guessed"
    assert_nil row(sampler: nil).sampler_name
    assert_equal "k_lms", row(sampler: "k_lms").sampler_name,
                 "a row an operator made by hand, already holding a name, is left as it is"
  end

  test "the generation request carries the sampler NAME, never the dataset's code" do
    settings = row(sampler: "8").generation_settings
    assert_equal "k_lms", settings["sampler"],
                 "the service takes a name; \"8\" would be a request it cannot honour"

    # And a row with an unresolvable code simply does not carry a sampler, rather
    # than carrying the number.
    refute row(sampler: "99").generation_settings.key?("sampler")
  end

  # --- what the row is FOR ---------------------------------------------------

  test "the generation settings carry the author's numbers, and invent nothing" do
    settings = row.generation_settings
    assert_equal "a woodcut phoenix emblem, two inks, high contrast", settings["prompt"],
                 "the prompt is handed over stripped"
    # `sampler: "k_euler"` is a NAME this fixture row already carries — the other
    # sampler cases cover the dataset's numeric codes.
    assert_equal({ "seed" => 12_345, "steps" => 30, "guidance" => 7.5, "sampler" => "k_euler",
                   "width" => 512, "height" => 512 },
                 settings.except("prompt"))

    # A row whose dataset recorded no sampler must not grow a default here: the
    # service's own default is the one that should apply, and a value invented in
    # this model would look like the dataset said it.
    sparse = row(sampler: nil, guidance: nil).generation_settings
    refute sparse.key?("sampler")
    refute sparse.key?("guidance")
  end

  test "the contract the JSON twin serves separates the prompt from its settings" do
    source = row
    source.save!
    contract = source.to_contract

    assert_equal source.prompt_sha, contract["prompt_sha"]
    assert_equal "part-000001", contract["part"]
    refute contract["settings"].key?("prompt"), "the prompt is not repeated inside its own settings"
    assert_equal 7.5, contract["settings"]["guidance"]
    refute contract.key?("meta"), "the loose column is not part of the contract"
  end

  test "a summary is cut on a word and never mid-token" do
    source = row(prompt: "alpha beta gamma delta")
    assert_equal "alpha beta gamma delta", source.summary(100)
    assert_equal "alpha beta…", source.summary(13)
  end

  # --- the three questions ---------------------------------------------------

  test "census counts what a reader needs to trust the slice" do
    PromptSource.delete_all
    # Every row carries the SAME keys: insert_all builds one statement, so a
    # missing key is a row the insert refuses rather than a null.
    PromptSource.insert_all([
      { dataset: "diffusiondb", licence: "CC0-1.0", part: "part-000001", prompt: "one",
        x: 0.5, y: 0.5, topic: "art", phrase_root: "art" },
      { dataset: "diffusiondb", licence: "CC0-1.0", part: "part-000001", prompt: "two",
        x: nil, y: nil, topic: "art", phrase_root: nil },
      { dataset: "diffusiondb", licence: "CC0-1.0", part: "part-000002", prompt: "three",
        x: 1.5, y: 1.5, topic: "photo", phrase_root: "lighting" }
    ])

    census = PromptSource.census
    assert_equal 3, census["total"]
    assert_equal 2, census["parts"]
    assert_equal 2, census["mapped"], "only the rows with BOTH coordinates can be drawn"
    assert_equal 2, census["topics"]
    assert_equal ["CC0-1.0"], census["licences"]
  ensure
    PromptSource.delete_all
  end

  test "a draw is restricted by topic and by phrase root" do
    PromptSource.delete_all
    PromptSource.insert_all([
      { dataset: "diffusiondb", prompt: "art one", topic: "art", phrase_root: "art" },
      { dataset: "diffusiondb", prompt: "art two", topic: "art", phrase_root: "lighting" },
      { dataset: "diffusiondb", prompt: "photo one", topic: "photo", phrase_root: "lighting" }
    ])

    assert_equal "art", PromptSource.draw(topic: "art").topic
    assert_includes ["art two", "photo one"], PromptSource.draw(phrase_root: "lighting").prompt
    assert_nil PromptSource.draw(topic: "nothing-here"),
               "a filter with no rows draws nothing rather than ignoring the filter"
  ensure
    PromptSource.delete_all
  end

  test "the map series is one series per topic, each a list of plain x/y pairs" do
    PromptSource.delete_all
    PromptSource.insert_all([
      { dataset: "diffusiondb", prompt: "a", topic: "art", x: -1.25, y: 2.5 },
      { dataset: "diffusiondb", prompt: "b", topic: "art", x: 3.0, y: -4.0 },
      { dataset: "diffusiondb", prompt: "c", topic: "photo", x: 0.5, y: 0.5 },
      { dataset: "diffusiondb", prompt: "d", topic: "photo", x: nil, y: nil }
    ])

    series = PromptSource.map_series(per_topic: 10)
    assert_equal %w[art photo], series.map { |s| s["name"] }.sort
    # Order is NOT asserted: the sample is drawn at random, which is the point of
    # a sample — the SET of points is what the drawing depends on.
    art = series.find { |s| s["name"] == "art" }
    assert_equal [{ "x" => -1.25, "y" => 2.5 }, { "x" => 3.0, "y" => -4.0 }],
                 art["points"].sort_by { |p| p["x"] }

    # The unmapped row is not a point at the origin: a nil coordinate would draw
    # a prompt at (0, 0) and claim its neighbours, which is a lie a map must not
    # tell.
    photo = series.find { |s| s["name"] == "photo" }
    assert_equal 1, photo["points"].size
  ensure
    PromptSource.delete_all
  end

  test "the map never asks for more points per topic than one exists" do
    PromptSource.delete_all
    PromptSource.insert_all(3.times.map do |i|
      { dataset: "diffusiondb", prompt: "p#{i}", topic: "art", x: i.to_f, y: i.to_f }
    end)

    series = PromptSource.map_series(per_topic: 500)
    assert_equal 3, series.first["points"].size
  ensure
    PromptSource.delete_all
  end
end
