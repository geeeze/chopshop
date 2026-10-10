# A DRAFT the studio carries from one page to another — a cloned job spec, or a
# prompt drawn from the datasets library.
#
# WHY THIS EXISTS, and why it is a table and not the session: the session is a
# COOKIE, and a cookie has a 4 KB ceiling that Rails enforces by raising
# ActionDispatch::Cookies::CookieOverflow. The two things the studio handed
# forward were exactly the two things with no size bound — a job's spec (measured:
# up to 15,816 bytes on a blend-plot query job) and a DiffusionDB prompt — so
# /reuse, /json/use and the datasets prompt hand-off all 500'd on the larger
# ones. It was a 500 in the LOG, not in the redirect: reuse answered 302 and the
# overflow was raised committing that response's cookie, so the failure landed on
# a request that had already succeeded.
#
# So a draft is stored here and the hand-off carries a TOKEN. Two properties that
# matter, both inherited from the shape rather than bolted on:
#
#   * Owned — a draft is scoped to the operator who made it, so a token lifted
#     from someone else's URL resolves to nothing. A token is a reference, not a
#     capability.
#   * The body is TEXT, so there is no size at which this fails.
#
# Drafts are SHORT-LIVED by design: they exist to survive one redirect. They are
# pruned on every write (age, then per-owner count) rather than by a cron, so a
# run of hand-offs cannot grow the table without a timer to maintain.
class SessionDraft < ActiveRecord::Base
  include Owned

  SPEC = "spec".freeze
  PROMPT = "prompt".freeze
  MASHUP = "mashup".freeze
  KINDS = [SPEC, PROMPT, MASHUP].freeze

  LIFETIME = 2.hours
  MAX_PER_OWNER = 20

  validates :kind, inclusion: { in: KINDS }
  validates :body, presence: true

  # Store a draft and return the token the next request reads it by.
  def self.store(kind:, body:, source: nil)
    prune!
    # A URL-safe token, and NOT a secret: it is bound to the owner, so its only
    # job is to name one row unambiguously.
    draft = create!(kind: kind, body: body.to_s, source: source.presence,
                    token: SecureRandom.urlsafe_base64(9))
    draft.token
  end

  # Read a draft by token. Scoped to the signed-in owner by Owned, so a token
  # from another workspace resolves to nil and the form simply renders without a
  # draft — the hand-off degrades to "start from scratch", never to a 500.
  def self.fetch(token, kind:)
    return nil if token.blank?
    find_by(token: token.to_s, kind: kind)
  end

  def self.prune!
    where("created_at < ?", LIFETIME.ago).delete_all
    # Keep the newest MAX_PER_OWNER per owner. Done in Ruby because the studio
    # runs SQLite: a window function would be portable but no clearer at this
    # size, and this runs once per hand-off.
    group(:owner).pluck(:owner).each do |handle|
      stale = where(owner: handle).order(id: :desc).offset(MAX_PER_OWNER).pluck(:id)
      where(id: stale).delete_all if stale.any?
    end
  end
end
