class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Belt-and-braces with public/robots.txt, and stronger than it in two ways:
  # it applies to every response (JSON, files, images — anything a crawler
  # fetches), and it reaches URLs a crawler already indexed before robots.txt
  # existed. Layouts carry a <meta name="robots"> tag for the same reason at the
  # document level.
  after_action :forbid_indexing

  # Per-user isolation: stamp the session's user on Current.user_handle for every
  # request, before any data access. The owned models' default_scope reads it, so
  # every query is already scoped to the signed-in user. Runs before the
  # sub-controllers' require_login, so an anonymous request stamps a blank handle.
  before_action :set_current

  # The login endpoint is the one place a caller can probe passwords, so it is
  # the one place attempts are counted: 10 per IP per 3 minutes. It rides the
  # app's cache store, so the counter is shared by every process serving the app
  # rather than per-process, and it sits on top of the fail2ban jail that reads
  # log/chopshop-auth.log (config/fail2ban/). Tripping it answers 429 with a plain
  # retry message — no account is ever locked out, the window just has to lapse.
  rate_limit to: 10, within: 3.minutes, only: :authenticate,
              with: :login_throttled, name: "login"

  helper_method :current_user

  # A STALE PAGE — one the browser restored from back/forward cache, or
  # revalidated with a 304 (HTML here is deliberately revalidatable via
  # stale_when_importmap_changes, so the browser may reuse its cached body) —
  # embeds an authenticity_token minted for a session that has since been reset
  # by any logout. Rails keeps the CSRF token INSIDE the session, so the
  # embedded copy can no longer be verified, and the default `with: :exception`
  # strategy RAISES WITHOUT RESETTING THE SESSION
  # (request_forgery_protection.rb:320), which leaves the operator on a raw 422
  # error page — still signed in, with every other form on that page (Run Job,
  # upload, Log out) hitting the same wall. Recover instead of dead-ending:
  # end the session and land on the login page. Nothing about forgery
  # protection is weakened — the exception is raised BEFORE the action runs, so
  # the unverified request has already performed no write.
  rescue_from ActionController::InvalidAuthenticityToken, with: :recover_stale_session

  # Password-only auth. There is no username: the password IS the identity, and
  # each user's password gates access to their own jobs, candidates, proofs,
  # scrapbook and composites (all owner-scoped to that user's handle).
  def require_login
    redirect_to login_path unless current_user
  end

  def login; end

  def authenticate
    user = User.authenticate_by_password(params[:password].to_s)
    if user
      # reset_session FIRST: the session the browser holds was minted while still
      # anonymous, so carrying its identifier across the login would let anyone
      # who planted that session have it promoted into a signed-in one (session
      # fixation). Rails rotates the identifier and drops every key the old
      # session held. The welcome flash is set AFTER the reset, so it lands in the
      # new session instead of being thrown away with the old one.
      reset_session
      session[:user_id] = user.id
      flash[:welcome] = true
      redirect_to root_path
    else
      # Dedicated plain-text auth log with explicit ISO timestamps — fail2ban
      # parses this file (Rails' own log format is timestamp-less in prod). The
      # filter and jail that read it ship in config/fail2ban/.
      auth_log = Rails.root.join("log/chopshop-auth.log")
      File.open(auth_log, "a") do |f|
        f.puts "#{Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')} chopshop login failed for #{request.remote_ip}"
      end
      Rails.logger.error("chopshop login failed for #{request.remote_ip}")
      flash.now[:alert] = "Wrong password."
      render :login, status: :unauthorized
    end
  end

  def logout
    reset_session
    redirect_to login_path
  end

  private

  # Marks EVERY response noindex/nofollow. robots.txt is only consulted for
  # crawls that start at the site root; this header travels with each response,
  # so it also covers direct links, already-indexed URLs, and the non-HTML
  # endpoints (job JSON, candidate SVGs, proofs, PDFs) that a crawler can reach
  # without ever reading robots.txt.
  def forbid_indexing
    response.headers["X-Robots-Tag"] = "noindex, nofollow, noarchive, nosnippet"
  end

  def current_user
    @current_user ||= User.find_by(id: session[:user_id])
  end

  # The 429 half of the login throttle (see rate_limit above). A plain retry
  # message on the login page: an operator who fat-fingers their password is not
  # locked out of their own studio, and nothing about the account is changed —
  # the counter in the cache store is the only state, and it expires on its own.
  def login_throttled
    flash.now[:alert] = "Too many login attempts. Wait a few minutes and try again."
    render :login, status: :too_many_requests
  end

  # The recovery for a request whose authenticity token no longer matches the
  # session (see the rescue_from above). reset_session matters as much as the
  # redirect: the stale session is what carried the dead token, and dropping it
  # means a retry from the same stale page fails the same way — and lands here
  # again — instead of half-working against a session the browser still holds.
  def recover_stale_session
    reset_session
    flash[:alert] = "That page was from a previous session, so it has been signed out. Please log in again."
    redirect_to login_path
  end

  # A page-to-page HAND-OFF of unbounded text — a cloned spec, a drawn prompt —
  # read back by the token the previous request put in the URL. Never the
  # session: a cookie is capped at 4 KB and Rails raises CookieOverflow past it,
  # which is how /reuse came to answer 302 and then 500 while committing that
  # response's cookie. See SessionDraft.
  def draft_body(token, kind)
    SessionDraft.fetch(token, kind: kind)&.body.presence
  end

  def set_current
    Current.user_handle = current_user&.handle
  end
end
