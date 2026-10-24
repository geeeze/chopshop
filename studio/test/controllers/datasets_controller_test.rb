require "test_helper"

# DATASETS — the library's filter selects embed the topic's live count.
#
# The kb's filter select renders `per (294)` — the option is a census as well
# as a filter, so the operator sees the distribution BEFORE filtering rather
# than after. The studio's surface is the same idea: `@topics` is the ranked
# count hash (`topic => n`) that comes from the same grouped query the list
# itself reads, so the option LABEL is `topic (n)` and the option VALUE stays
# the bare topic, which is what the filter actually matches on.
#
# Non-vacuity: with the fix reverted to `@topics.keys` the options are the bare
# topics and every count assertion below fails — the counts are the bite.
#
# This test seeds two topics -- under the SELECT_LIMIT cap, so both survive;
# the cap itself and the first-paint weight guard are asserted in
# datasets_selects_test.rb. The tail beyond the cap is NOT in the page at all:
# it is read from the library JSON by the "search all N" affordance.
class DatasetsControllerTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def login!
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
  end

  def seed!
    PromptSource.create!(dataset: "diffusiondb", prompt: "a woodcut phoenix emblem",
                         part: "part-000001", topic: "art", phrase_root: "a woodcut")
    PromptSource.create!(dataset: "diffusiondb", prompt: "an art deco skyline",
                         part: "part-000002", topic: "art", phrase_root: "an art")
    PromptSource.create!(dataset: "diffusiondb", prompt: "a misty forest path",
                         part: "part-000003", topic: "nature", phrase_root: "a misty")
  end

  test "the topic select embeds the live count and keeps the full vocabulary" do
    login!
    seed!
    get datasets_path
    assert_response :success

    options = Nokogiri::HTML(response.body).css("select[name='topic'] option")
                                                .map { |o| [o.text.strip, o["value"]] }

    # counts embedded: `art (2)`, `nature (1)`
    assert_includes options, ["art (2)", "art"], "the option label is `topic (count)`"
    assert_includes options, ["nature (1)", "nature"]
    # the value stays the bare topic, so the filter still matches on it
    assert_includes options.map(&:last), "art"
    # full vocab: every seeded topic is present, none folded into a "top N"
    # (`include_blank` adds a bare "" for "any", which is not a topic)
    assert_equal %w[art nature].sort, options.map(&:last).reject(&:blank?).sort
  end

  test "the surface popup carries the same counted options as the page" do
    login!
    seed!
    get surface_datasets_path
    assert_response :success
    assert_includes response.body, "art (2)"
    assert_includes response.body, "nature (1)"
  end
end
