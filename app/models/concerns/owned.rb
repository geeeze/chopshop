# Owner scoping for every per-user model. A row's `owner` is stamped from the
# signed-in user at creation, and reads are scoped to that same user for the
# lifetime of the request — one password, one private workspace.
#
# default_scope reads Current.user_handle rather than a bare current_user call:
# in the Solid Queue worker (no request, no session) Current is blank, so the
# scope falls back to `all` and the worker can load any user's job by id. In a
# web request Current is set before any data access, so the scope always applies.
module Owned
  extend ActiveSupport::Concern

  included do
    before_validation :assign_owner, on: :create

    default_scope do
      handle = Current.user_handle
      handle.present? ? where(owner: handle) : all
    end
  end

  private

  def assign_owner
    self.owner ||= Current.user_handle
  end
end
