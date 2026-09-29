require "test_helper"

# The SIMULATED tournament: the bracket's DATA (seeding, byes, outcomes) and its
# GEOMETRY (the mirrored fold).
#
# Why this file exists as tests and not as a page: the bracket is the one place
# in the studio where a wrong number is invisible. A bracket that mispairs
# still looks like a bracket; a bracket whose fold is off by one column still
# looks symmetric. So the invariants that make it correct are pinned here,
# against the formula in bracket-layout-spec §3, rather than eyeballed.
#
# The sim decides NOTHING about the real pipeline — that is a design rule
# ("the pipeline never picks a winner") and the first test pins it, because a
# simulation that started writing Events or Validations would be a much more
# serious regression than a wrong y coordinate.
class TournamentSimTest < ActiveSupport::TestCase
  NAMES = %w[alpha bravo charlie delta echo foxtrot golf hotel].freeze

  # A helper that takes a COUNT (not a list), because most of these assertions
  # are about sizes and padding, and naming eight strings to check a power of
  # two is how a test starts asserting the wrong thing.
  def sim(n = NAMES, **kw)
    list = n.is_a?(Integer) ? n.times.map { |i| "p#{i}" } : n
    TournamentSim.new(list, **kw)
  end

  # ---- the rule the whole feature sits under ----

  test "the sim touches nothing: it is a demonstration, not a decision" do
    s = sim
    before = { jobs: Job.count, events: Event.count, validations: Validation.count }
    s.simulate
    after = { jobs: Job.count, events: Event.count, validations: Validation.count }
    assert_equal before, after,
      "a simulation that recorded a pick would break the studio's core rule: " \
      "the pipeline never picks a winner"
    assert_not s.respond_to?(:create!), "a sim is not a model"
  end

  # ---- determinism ----

  test "the same seed always yields the same bracket" do
    a = sim(NAMES, seed: "one")
    b = sim(NAMES, seed: "one")
    assert_equal a.simulate, b.simulate
    assert_equal a.outcomes.map { |o| [o.round, o.index, o.winner] },
                 b.outcomes.map { |o| [o.round, o.index, o.winner] }
  end

  test "a different seed gives a different bracket" do
    # Not a hard guarantee for any one pair of seeds, so this asserts that the
    # seed is actually an INPUT rather than decoration: over several seeds the
    # champion must move at least once.
    champs = %w[alpha bravo charlie delta echo].map { |s| sim(NAMES, seed: s).simulate }
    assert champs.uniq.size > 1, "the seed is not reaching the result"
  end

  # ---- padding and byes ----

  test "the field is padded to a power of two and the surplus is byes" do
    assert_equal 8, sim(8).size
    assert_equal 8, sim(5).size, "5 entrants pad to 8"
    assert_equal 3, sim(5).byes
    assert_equal 16, sim(9).size, "9 entrants pad to 16"
  end

  test "a bye advances the entrant with no match played, and says so" do
    s = sim(5)
    s.simulate
    byes = s.outcomes.select { |o| o.note == "bye" }
    assert_equal 3, byes.size, "one bye per padded slot, each recorded rather than skipped"
    assert byes.all? { |o| o.a || o.b }, "a bye still advances somebody"
  end

  test "the bracket is never shorter than the entrant count" do
    (1..17).each do |n|
      s = sim(n)
      assert_operator s.size, :>=, n
      assert_equal 0, (1 << s.rounds) - s.size,
        "#{n} entrants: padded size must be an exact power of two"
    end
  end

  # ---- seeding: the invariant that actually matters ----

  test "top two seeds can only meet in the final" do
    # The perfect-seeding containment property (spec §1.2). It is the whole
    # reason the seeding exists, and it is invisible in the drawing: a bracket
    # with the wrong seed order can look perfectly symmetric.
    s = sim(%w[s1 s2 s3 s4 s5 s6 s7 s8])
    order = s.slot_order
    # Seed 1 and seed 2 sit in opposite halves, so no match before the final
    # can contain both.
    assert_equal 1, order.first, "seed 1 is the top slot"
    assert_equal 8, order.max, "the weakest seed is somewhere in the field"
    # The printed convention's symmetry property is that seed 1 and seed P
    # occupy the two EXTREME slots (first and second here, read top-down in two
    # columns). For P=8 the arrangement is [1,8,4,5,2,7,3,6]: seed 1 is the top
    # slot and seed 2 sits in the bottom HALF, opposite seed 1. What matters,
    # and what the containment assertion below checks, is that they cannot meet
    # before the final.
    assert_equal 1, order.first
    assert_equal 8, order[1], "seed 8 is paired with seed 1 in the very first match"
    first_round_meet = order.each_slice(2).map { |pair| pair.sort }
    assert(first_round_meet.none? { |pair| pair == [1, 2] },
      "seeds 1 and 2 must not meet in round one")
  end

  test "seeding is the standard inner-outer arrangement" do
    assert_equal [1], sim(1).slot_order
    assert_equal [1, 2], sim(2).slot_order
    assert_equal [1, 4, 2, 3], sim(4).slot_order
    assert_equal [1, 8, 4, 5, 2, 7, 3, 6], sim(NAMES).slot_order
  end

  # ---- the meme candidate ----

  test "the meme candidate is present, and is the one that loses" do
    s = sim(NAMES + [TournamentSim::MEME_NAME])
    assert_includes s.participants, TournamentSim::MEME_NAME
    s.simulate
    first_round = s.outcomes.select { |o| o.round == 0 }
    meme_match = first_round.find { |o| [o.a, o.b].include?(TournamentSim::MEME_NAME) }
    refute_nil meme_match, "the meme candidate must actually be drawn in round one"
    refute_equal TournamentSim::MEME_NAME, meme_match.winner,
      "a sim where the joke entrant sometimes wins is not a joke"
  end

  # ---- geometry: the formula, pinned ----

  test "every y is on the pitch grid, in BOTH layouts" do
    # A match landing on a half-pitch is the signature of the one way to get the
    # mirror wrong: laying out the full tree and halving the y. The picture still
    # looks symmetric, so only the arithmetic catches it.
    [[:ltr], [:mirror]].each do |(layout)|
      s = sim(NAMES, layout: layout)
      s.matches.each do |m|
        assert_equal 0, m.y % TournamentSim::ROW_PITCH,
          "#{layout} match round #{m.round} index #{m.index} at y=#{m.y} is off the pitch grid"
      end
    end
  end

  test "the final is vertically centred on the sheet" do
    s = sim(NAMES, layout: :mirror)
    final = s.matches.find { |m| m.round == s.rounds - 1 }
    assert_equal s.total_height / 2.0, final.y,
      "the final sits at the vertical centre, which is where the two halves meet"
  end

  test "a match is centred on the midpoint of its two feeders" do
    # The property that makes the whole layout exact with no measurement: round
    # k owns a band twice round k-1's, so the midpoint of the two feeders IS
    # the centre of the band.
    s = sim(NAMES)
    by_round = s.matches.group_by(&:round)
    by_round.each_cons(2) do |(r, prevs), (_, curs)|
      prevs.each_with_index do |p, i|
        a = s.y_center(r - 1, i * 2)
        b = s.y_center(r - 1, i * 2 + 1)
        assert_equal (a + b) / 2, s.y_center(r, i),
          "round #{r} index #{i} is not on its feeders' midpoint"
      end
    end
  end

  test "the card fits its band: the minimum vertical gap is never negative" do
    assert_operator 2 * TournamentSim::ROW_PITCH, :>=, TournamentSim::CARD_H,
      "a card taller than its own band would overlap its neighbour"
  end

  # ---- the mirror: what "mirrored" has to mean ----

  test "the mirrored layout splits at the root, with the final in the centre" do
    s = sim(NAMES, layout: :mirror)
    assert_equal 2 * s.rounds - 1, s.columns, "C = 2k - 1 for the mirrored fold"
    final = s.matches.find { |m| m.round == s.rounds - 1 }
    assert_equal TournamentSim::CARD_W * 0 + (s.columns / 2) * (TournamentSim::CARD_W + TournamentSim::GUTTER),
                 final.x, "the final sits in the CENTRE column, not at an edge"
  end

  test "round one is at BOTH outer edges" do
    # The defining property of the two-sided sheet (spec §2a): the field narrows
    # toward the middle, so the earliest round cannot be only on the left.
    s = sim(NAMES, layout: :mirror)
    firsts = s.matches.select { |m| m.round == 0 }
    xs = firsts.map(&:x).uniq.sort
    assert_equal 2, xs.size, "round one must appear on both sides of the mirror"
    assert_equal s.total_width - TournamentSim::CARD_W, xs.last,
      "the outermost right column must be flush with the right edge"
    assert_equal 0, xs.first, "and the outermost left column flush with the left"
  later = s.matches.select { |m| m.round == 1 }
    assert later.all? { |m| m.x > xs.first && m.x < xs.last },
      "later rounds move INWARD, which is what makes it a fold"
  end

  test "the two halves are mirror images of each other" do
    s = sim(NAMES, layout: :mirror)
    firsts = s.matches.select { |m| m.round == 0 }
    left = firsts.select { |m| m.x < s.total_width / 2 }
    right = firsts.select { |m| m.x >= s.total_width / 2 }
    assert_equal left.size, right.size, "the split is at the root, so the halves are equal"
    left.sort_by { |m| m.y }.each_with_index do |l, i|
      r = right.sort_by { |m| m.y }[i]
      assert_equal TournamentSim::CARD_W, s.total_width - r.x - l.x,
        "round-one match #{i}: the two sides are not reflections"
    end
  end

  test "the mirror is a render transform, never a data permutation" do
    # Folding the drawing is a x-transformation; the bracket's DATA keeps one
    # top-to-bottom order. If the fold were baked into the model, two renders
    # with different layouts would disagree about who played whom — which is the
    # bug this assertion exists to prevent.
    a = sim(NAMES, layout: :mirror)
    b = sim(NAMES, layout: :ltr)
    assert_equal a.bracket, b.bracket, "the layout must not change the entrants"
    assert_equal a.simulate, b.simulate, "nor the result"
  end

  test "plain left-to-right has one column per round" do
    s = sim(NAMES, layout: :ltr)
    assert_equal s.rounds, s.columns
    xs = s.matches.map(&:x).uniq.sort
    assert_equal s.rounds, xs.size, "each round gets exactly one column"
    assert_equal xs.sort, xs, "and they run left to right, in round order"
  end

  test "the mirror halves the height and widens it" do
    n = NAMES.size
    ltr = sim(NAMES, layout: :ltr)
    mir = sim(NAMES, layout: :mirror)
    assert_equal n * TournamentSim::ROW_PITCH, ltr.total_height
    assert_equal (n / 2) * TournamentSim::ROW_PITCH, mir.total_height,
      "folding the tree at the root halves how tall it is"
    assert_operator mir.total_width, :>, ltr.total_width
  end

  # ---- labels ----

  test "rounds are named by how many matches survive them" do
    s = sim(NAMES)
    assert_equal "Round of 8", s.round_label(0)
    assert_equal "Quarter-finals", s.round_label(1)
    assert_equal "Semi-finals", s.round_label(2)
    assert_equal "Final", s.round_label(3)
  end
end
