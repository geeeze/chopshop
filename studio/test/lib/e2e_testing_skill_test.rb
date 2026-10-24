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

  # A NEUTRAL fixture handle: this file ships with the app, so it must not name
  # the deployment's real accounts. These are strings in a test DB, not
  # credentials, and the point is that nothing here depends on what a real
  # handle is called.
  OPERATOR_HANDLE = "op-account".freeze
  DISPOSABLE_HANDLE = "disposable-account".freeze

  setup { Current.user_handle = OPERATOR_HANDLE }
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
    # Two layers, and the first needs no configuration: the GENERIC classes a
    # regex can recognise (an absolute home path under any account, a
    # private-network address). The second reads the box's own redaction table if
    # this checkout has one -- the table is untracked, so a clean clone has no
    # literals to check either, and the test says which layer it ran.
    assert_no_match(%r{/home/[a-z][a-z0-9_-]*}, doc,
                    "an absolute home path is published in the skill copy")
    assert_no_match(%r{/Users/[A-Za-z][A-Za-z0-9_-]*}, doc)
    assert_no_match(/\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.\d{1,3}\.\d{1,3}\b/,
                    doc, "a private-network address is published in the skill copy")

    table = File.join(ROOT, ".sync-skills.local")
    if File.exist?(table)
      File.readlines(table, chomp: true).each do |line|
        next if line.strip.empty? || line.lstrip.start_with?("#")
        literal = line.split("\t").first.to_s.strip
        next if literal.length < 4
        refute_includes doc, literal,
                        "#{literal.inspect} is a this-host literal from the redaction " \
                        "table and it is published in the skill copy; the page is read " \
                        "by agents and this file is the recurrence vector #16 named"
      end
    end
  end

  # --- the rake task: the example, and the guard behind it ------------------

  test "the users:reset usage example names a PLACEHOLDER, never a real account" do
    # A usage line is a thing people PASTE, and the example that used to be here
    # named the operator's own account: one paste deleted their rows AND their
    # scrapbook files. It now names a placeholder and points at the config that
    # says which accounts are off limits, because a literal example is a greeting
    # card for whichever deployment shipped it.
    desc_line = rake.lines.find { |l| l.include?("DRY RUN unless APPLY=1") }
    refute_nil desc_line, "the task's desc still documents its own usage"
    assert_match(/users:reset\[<handle>\]/, rake,
                 "the example must be a placeholder, so the copy-paste has no " \
                 "target on any particular deployment")
    assert_match(/CHOPSHOP_PROTECTED_HANDLES/, rake,
                 "and it must name the place the operator's accounts are listed")
  end

  test "users:reset REFUSES the operator's account outright, and says why" do
    # The list is CONFIG, not a literal: this file is published, and a hardcoded
    # handle tells every reader which account to aim at on the deployment that
    # wrote it. What is asserted is the contract -- config-driven, fail-closed,
    # with a deliberate override -- rather than the handle of the day.
    refute_match(/PROTECTED_HANDLES\s*=\s*%w\[/, rake,
                 "a hardcoded handle list is back in a published file")
    assert_match(/ENV\.fetch\("CHOPSHOP_PROTECTED_HANDLES"/, rake,
                 "the guard has to read the handles it protects from config")
    assert_match(/ALLOW_OPERATOR_RESET/, rake,
                 "and there must be a deliberate override, or a legitimate " \
                 "operator action becomes impossible and gets worked around")
  end

  # The above reads the SOURCE; this runs the TASK. The source can say anything,
  # and the reason the guard matters is a message an agent will actually see --
  # so what is asserted is the string the abort really produces, and the fact
  # that it aborts at all rather than deleting rows.
  test "the task really refuses, and the refusal is a redirect rather than a wall" do
    op = User.find_or_create_by!(handle: OPERATOR_HANDLE) { |u| u.password = SecureRandom.hex(8) }
    User.find_or_create_by!(handle: DISPOSABLE_HANDLE) { |u| u.password = SecureRandom.hex(8) }
    job = Job.create!(owner: OPERATOR_HANDLE, name: "keep-me", state: "done",
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
      ENV["CHOPSHOP_PROTECTED_HANDLES"] = OPERATOR_HANDLE
      Rake::Task["users:reset"].invoke("#{OPERATOR_HANDLE},#{DISPOSABLE_HANDLE}")
    rescue SystemExit => e
      aborted = true
      message = e.message
    ensure
      ENV.delete("APPLY")
      ENV.delete("CHOPSHOP_PROTECTED_HANDLES")
      Rake::Task["users:reset"].reenable
    end

    assert aborted, "the task ran to completion against the operator's own account " \
                    "with APPLY=1 — the guard is not in the executed path"
    assert_match(/refusing to reset/i, message.to_s,
                 "and the refusal must announce itself, not just stop")
    assert_match(/OPERATOR's own account, not a test fixture/, message.to_s,
                 "the message must explain WHY, or the reader reaches for another " \
                 "tool and the account is still gone")
    assert_match(/NOT listed in CHOPSHOP_PROTECTED_HANDLES/, message.to_s,
                 "and it must say which accounts ARE safe to reset, so the " \
                 "message is a redirect rather than a wall")
    assert_match(/issue #16/, message.to_s, "and point at the record of why")

    assert Job.exists?(job.id),
           "the refusal must happen BEFORE any deletion — a guard that runs after " \
           "the delete has already done the damage it exists to prevent"
  ensure
    Current.user_handle = nil
  end

  test "with no configured handle list the task refuses everything, rather than nothing" do
    # FAIL CLOSED. An unset variable must not read as "no accounts are protected",
    # which would make a fresh clone's first `users:reset` a destructive no-op
    # guard. The refusal is the whole point of the empty case.
    # Owner scoping is real: Job's default_scope reads Current.user_handle, so a
    # row is only visible to the account that owns it. Read it back AS the
    # disposable account, or the existence check would fail for a reason that has
    # nothing to do with the guard.
    User.find_or_create_by!(handle: DISPOSABLE_HANDLE) { |u| u.password = SecureRandom.hex(8) }
    Current.user_handle = DISPOSABLE_HANDLE
    job = Job.create!(owner: DISPOSABLE_HANDLE, name: "keep-me-too", state: "done",
                      input_path: "source.png", runner: "mock")

    require "rake"
    load File.join(ROOT, "lib", "tasks", "users.rake")
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)

    message = nil
    aborted = false
    begin
      ENV["APPLY"] = "1"
      ENV.delete("CHOPSHOP_PROTECTED_HANDLES")
      Rake::Task["users:reset"].invoke(DISPOSABLE_HANDLE)
    rescue SystemExit => e
      aborted = true
      message = e.message
    ensure
      ENV.delete("APPLY")
      Rake::Task["users:reset"].reenable
    end

    assert aborted, "an unconfigured task must refuse: with no list it cannot tell a " \
                    "disposable account from the operator's own"
    assert_match(/CHOPSHOP_PROTECTED_HANDLES is not set/, message.to_s)
    assert Job.exists?(job.id), "and it must refuse BEFORE deleting anything"
  ensure
    Current.user_handle = nil
  end

  test "the protected handles are exact strings from config, not a pattern" do
    # A pattern ("any handle with a digit") would protect accounts nobody asked
    # about and give the guard a shape that looks arbitrary. The task compares
    # exact members of the configured list.
    assert_match(/protected\.select \{ \|h\| handles\.include\?\(h\) \}/, rake,
                 "the guard must compare exact handles")
    refute_match(/PROTECTED_HANDLES\s*=.*include\?/, rake,
                 "a substring/pattern guard is not what this task promises")
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
    assert_no_match(/REDACTIONS/, out,
                    "the handle-redaction self-check must not have fired")
  end

  test "the redaction self-check would CATCH a missing handle rule, not just report one" do
    # The check above is only worth anything if it can fail. The cases are now
    # DERIVED from the untracked table, so a rule that is simply ABSENT would have
    # no case to fail -- which is why the self-check also requires the handle
    # family to be complete. This proves that requirement by running the check
    # against a table with the disposable-handle rule removed.
    table = File.join(ROOT, ".sync-skills.local")
    skip "no local redaction table on this checkout" unless File.exist?(table)

    dir = Dir.mktmpdir
    broken = File.join(dir, "redactions")
    kept = File.readlines(table, chomp: true).reject do |line|
      line.split("\t").last.to_s.strip == "<disposable-handle>"
    end
    File.write(broken, kept.join("\n") + "\n")

    out, status = Open3.capture2e({ "CHOPSHOP_SYNC_REDACTIONS" => broken },
                                  "python3", SYNC, "--check", chdir: ROOT)
    refute status.success?,
           "dropping the disposable-handle rule must make the check FAIL; if it " \
           "still passes, the guard is decoration:\n#{out}"
    assert_match(/REDACTIONS/, out)
    assert_match(/disposable-handle/, out,
                 "and it must name the rule that is missing")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
