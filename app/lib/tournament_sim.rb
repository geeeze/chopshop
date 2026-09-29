# A SIMULATED tournament over a candidate set, and the geometry to draw it.
#
# WHAT THIS IS, and the rule it exists under:
#
# Chopshop's pipeline NEVER PICKS A WINNER. That is a load-bearing design rule,
# stated in the page copy, in `docs/SURFACES.md` ("never ranks candidates and
# never picks a winner"), and in the ranker's own contract: it returns "a ranked
# order — never a winner". A feature that auto-picked would break the thing the
# studio is for.
#
# So this is a SIMULATION, deliberately and only: it runs a whole single-
# elimination bracket over a SET OF CANDIDATES using a DETERMINISTIC seeded
# score, and it decides nothing about the real pipeline. It touches no Job, no
# Candidate, no Validation and no Event; it reads nothing owner-scoped. It is a
# reference page beside /json, /flux, /bp and /status: it demonstrates a shape
# the studio does not have, and it is the only place a bracket appears.
#
# WHY DETERMINISTIC: a sim whose champion changed on every page load would be
# useless for reading the GEOMETRY, which is the thing being demonstrated. The
# seed is a parameter, so a given seed always yields the same bracket, and two
# different seeds are visibly different. `Digest::SHA256` rather than `Random`
# so the score does not depend on Ruby's PRNG version — a sim that changes its
# answer when the interpreter is upgraded is a sim nobody can test.
#
# THE "MEME CANDIDATE": a deliberately terrible entrant, named as a joke and
# seeded to lose in round one. It is not decoration. Its job is to make the
# LOSER path visible — a bracket that has only ever rendered winners is a
# bracket that has not been shown to handle a first-round elimination, and a
# tie, and a bye. Three things a bracket gets wrong are all things a winner-only
# bracket cannot reveal.
class TournamentSim
  # Base row pitch: the vertical space one participant occupies. Every y
  # coordinate is an integer multiple of this, which is what makes the layout
  # exact at any height with no measurement (bracket-layout-spec §3.1).
  ROW_PITCH = 32
  CARD_W = 220
  GUTTER = 48
  # The card is inset inside its 2r-tall band; 2*ROW_PITCH - this = 8 is the
  # minimum vertical gap between two round-one cards.
  CARD_H = 2 * ROW_PITCH - 8
  CONNECTOR_STROKE = 2
  CORNER_RADIUS = 2

  # The joke entrant. The seed value is irrelevant to the outcome — the score is
  # derived from the participant's NAME, so it loses because of what it is
  # called, which is the joke. See `score_for`.
  MEME_NAME = "meme candidate (this is fine)".freeze

  Outcome = Struct.new(:round, :index, :a, :b, :winner, :note, keyword_init: true)
  Match = Struct.new(:round, :index, :a, :b, :winner, :x, :y, keyword_init: true)

  attr_reader :participants, :size, :seed, :columns, :outcomes

  # `participants` is an array of names, in the order the caller has them —
  # NOT in bracket order. Slot order is computed here (§ seeding), because the
  # whole point of a bracket is that it is not simply the input order, and a
  # caller that gets to choose the order can trivially get the wrong bracket.
  def initialize(names, seed: "chopshop", layout: :mirror)
    @participants = Array(names).map(&:to_s)
    @seed = seed.to_s
    @layout = layout.to_sym
    @size = padded_size
    @outcomes = []
    @columns = build_columns
  end

  # The padded field: the next power of two at or above the entrant count. The
  # grid is NEVER shrunk to fit the entrants — every slot is laid out and the
  # surplus ones are byes, because a bracket that reflows to its data has no
  # uniform pitch and cannot be read (spec §5).
  def padded_size
    n = [participants.size, 1].max
    return 1 if n <= 1
    (1..16).map { |k| 1 << k }.find { |p| p >= n } || 1 << 16
  end

  def rounds
    Math.log2(size).round
  end

  def byes
    size - participants.size
  end

  # Seeding. The recursive "inner-outer" doubling: the standard arrangement, and
  # the one that makes the top two seeds able to meet only in the final. For
  # P=8 it gives [1,8,4,5,2,7,3,6].
  #
  # The doubling is written the way it is on purpose. `n` is captured BEFORE the
  # flat_map, because inside the comprehension `positions.size` is being
  # reassigned on the same line and reading it there yields the value the
  # assignment is about to take — which silently produces a different, and
  # wrong, arrangement that still looks plausible. The `while` also compares
  # against the RESULT, not the previous value.
  def slot_order
    return [1] if size <= 1
    positions = [1, 2]
    while positions.size < size
      n = positions.size
      positions = positions.flat_map { |p| [p, (n * 2) + 1 - p] }
    end
    positions
  end

  # The entrants in SLOT order, with `nil` for a bye. Seed 1 is the top slot and
  # seed P the bottom, which is what makes the sheet symmetric.
  def bracket
    order = slot_order
    byes = (1..size).to_a - (1..participants.size).to_a
    order.map { |seed| participants[seed - 1] || (byes.include?(seed) ? nil : nil) }
  end

  def real?(participant)
    !participant.nil?
  end

  # The score a pair is decided on. Derived from the name and the seed, so it is
  # stable across processes and reproducible from the seed alone.
  #
  # The MEME CANDIDATE is forced to the bottom: a sim where the joke entrant
  # sometimes wins is not a joke. The special case is explicit and named rather
  # than an accident of ordering.
  def score_for(participant)
    return 0.0 if participant == MEME_NAME
    digest = Digest::SHA256.hexdigest("#{seed}:#{participant}")
    digest[0, 8].to_i(16).to_f / 0xffffffff
  end

  def winner_of(a, b)
    return a if b.nil?
    return b if a.nil?
    score_for(a) >= score_for(b) ? a : b
  end

  # Run the whole bracket. Returns the champion and fills `outcomes` with one
  # entry per match, in round order — the event log the page draws beside the
  # bracket, and the thing a test asserts on.
  def simulate
    current = bracket
    (0...rounds).each do |round|
      winners = []
      (0...current.size / 2).each do |index|
        a = current[index * 2]
        b = current[index * 2 + 1]
        if a.nil? && b.nil?
          winners << nil
          next
        end
        if a.nil? || b.nil?
          # A BYE: the entrant walks through with no match played. Recorded as
          # an outcome with no rival, because a bracket that silently skips a
          # round-1 slot is a bracket whose first round does not add up.
          outcomes << Outcome.new(round: round, index: index, a: a, b: b,
                                  winner: a || b, note: "bye")
          winners << (a || b)
          next
        end
        w = winner_of(a, b)
        outcomes << Outcome.new(round: round, index: index, a: a, b: b, winner: w)
        winners << w
      end
      current = winners
      break if current.size <= 1
    end
    current.first
  end

  def champion
    @champion ||= simulate
  end

  # ---- geometry ------------------------------------------------------------

  def total_height
    (mirror? ? size / 2 : size) * ROW_PITCH
  end

  def total_width
    (columns * (CARD_W + GUTTER)) - GUTTER
  end

  def mirror?
    @layout == :mirror
  end

  # C = k for plain left-to-right, 2k-1 for the mirrored fold. The mirrored
  # layout splits the tree at its ROOT: the final sits in the CENTRE column,
  # one half advances left-to-right into it and the other right-to-left, with
  # round one at both outer edges. That is what "mirrored" means in the
  # literature and it is NOT per-round alternation (spec §2) — the zig-zag in
  # any bracket is emergent from the pairing and needs no transform at all.
  def build_columns
    mirror? ? (2 * rounds - 1) : rounds
  end

  def column_x(col)
    col * (CARD_W + GUTTER)
  end

  # The one formula the whole drawing rests on. A match at round k owns a band
  # twice the height of round k-1's, so centring a match in its band puts it
  # exactly on the midpoint of its two feeders — no measurement, at any height.
  def y_center(round, index)
    (2**round) * (2 * index + 1) * ROW_PITCH
  end

  # The x of a match, in the MIRRORED layout.
  #
  # The left half's rounds run left-to-right into the centre; the right half's
  # are the same geometry folded, so round one is flush with the RIGHT edge and
  # later rounds move inward. That fold is the reflection `x -> totalW - x - W`
  # expressed as a column index, which keeps every x an exact multiple of
  # (CARD_W + GUTTER) — a reflected coordinate would be the same number for the
  # right fields only by coincidence of the totals.
  def match_x(round, side)
    return column_x(round) unless mirror?
    return column_x(round) if side == :left
    column_x(columns - 1 - round)
  end

  # Which side of the mirror a given slot is on. The first half of the padded
  # field is the left half, the second is the right — the split is at the root,
  # which is exactly where the final sits.
  def side_for_slot(slot)
    return :left unless mirror?
    slot < size / 2 ? :left : :right
  end

  # Every match as a positioned card, ready to draw.
  #
  # The mirrored layout is built as TWO INDEPENDENT HALVES rather than one tree
  # with a transform applied. That is the whole trick, and getting it wrong is
  # the mistake worth naming: the tempting version is to lay out the full tree
  # and divide the y coordinates by two. That produces a picture which looks
  # symmetric and is not — the halves no longer meet at the final, and the
  # vertical centring property (a match sitting on its feeders' midpoint) is
  # broken by the division, because a match can land on a half-pitch.
  #
  # Instead each half is a complete bracket over P/2 entrants, with its own
  # rounds numbered from 0, using the SAME y_center formula. The two halves
  # therefore agree at the final by construction rather than by arithmetic, and
  # every y is a whole multiple of the base row pitch. The centre column is
  # drawn once, carrying the final.
  def matches
    @matches ||= begin
      if mirror?
        half = size / 2
        left = half_matches(bracket.first(half), :left)
        right = half_matches(bracket.drop(half), :right)
        final = final_match(left.last, right.last)
        left + right + [final]
      else
        ltr_matches(bracket)
      end
    end
  end

  # The rounds of one branch, placed in the half's own coordinate space.
  def half_matches(slots, side)
    out = []
    current = slots
    (0...(rounds - 1)).each do |round|
      nxt = []
      (0...current.size / 2).each do |index|
        a = current[index * 2]
        b = current[index * 2 + 1]
        out << Match.new(round: round, index: index, a: a, b: b,
                         winner: winner_of(a, b),
                         x: match_x(round, side),
                         y: y_center(round, index))
        nxt << winner_of(a, b)
      end
      current = nxt
    end
    out
  end

  def ltr_matches(slots)
    out = []
    current = slots
    rounds.times do |round|
      nxt = []
      (0...current.size / 2).each do |index|
        a = current[index * 2]
        b = current[index * 2 + 1]
        out << Match.new(round: round, index: index, a: a, b: b,
                         winner: winner_of(a, b),
                         x: match_x(round, :left),
                         y: y_center(round, index))
        nxt << winner_of(a, b)
      end
      current = nxt
    end
    out
  end

  # The single match that joins the two halves, in the CENTRE column and
  # vertically centred on the whole sheet. Both halves' finalists meet here,
  # which is the definition of the two-sided bracket.
  def final_match(left_winner, right_winner)
    Match.new(round: rounds - 1, index: 0,
              a: left_winner, b: right_winner,
              winner: winner_of(left_winner, right_winner),
              x: column_x(rounds - 1),
              y: total_height / 2.0)
  end

  # How many characters fit a card. SVG has no `text-overflow: ellipsis`, so a
  # long entrant name spills its card and visually collides with the next
  # column -- which is invisible to every geometry test, because the GEOMETRY is
  # still correct; only the paint is wrong. The number is derived from the card
  # width and the font size rather than hard-coded, so changing either moves
  # this with it.
  #
  # 12px in the monospace stack is about 7.2px per character, and the card
  # keeps an 8px inset on each side.
  NAME_CHARS = ((CARD_W - 16) / 7.2).floor

  # The name as DRAWN: clipped with a real ellipsis character, so the text
  # element's own length stays inside the card. The full name is never lost --
  # it is in the match log below the bracket and in the <title> tooltip.
  def display_name(name)
    text = name.to_s
    return text if text.length <= NAME_CHARS
    text[0, [NAME_CHARS - 1, 1].max] + "\u2026"
  end

  def round_label(round)
    remaining = size / (2**round)
    case remaining
    when 1 then "Final"
    when 2 then "Semi-finals"
    when 4 then "Quarter-finals"
    else "Round of #{remaining}"
    end
  end
end
