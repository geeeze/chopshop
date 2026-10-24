require "test_helper"

# THE DATASETS SELECTS ship a BOUNDED window: the top-N values by row count, so
# the first paint is small. The library's topic labels are descriptive slugs --
# 60,000 prompts carry thousands of them -- and an uncapped <select> ships
# 9,633 topic options and 1,968 phrase-root options (~1.17 MB of markup) before
# any interaction.
#
# The tail is NOT duplicated in the page. It stays reachable through the
# "search all N" affordance, which reads the FULL ranked vocabulary from the
# library JSON (`/datasets/library`, which now carries every value with its
# count) rather than from markup.
#
# Non-vacuity: with the cap reverted to the full vocabulary, the option-count
# assertions below fail -- the bound is the bite. `insert_all` seeds the bulk
# rows without callbacks/validations, so the weight test can seed more values
# than the cap cheaply.
class DatasetsSelectsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  CAP = DatasetsController::SELECT_LIMIT
  VOCAB_JS = Rails.root.join("app/javascript/dataset_vocabulary.js").read(encoding: "UTF-8")

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  # `count` distinct topics, the first `hot` of them carrying `hot_n` rows each
  # and the rest one row. The hot ones are the top by count; `topic-%04d` sorts
  # alphabetically, so the ranked order is deterministic.
  def seed_topics!(count:, hot: 0, hot_n: 1)
    rows = count.times.flat_map do |i|
      topic = format("topic-%04d", i)
      n = i < hot ? hot_n : 1
      n.times.map do |j|
        { dataset: "diffusiondb", prompt: "prompt #{i}-#{j}", topic: topic,
          phrase_root: format("root-%04d", i), part: format("part-%06d", (i * hot_n) + j) }
      end
    end
    PromptSource.insert_all(rows)
  end

  test "the topic select is capped to the top N by count and carries the top items" do
    login!
    seed_topics!(count: CAP + 50, hot: 3, hot_n: 10)
    get datasets_path
    assert_response :success

    options = Nokogiri::HTML(response.body).css("select[name='topic'] option")

    # bounded: the cap plus the `any` blank
    assert_operator options.size, :<=, CAP + 1,
                    "the select ships at most the cap (plus the `any` blank)"

    # the most common values are present, with the count in the label
    assert_includes options.map { |o| o["value"] }, "topic-0000"
    assert_includes options.map { |o| o.text.strip }, "topic-0000 (10)"
    assert_includes options.map { |o| o.text.strip }, "topic-0001 (10)"

    # the tail beyond the cap is NOT in the page
    refute_includes options.map { |o| o["value"] }, format("topic-%04d", CAP + 10)
  end

  test "the phrase-root select is capped too, and its options carry counts" do
    login!
    seed_topics!(count: CAP + 20, hot: 2, hot_n: 8)
    get datasets_path
    assert_response :success

    options = Nokogiri::HTML(response.body).css("select[name='root'] option")
    assert_operator options.size, :<=, CAP + 1
    assert_includes options.map { |o| o.text.strip }, "root-0000 (8)"
    refute_includes options.map { |o| o["value"] }, format("root-%04d", CAP + 5)
  end

  test "the first paint option count stays bounded (weight regression guard)" do
    login!
    seed_topics!(count: CAP + 500, hot: 5, hot_n: 20)
    get datasets_path
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    topic_opts = doc.css("select[name='topic'] option").size
    root_opts = doc.css("select[name='root'] option").size

    assert_operator topic_opts, :<=, CAP + 1,
                    "a 700-topic library must not put 700 options in the first paint"
    assert_operator root_opts, :<=, CAP + 1
    # and the tail is absent from the page, not merely short-listed
    refute_includes doc.css("select[name='topic'] option").map { |o| o["value"] },
                    format("topic-%04d", CAP + 100)
  end

  test "the full ranked vocabulary stays reachable through the library JSON" do
    login!
    seed_topics!(count: CAP + 50, hot: 3, hot_n: 10)
    get library_datasets_path(limit: 1)
    assert_response :success

    data = JSON.parse(response.body)
    assert_equal CAP + 50, data["topics"].size, "the API keeps the FULL vocabulary"
    assert_equal "topic-0000", data["topics"].first["name"], "ranked by count DESC"
    assert_equal 10, data["topics"].first["count"]
    assert_equal CAP + 50, data["roots"].size
    assert_equal "root-0000", data["roots"].first["name"]
    assert_equal 10, data["roots"].first["count"]
  end

  test "each select carries a search affordance for the full vocabulary" do
    login!
    seed_topics!(count: 5)
    get datasets_path
    assert_response :success

    doc = Nokogiri::HTML(response.body)
    topic_btn = doc.at_css("[data-vocab-more][data-vocab-kind='topic']")
    root_btn = doc.at_css("[data-vocab-more][data-vocab-kind='root']")

    refute_nil topic_btn, "the topic select carries a search affordance"
    refute_nil root_btn, "the root select carries a search affordance"
    assert_equal library_datasets_path(limit: 1), topic_btn["data-vocab-endpoint"]
    assert_equal library_datasets_path(limit: 1), root_btn["data-vocab-endpoint"]
    assert_includes topic_btn.text, "5", "the affordance names how much is behind it"
    assert_includes root_btn.text, "5"
  end

  test "the vocabulary search file parses as JavaScript and stands alone" do
    require "open3"
    _out, status = Open3.capture2e("node", "--check", "-") { |stdin| stdin.write(VOCAB_JS) }
    assert status.success?, "dataset_vocabulary.js must parse as JavaScript"
    refute_match(/^\s*import /, VOCAB_JS, "the module must stand alone: no imports")
    refute_match(/^\s*export /, VOCAB_JS, "and no exports -- it is a side-effect module")
  end

  test "the map is drawn on demand, not in the first paint" do
    login!
    seed_topics!(count: 5)
    get datasets_path
    assert_response :success
    # the deferred control is present; the 186 KB SVG is not in this response
    assert_includes response.body, "draw the prompt-space map"
    assert_match(/map=1/, response.body)
    refute_includes response.body, 'class="dataset-map"', "no map SVG in the first paint"

    # asking for it does not 500; the card says why it could not be drawn
    get datasets_path(map: 1)
    assert_response :success
    assert_match(/map is not drawn|map could not be drawn/, response.body)
  end
end
