# Password-only identity: no username, no directory. The password a user types
# IS who they are, and it gates access to their own data — everything that
# carries their `handle` (jobs, candidates, proofs, scrapbook, composites).
#
# `handle` is the internal owner key. It is never shown in the UI and never
# entered at login; it only ever comes from the users table after the password
# matches. Adding a user is a one-liner:
#
#   bin/rails runner 'User.create!(handle: "alice", password: "…")'
class User < ActiveRecord::Base
  has_secure_password

  validates :handle, presence: true, uniqueness: true

  # Login has no handle to look up, so the entered password is compared against
  # every user's digest until one matches. O(n) bcrypt on purpose and acceptable:
  # the user count here is single digits, and password-only identity is the whole
  # point. A miss and a blank password both return nil (indistinguishable).
  def self.authenticate_by_password(raw)
    return nil if raw.blank?
    all.detect { |user| user.authenticate(raw) }
  end
end
