require "test_helper"
require "open3"
require "rake"

# The published skill copy must not instruct anyone to reset the operator's own
# account. That instruction was there, and following it cost the operator a real
# credential three times in one day (issue #16).
#
# Why this needs a test rather than a review: the destructive text was REDACTED
# before publication — the handle was rewritten to a placeholder and the
# instruction left intact — so the published file read like a reasonable
# procedure. A reader comparing it against the source would not see the problem,
# because the problem is not the handle, it is the sentence. A grep for the
# account's name finds nothing in either case.
#
# So the assertions below are on the SENTENCES, and they are deliberately
# phrased as "the rule must be stated here" rather than "the bad text must be
# absent": a file can satisfy the second by deleting the section entirely, which
# is not a fix. Both are asserted, because both are needed.
class E2eTestingSkillTest < ActiveSupport::TestCase
  ROOT = File.expand_path("../..", __dir__).freeze
  DOC = File.join(ROOT, "skills", "chopshop-studio", "references", "e2e-testing.md").freeze
  RAKE = File.join(ROOT, "lib", "tasks", "users.rake").freeze
  SYNC = File.join(ROOT, "sync-skills").freeze

  setup { Current.user_handle = "unodos2" }
  teardown { Current.user_handle = nil }

  def doc
    @doc ||= File.read(DOC)
  end

  def rake
    @rake ||= File.read(RAKE)
  end

  # --- the destructive instruction is gone ---------------------------------

  test "the published page no longer tells anyone to reset the demo user on demand" do
    # The exact shape of what was there, with the handle in EITHER its literal or
    # its redacted form -- because the redaction is what hid this, so a check
    # that only knew the placeholder would pass on the broken file.
    refute_match(/password is NOT in context, so reset it on demand/i, doc,
                 "the destructive instruction is still here, verbatim or redacted")
    refute_match(/reset it on demand/i, doc)
    refute_match(/User\.find_by\(handle:.*\)\.update!\(password:/, doc,
                 "the reset-on-demand recipe is still published; an agent following " \
                 "documented procedure cannot know it destroys an operator credential")

    # And no `openssl rand` written to a password file in a documented procedure.
    refute_match(/openssl rand -hex 8 > \/tmp\/e2e_pw\.txt/, doc,
                 "the throwaway-password generator is still presented as a step")
  end

  # --- and the rule is stated where a reader cannot miss it -----------------

  test "the page states the rule in capitals, at the point of use" do
    assert_match(/NEVER RESET ITS PASSWORD/i, doc,
                 "the rule has to be unmissable, not merely correct: the failure " \
                 "was an agent reading a page that looked reasonable")
    assert_match(/<test-handle>`? IS THE OPERATOR'S OWN ACCOUNT/im, doc,
                 "and it must name WHICH account, in the terms the page uses " \
                 "everywhere else, so the reader does not have to translate")
  end

  test "the page names the DISPOSABLE account, so 'reset the demo user' is unambiguous" do
    # This is the actual fix, and it is a substitution rather than a deletion:
    # the step still exists, it now has exactly one legal target.
    assert_match(/<disposable-handle>`? IS THE THROWAWAY ONE/i, doc,
                 "the disposable account must be named as such — without it, " \
                 "'reset the demo user' still has two possible meanings and the " \
                 "operator's is one of them")
    assert_match(/"Reset the demo user" means\s*\n?`<disposable-handle>`?/i, doc)
  end

  test "the two accounts are told APART, and the placeholders do not collapse" do
    # The subtle failure: a redaction rule that maps both handles to one
    # placeholder publishes a page that says "never reset the operator's
    # account" without saying which account that is. The distinction is the
    # entire content of the rule.
    assert doc.include?("<test-handle>"), "the operator's account placeholder is gone"
    assert doc.include?("<disposable-handle>"), "the disposable account placeholder is gone"
    refute_includes doc, "<operator-handle>2",
                    "the numbered handle collapsed into the bare operator handle — " \
                    "the redaction erased which account the rule is about"
  end

  test "the page says a nil authentication is a FINDING, not a licence to overwrite" do
    # /m because the sentence is hard-wrapped in the markdown: a rule phrased
    # across two lines is still the rule, and a test that only matches the
    # unwrapped form would fail on a harmless re-wrap.
    assert_match(/a nil means the stored password is NOT the one in the env file/im, doc,
                 "the read-and-check recipe is only safe if a mismatch is defined " \
                 "as something to report")
    assert_match(/REPORT it/i, doc)
    assert_match(/Do NOT "fix" it by writing a new password/im, doc,
                 "and the tempting wrong move has to be named as wrong, because " \
                 "that is what three agents did")
  end

  test "the page carries no host literal, so the redaction did its job here too" do
    # The leak guard in sync-skills covers GENERATED skills; this file is
    # hand-maintained in-repo since GENERATED was emptied, so nothing scans it
    # automatically. That gap is the reason the guard below is duplicated here.
    {
      "geenet" => "the retired domain stem",
      "unodos2" => "the operator's own account",
      "unodos3" => "the disposable account",
      "am5" => "a host name",
      "x18" => "a host name"
    }.each do |literal, what|
      refute_match(/#{literal}/, doc,
                   "#{what} (#{literal}) is published in the skill copy; the page " \
                   "is read by agents and this file is the recurrence vector #16 named")
    end
  end

  # --- the rake task: the example, and the guard behind it ------------------

  test "the users:reset usage example names the DISPOSABLE account, not the operator's" do
    # A usage line is a thing people PASTE. An example naming the operator's own
    # account is a loaded gun with the safety off, dry-run or not.
    desc_line = rake.lines.find { |l| l.include?("DRY RUN unless APPLY=1") }
    refute_nil desc_line, "the task's desc still documents its own usage"
    refute_match(/users:reset\[unodos2/, rake,
                 "the documented example still points at the operator's own " \
                 "account — one paste deletes their rows AND their scrapbook files")
    assert_match(/users:reset\[unodos3\]/, rake,
                 "the example must name the disposable account, so the copy-paste " \
                 "has exactly one safe target")
  end

  test "users:reset REFUSES the operator's account outright, and says why" do
    assert_match(/PROTECTED_HANDLES\s*=\s*%w\[unodos2\]/, rake,
                 "the guard has to name the handle it protects")
    assert_match(/ALLOW_OPERATOR_RESET/, rake,
                 "and there must be a deliberate override, or a legitimate " \
                 "operator action becomes impossible and gets worked around")
  end

  # The above reads the SOURCE; this runs the TASK. The source can say anything,
  # and the reason the guard matters is a message an agent will actually see --
  # so what is asserted is the string the abort really produces, and the fact
  # that it aborts at all rather than deleting rows.
  test "the task really refuses, and the refusal is a redirect rather than a wall" do
    User.find_or_create_by!(handle: "unodos2") { |u| u.password = SecureRandom.hex(8) }
    User.find_or_create_by!(handle: "unodos3") { |u| u.password = SecureRandom.hex(8) }
    job = Job.create!(owner: "unodos2", name: "keep-me", state: "done",
                      input_path: "source.png", runner: "mock")

    # Run the REAL task file, in this process, so it sees this process's rows.
    #
    # Two things that rule out the alternatives, both learned the hard way: a
    # subprocess gets its own connection and cannot see rows created inside the
    # test's transaction, so it would abort on "not users" and prove nothing; and
    # `Rake::Task["users:reset[a,b]"]` is not a name rake can build in-process,
    # because the bracketed arguments are parsed out of ARGV before the task is
    # defined. So the file is LOADED (that is what `bin/rails` does) and the task
    # is invoked with the argument the way rake passes one -- which is the same
    # comma-joined string the shell form produces, and which the task's own
    # comment says it has to cope with.
    require "rake"
    # `load`, not `rake_require`: the latter resolves its argument as a TASK
    # NAME inside an application, and this file is a PATH. Loading it is also
    # literally what `bin/rails` does with the whole lib/tasks directory.
    load File.join(ROOT, "lib", "tasks", "users.rake")
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)

    message = nil
    aborted = false
    begin
      # APPLY=1 on purpose: a guard that only holds in a dry run is not a guard,
      # and the whole point is the destructive run.
      ENV["APPLY"] = "1"
      Rake::Task["users:reset"].invoke("unodos2,unodos3")
    rescue SystemExit => e
      aborted = true
      message = e.message
    ensure
      ENV.delete("APPLY")
      Rake::Task["users:reset"].reenable
    end

    assert aborted, "the task ran to completion against the operator's own account " \
                    "with APPLY=1 — the guard is not in the executed path"
    assert_match(/refusing to reset/i, message.to_s,
                 "and the refusal must announce itself, not just stop")
    assert_match(/OPERATOR's own account, not a test fixture/, message.to_s,
                 "the message must explain WHY, or the reader reaches for another " \
                 "tool and the account is still gone")
    assert_match(/disposable account is unodos3/, message.to_s,
                 "and it must name the account that IS safe to reset, so the " \
                 "message is a redirect rather than a wall")
    assert_match(/issue #16/, message.to_s, "and point at the record of why")

    assert Job.exists?(job.id),
           "the refusal must happen BEFORE any deletion — a guard that runs after " \
           "the delete has already done the damage it exists to prevent"
  ensure
    Current.user_handle = nil
  end

  test "the protected handle is an exact list, not a pattern that could over-reach" do
    refute_match(/PROTECTED_HANDLES\s*=\s*%w\[unodos2\s+unodos3\]/, rake,
                 "the disposable account must NOT be protected — it is the one " \
                 "account this task exists to reset, and protecting it would make " \
                 "the task useless while looking correct")
  end

  # --- and the redaction that hid this in the first place -------------------

  test "the redaction keeps the operator/disposable distinction (sync-skills self-check)" do
    # Asserted by RUNNING the script, not by reading its rules: these are ordered
    # plain string replacements, and a rule that matches too little does not
    # fail -- it publishes something subtly wrong. The script exits non-zero when
    # the distinction collapses, which is the only way this stays true as rules
    # are added.
    out, status = Open3.capture2e("python3", SYNC, "--check", chdir: ROOT)
    assert status.success?,
           "sync-skills --check failed, which now includes the handle-redaction " \
           "self-check:\n#{out}"
    # NOTE: silence is the success signal here and nothing else. `GENERATED` is
    # empty (the disk skill was retired; the in-repo copy is the source of truth),
    # so the loop has no skill to report on and exits 0 having printed nothing.
    # Asserting on the OUTPUT would therefore be asserting on an accident of that
    # list's length, so what is asserted is the exit status plus the fact that
    # the redaction self-check did not object.
    assert_no_match(/REDACTIONS/, out,
                    "the handle-redaction self-check must not have fired")
  end

  test "the redaction self-check would CATCH a collapsed handle, not just report one" do
    # The check above is only worth anything if it can fail. So it is run against
    # a COPY of the script with the disposable-handle rule removed — which is
    # exactly the drift this guards: one fewer rule, and `unodos3` starts
    # publishing as the operator's handle.
    broken = File.join(Dir.mktmpdir, "sync-skills-broken")
    File.write(broken, File.read(SYNC).sub('("unodos3", "<disposable-handle>"),', ""))
    File.chmod(0o755, broken)
    out, status = Open3.capture2e("python3", broken, "--check", chdir: ROOT)
    refute status.success?,
           "removing the disposable-handle redaction must make the check FAIL; if " \
           "it still passes, the guard is decoration:\n#{out}"
    assert_match(/REDACTIONS/, out)
  ensure
    FileUtils.rm_rf(File.dirname(broken)) if broken && File.exist?(broken)
  end
end
