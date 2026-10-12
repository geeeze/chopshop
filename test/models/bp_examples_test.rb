require "test_helper"

# DRIFT PIN for the job specs on the /bp page.
#
# `BpExamples::ALL` is a hand mirror: every `doc` in it is a COPY of the `spec`
# block of one file in chopshop-bp's `examples/`, and the page shows them as
# "paste this as-is". Until this test existed the only thing checking them was
# the page's own rendering — a doc that stopped matching the service's example
# still rendered, still copied, and would simply be refused by the service the
# first time somebody pasted it. The file's own header says the docs "are NOT
# written here"; this is what makes that true rather than aspirational.
#
# WHY A LIVE READ AND NOT A FIXTURE: these are DATA files (`examples/*.json`),
# not Python source, so the studio's test container can read them over a volume
# mount without needing the sibling repo's runtime — and the sibling IS on this
# machine. Where it is not, the test SKIPS with the reason rather than passing:
# "I could not read the service's example" must never read as "the doc agrees".
# (The suite's other drift pins take the same rule from the opposite end —
# RunnerConfDriftTest carries a checked-in fixture for the Python constants the
# container genuinely cannot read.)
#
# THE COMPARISON IS STRUCTURAL: each side is `JSON.parse`d and compared as Ruby
# hashes. Key order, whitespace and indentation are the JSON writer's business;
# a changed VALUE, a changed nested key or a spec key the doc no longer carries
# are all mismatches.
class BpExamplesTest < ActiveSupport::TestCase
  # The sibling repo. Overridable, like CHOPSHOP_SIBLING_ROOT in
  # RunnerConfDriftTest and CHOPSHOP_FLUX_REPO in flux_repo_parity_test, for a
  # layout where the service is not a sibling.
  BP_EXAMPLES_DIR = ENV.fetch(
    "CHOPSHOP_BP_EXAMPLES_DIR",
    File.expand_path("~/chopshop-bp/examples")
  ).freeze

  # op => the example file its `doc` is copied from. Derived from the entries'
  # own `source:` lines where possible, pinned here where the source names more
  # than one file (query: a chart spec plus run records).
  SOURCE_FILES = {
    "generate" => "shapes.json",
    "digest"   => "scores.json",
    "query"    => "query_scatter.json",
    "tree"     => "hierarchy.json",
    "log"      => "events.json",
    "blender"  => "blender_shapes.json"
  }.freeze

  # The one op whose `source` names a SECOND file: `query_scatter.json` carries
  # the chart spec as a BARE document (no op/spec envelope, because a chart spec
  # is what the service's query engine reads directly), and the run records
  # live in `examples/runs/demo-01.run.json` + `demo-02.run.json`. Those
  # records are elided from `BpExamples` deliberately — they are ~8 KB and ~4 KB
  # of fixture candidate data — so the pin for query covers the chart keys and
  # asserts the elision marker is shown instead of inlining them.
  QUERY_RUN_FILES = %w[runs/demo-01.run.json runs/demo-02.run.json].freeze

  def examples_dir
    @examples_dir ||= begin
      unless Dir.exist?(BP_EXAMPLES_DIR)
        skip "no chopshop-bp examples at #{BP_EXAMPLES_DIR} — set CHOPSHOP_BP_EXAMPLES_DIR to pin them"
      end
      Pathname.new(BP_EXAMPLES_DIR)
    end
  end

  def read_example(rel)
    path = examples_dir.join(rel)
    unless path.file?
      flunk "chopshop-bp's example file is gone: #{path} — the /bp page's docs are copies of it"
    end
    JSON.parse(path.binread)
  end

  # The document the SERVICE's example holds, whichever envelope shape it uses:
  # `{"op": …, "spec": {…}}` for the operation examples, the bare spec itself
  # for the chart examples (`query_scatter.json` and friends carry no envelope
  # — a chart spec is what the query engine reads directly).
  def spec_of(rel)
    raw = read_example(rel)
    raw["op"] ? raw["spec"] : raw
  end

  def doc_for(op)
    entry = BpExamples.for_op(op)
    refute_nil entry, "#{op}: no entry in BpExamples::ALL"
    entry[:doc]
  end

  # What the page SHOWS for a key that is not in bp's example: nothing, once the
  # two agree. Both documented deviations are checked as their own tests below
  # so this comparison can stay strict.
  test "every bp example doc is exactly the spec of its own chopshop-bp example file" do
    SOURCE_FILES.each do |op, file|
      expected = spec_of(file)
      actual = doc_for(op)

      assert_kind_of Hash, expected, "#{file}: the example must carry a spec object"
      assert_equal expected, actual,
        "#{op}: the doc the /bp page offers no longer matches #{file}. The docs " \
        "are copies, not authored: re-copy the spec from the service's example " \
        "(or update the service and re-copy deliberately)."
    end
  end

  # The elision, asserted as elision: the page must still SAY that the run
  # records are missing and must still paste something the service refuses
  # rather than silently drawing an empty chart. The chart keys themselves are
  # pinned by the comparison above.
  test "query elides its run records and says so, and the records exist to be pasted" do
    entry = BpExamples.for_op("query")
    assert entry[:runs_note].present?,
      "query is the one op that takes `runs`, and an empty one is refused: " \
      "the page must say the records are elided, not paste a stub"

    rendered = BpExamples.job_spec_json("query")
    assert_includes rendered, BpExamples::RUNS_ELIDED,
      "the elision marker must survive into the rendered spec, so a reader who " \
      "pastes it gets a parse error rather than a silent empty chart"

    QUERY_RUN_FILES.each do |rel|
      path = examples_dir.join(rel)
      assert path.file?, "#{rel}: the run records the note points at must exist to be pasted"
      assert_kind_of Hash, JSON.parse(path.binread), "#{rel} must hold a run record"
    end
  end

  # The page claims provenance; the pin is what makes the claim checkable. An
  # entry whose `source` names a file the map does not read would be a doc this
  # test silently never compared.
  test "every entry names the example file this test reads" do
    assert_equal SOURCE_FILES.keys.sort, BpExamples::ALL.map { |e| e[:op] }.sort,
      "one doc per operation, and every operation has a source file pinned here"

    BpExamples::ALL.each do |entry|
      assert_includes entry[:source], SOURCE_FILES.fetch(entry[:op]),
        "#{entry[:op]}: the provenance line names a file this test does not read"
    end
  end

  # The whole point of the surface: what the page renders as a pasteable spec
  # must BE these docs, not a second hand-written copy.
  test "the spec the page renders is built from the pinned docs" do
    BpExamples::ALL.each do |entry|
      spec = BpExamples.job_spec(entry[:op])
      assert_equal entry[:op], spec["op"], "#{entry[:op]}: the op travels with the doc"
      assert_equal entry[:doc], spec["doc"], "#{entry[:op]}: the rendered doc is the pinned doc"
    end
  end
end
