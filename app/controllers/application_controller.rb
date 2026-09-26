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

  helper_method :current_user

  # Simple shared-password gate for a private demo. Set CHOPSHOP_PASSWORD
  # (or EDITOR_PASSWORD for continuity with the earlier portals); a blank
  # env var disables the gate entirely (local-only fallback).
  def require_login
    return if session[:authed]
    return if gate_disabled?

    redirect_to login_path
  end

  def login; end

  def authenticate
    if gate_disabled? || params[:password].to_s == gate_password
      session[:authed] = true
      flash[:welcome] = true
      redirect_to root_path
    else
      # Dedicated plain-text auth log with explicit ISO timestamps — fail2ban
      # parses this file (Rails' own log format is timestamp-less in prod).
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

  def gate_password
    ENV["CHOPSHOP_PASSWORD"] || ENV["EDITOR_PASSWORD"] || ""
  end

  def gate_disabled?
    gate_password.blank?
  end

  def current_user
    (session[:authed] || gate_disabled?) ? "operator" : nil
  end
end
