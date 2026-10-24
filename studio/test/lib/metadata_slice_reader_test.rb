require "test_helper"
require "rake"

# The dataset slice is 1.1GB of JSON and is stored zstd-compressed at about 16%
# of that, so `settings_lookup` reads it through a decompressor. That introduced
# the one risk this file exists to close: a SECOND reader for the same file.
#
# The hazard is not that the compressed path fails loudly. It is that it fails
# QUIETLY — returns fewer rows, or rows with nil hyperparameters, and the
# library simply looks emptier. Nothing raises. So the contract pinned here is
# not "the compressed path works" but "the compressed path and the plain path
# produce IDENTICAL output", byte for byte, on the same input.
class MetadataSliceReaderTest < ActiveSupport::TestCase
  ROWS = [
    { "prompt" => "a lighthouse at dusk", "seed" => 1, "step" => 20, "cfg" => 7.5,
      "sampler" => 8, "width" => 1024, "height" => 1024, "image_name" => "x.png",
      "prompt_nsfw" => false, "part_id" => 3, "user_name" => "u1",
      "timestamp" => "2023-01-01", "image_nsfw" => false },
    { "prompt" => "  a lighthouse at dusk  ", "seed" => 2, "step" => 30, "cfg" => 9.0,
      "sampler" => 1, "width" => 512, "height" => 768, "image_name" => "y.png",
      "prompt_nsfw" => true, "part_id" => 4, "user_name" => "u2",
      "timestamp" => "2023-01-02", "image_nsfw" => true },
    { "prompt" => "not one of ours", "seed" => 9, "step" => 1, "cfg" => 1.0,
      "sampler" => 2, "width" => 64, "height" => 64, "image_name" => "z.png",
      "prompt_nsfw" => false, "part_id" => 5, "user_name" => "u3",
      "timestamp" => "2023-01-03", "image_nsfw" => false }
  ].freeze

  setup do
    Rake::Task.clear rescue nil
    load Rails.root.join("lib/tasks/datasets.rake").to_s
    @dir = Pathname.new(Dir.mktmpdir("slice"))
    @plain = @dir.join("metadata-slice.jsonl")
    @plain.write(ROWS.map { |r| JSON.generate(r) }.join("\n") + "\n")
  end

  teardown { FileUtils.remove_entry(@dir) if @dir&.exist? }

  test "a compressed slice and a plain slice give the SAME rows" do
    zst = @dir.join("metadata-slice.jsonl.zst")
    ok = system("zstd", "-q", "-f", @plain.to_s, "-o", zst.to_s,
                out: File::NULL, err: File::NULL)
    skip "zstd is not installed on this box" unless ok

    wanted = ["a lighthouse at dusk"]
    from_plain = settings_lookup(@dir, wanted)

    # Move the plain file aside so only the compressed one can be found.
    hidden = @dir.join("hidden.jsonl")
    FileUtils.mv(@plain, hidden)

    from_zst = settings_lookup(@dir, wanted)

    assert_equal from_plain, from_zst,
      "the compressed reader and the plain reader disagree, which means the " \
      "library is being built from a different file depending on how the dump " \
      "happens to be stored"
    assert_equal 1, from_zst.size
    assert_equal 1, from_zst["a lighthouse at dusk"][:seed],
      "first occurrence wins: the untrimmed duplicate must not overwrite it"
    assert_equal 20, from_zst["a lighthouse at dusk"][:steps]
    assert_equal 7.5, from_zst["a lighthouse at dusk"][:guidance]
  end

  test "the .zst file is preferred when both are present, so the small one is used" do
    zst = @dir.join("metadata-slice.jsonl.zst")
    ok = system("zstd", "-q", "-f", @plain.to_s, "-o", zst.to_s,
                out: File::NULL, err: File::NULL)
    # Same guard as the test above: without the binary the fixture is never
    # created, and asserting anyway fails on the PLAIN name -- a red suite that
    # says nothing about the code (the dev container has no zstd).
    skip "zstd is not installed on this box" unless ok
    assert_equal "metadata-slice.jsonl.zst", metadata_slice_path(@dir).basename.to_s,
      "with both on disk the compressed one wins, or the space saving is undone " \
      "by preferring whichever file happens to sort first"
  end

  test "a missing slice is an empty answer, not a crash" do
    empty = Pathname.new(Dir.mktmpdir("empty"))
    begin
      assert_equal({}, settings_lookup(empty, ["anything"]),
        "a dataset whose hyperparameters were never fetched still ingests its " \
        "coords; it does not abort the whole run")
    ensure
      FileUtils.remove_entry(empty)
    end
  end

  test "the reader streams: it never holds the file in memory" do
    # A reader that slurped the file would still return the right rows, so the
    # assertion is on the SHAPE: the source is yielded line by line.
    seen = 0
    each_metadata_line(@plain) { |_l| seen += 1 }
    assert_equal ROWS.size, seen
    assert_respond_to each_metadata_line(@plain), :each
  end

  test "a missing slice ANNOUNCES the loss, so a hollow ingest is not silent" do
    # The empty answer above is the intended trade, but a library whose
    # hyperparameters are all nil is indistinguishable from a good one in the
    # census. The task must say so on stderr, because the operator's only other
    # evidence is a column of nils they have no reason to go and look at.
    empty = Pathname.new(Dir.mktmpdir("empty"))
    begin
      _out, err = capture_io do
        assert_equal({}, settings_lookup(empty, ["anything", "anything else"]))
      end
      assert_match(/NO hyperparameters/, err.to_s,
        "an ingest that loses every hyperparameter must say so")
      assert_match(/metadata-slice\.jsonl/, err.to_s,
        "and it must name the input that was missing")
    ensure
      FileUtils.remove_entry(empty)
    end
  end
end
