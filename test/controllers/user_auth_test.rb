require "test_helper"

# The password-only user system: each password IS an identity and gates access to
# that user's own data. Pins the three things that must not regress — a wrong
# password is refused, a right one signs in, and one user cannot see another's
# jobs (the owner scope is the whole isolation model).
class UserAuthTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def make_job(owner:, name:)
    Job.create!(name: name, state: "done", source_kind: "svg",
                input_path: "/data/#{name}.svg", stem: name, spec: {},
                runner: "mock", owner: owner)
  end

  test "a wrong password is refused and logged" do
    post login_path, params: { password: "not-the-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_response :unauthorized
    assert_nil session[:user_id]
    assert_match(/Wrong password/, response.body)
  end

  test "the right password signs the user in" do
    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    assert_redirected_to root_path
    assert session[:user_id].present?
    assert_equal "test", User.find(session[:user_id]).handle
  end

  test "a new record is stamped with the signed-in user's handle" do
    Current.user_handle = "test"
    begin
      job = Job.create!(name: "scoped", state: "pending", source_kind: "svg",
                        input_path: "/data/scoped.svg", stem: "scoped", spec: {},
                        runner: "mock")
      assert_equal "test", job.owner
    ensure
      Current.reset
    end
  end

  test "the owner scope hides another user's rows" do
    User.create!(handle: "other", password: "other-password")
    foreign = make_job(owner: "other", name: "theirs")

    Current.user_handle = "test"
    begin
      assert_nil Job.find_by(id: foreign.id)
      assert_equal 0, Job.where(id: foreign.id).count
    ensure
      Current.reset
    end
  end

  test "the jobs list shows only the signed-in user's jobs" do
    User.create!(handle: "other", password: "other-password")
    make_job(owner: "other", name: "theirs")
    make_job(owner: "test", name: "mine")

    post login_path, params: { password: "test-password" }, headers: { "User-Agent" => MODERN_UA }
    get root_path, headers: { "User-Agent" => MODERN_UA }
    assert_response :success
    assert_match(/mine/, response.body)
    refute_match(/theirs/, response.body)
  end
end
