require "test_helper"

# Pins the shared-password gate as a property of the WHOLE app, not of a handful
# of hand-picked routes: every jobs/pages/validations route is enumerated from
# the router and called anonymously, and each one must bounce to /login. Add a
# new route under those controllers and it is covered here automatically.
class AuthGateTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  setup do
    @original_password = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
  end

  teardown do
    ENV["CHOPSHOP_PASSWORD"] = @original_password
  end

  # Every route owned by the three operator controllers, as [verb, path, action].
  # Concrete values stand in for the dynamic segments; the gate runs before the
  # action reads them, so they never need to resolve.
  def gated_routes
    controllers = %w[jobs pages validations scrapbooks audit]
    Rails.application.routes.routes.flat_map do |route|
      next [] unless controllers.include?(route.defaults[:controller].to_s)
      path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      path = path.gsub(":id", "1").gsub(":name", "probe.png")
      route.verb.to_s.split("|").map do |verb|
        [ verb, path, route.defaults[:action] ]
      end
    end
  end

  test "every jobs/pages/validations route redirects an anonymous caller to login" do
    assert_operator gated_routes.size, :>=, 15,
                    "route enumeration found suspiciously few routes"

    gated_routes.each do |verb, path, action|
      send(verb.downcase, path, headers: { "User-Agent" => MODERN_UA })
      assert_response :redirect,
                      "#{verb} #{path} (#{action}) must require a session"
      assert_match %r{\A/login}, URI.parse(response.location).path,
                   "#{verb} #{path} (#{action}) must bounce to /login"
    end
  end

  test "an anonymous upload is bounced before the file is looked at" do
    post upload_jobs_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :redirect
    assert_equal "/login", URI.parse(response.location).path
  end

  test "the health check and the login form stay reachable without a session" do
    get "/up", headers: { "User-Agent" => MODERN_UA }
    assert_response :success

    get login_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
  end

  # Behaviour above is the real pin; this catches a controller losing the gate at
  # the source level even if a route happens to be shadowed in the test run.
  test "the operator controllers all declare require_login" do
    %w[jobs_controller pages_controller validations_controller audit_controller].each do |file|
      source = Rails.root.join("app", "controllers", "#{file}.rb").read
      assert_match(/before_action :require_login/, source,
                   "#{file} must gate its actions")
    end
  end
end
