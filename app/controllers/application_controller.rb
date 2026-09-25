class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

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
      redirect_to root_path, notice: "Welcome to the shop."
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
