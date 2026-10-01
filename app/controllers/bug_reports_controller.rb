# The footer's REPORT A BUG button: any operator with an account describes what
# happened, what they expected, or what they would change, and it becomes a
# GitHub issue labelled for triage.
#
# WHY A CONTROLLER AND NOT A LINK: an operator's account here is deliberately
# anonymous (a password IS the identity), so there is nobody to email and
# nothing to attribute a mail to. A GitHub issue is the one artefact both sides
# can see, and the labels give it a queue.
#
# WHAT THE OPERATOR FILLS IN is deliberately three boxes, not one: "what
# happened", "what I expected" and "anything else". The middle one is the part
# every good bug report has and the part a single textarea cannot prompt for.
#
# WHAT IS ADDED FOR THEM, without being asked: the page they were on, their
# user agent, the account handle and the studio's version. All four are facts
# the reporter does not know and would otherwise be chased for by email.
#
# IT ANSWERS JSON, NOT A REDIRECT, because the caller is the footer's popup and
# not a page: a redirect would navigate the operator off whatever they were
# looking at to re-file the same words. A failure therefore renders as `ok:
# false` IN THE POPUP with the form still holding every word — losing a
# carefully typed report to a GitHub hiccup is the one outcome this feature
# cannot have. (An HTML caller is still answered — the flash carries the issue
# URL — so the endpoint is usable without JavaScript too.)
class BugReportsController < ApplicationController
  before_action :require_login

  KINDS = {
    "bug" => "Something is broken",
    "expected" => "It did not do what I expected",
    "suggestion" => "A suggestion"
  }.freeze

  # The prefix each kind puts on the issue title, so a triage list reads without
  # opening anything. A LABEL does the queueing; this does the reading.
  KIND_PREFIX = {
    "bug" => "Bug",
    "expected" => "Expectation",
    "suggestion" => "Suggestion"
  }.freeze

  def create
    report = params[:report] || {}
    # An unrecognised kind is not an error the operator should see: it falls back
    # to the default rather than refusing the report over a value nobody chose by
    # hand.
    kind = KINDS.key?(report[:kind].to_s) ? report[:kind].to_s : "bug"

    issue = GithubIssues.create(
      title: title_for(kind, report),
      body: body_for(kind, report),
      kind: kind
    )

    respond_to do |format|
      format.json { render json: { ok: true, url: issue.url, number: issue.number } }
      format.any do
        flash[:notice] = "Filed as #{issue.url} — thank you."
        redirect_back fallback_location: root_path
      end
    end
  rescue GithubIssues::Unconfigured, GithubIssues::Error => e
    respond_to do |format|
      format.json do
        render json: { ok: false, error: e.message }, status: :unprocessable_entity
      end
      format.any do
        # Without JS there is no popup to hold the text, so say plainly that it
        # was not filed rather than silently dropping the words.
        render plain: "Report not filed: #{e.message}", status: :unprocessable_entity
      end
    end
  end

  private

  # The title is the reporter's own first sentence, prefixed with the kind so a
  # triage list is readable without opening anything. Truncated because GitHub
  # caps a title at 256 characters and refuses the WHOLE issue past that — a
  # long paste in the summary box must not silently lose the report.
  def title_for(kind, report)
    summary = report[:summary].to_s.strip.gsub(/\s+/, " ")
    summary = "Untitled report" if summary.empty?
    "#{KIND_PREFIX[kind]}: #{summary}"[0, 256]
  end

  # The issue body, in the shape a maintainer triages by: what happened, what
  # was expected, anything else, then the facts only the box knows.
  def body_for(kind, report)
    <<~BODY
      **Kind:** #{KINDS[kind]}

      ## What happened

      #{section(report[:happened])}

      ## What I expected

      #{section(report[:expected_behaviour])}

      ## Anything else

      #{section(report[:details])}

      ---

      ### Reported from the studio

      | | |
      |---|---|
      | Page | `#{reported_page}` |
      | Account | `#{Current.user_handle}` |
      | Studio version | `#{studio_version}` |
      | User agent | #{request.user_agent.to_s.truncate(200)} |
      | Reported at | #{Time.current.utc.iso8601} |
    BODY
  end

  # WHICH page the reporter was on. The Referer is the honest answer and is what
  # a browser sends, but the fetch posts JSON with no document behind it, so it
  # may be absent -- and `request.path` then reads "/reports", which is this
  # endpoint and tells a triager nothing. So the client's own page is preferred
  # when there is one: the form carries it in a hidden field set at open time,
  # and without JavaScript the referer (or nothing) is what there is. Never
  # report this endpoint as the page the problem happened on.
  def reported_page
    from_client = params.dig(:report, :page).to_s.strip
    return from_client if from_client.present?
    return request.referer.to_s if request.referer.present?

    "not reported (posted without a referring page)"
  end

  # A heading with nothing under it reads as a broken report, so an empty box
  # says so in words rather than leaving a bare heading.
  def section(text)
    value = text.to_s.strip
    value.present? ? value : "_(not given)_"
  end

  # Which build this is. The env var when the deploy sets one (a release tag, a
  # commit), and the checkout's HEAD otherwise — an operator reporting against
  # "yesterday's main" is the single most useful thing a report can carry.
  def studio_version
    return ENV["CHOPSHOP_VERSION"].strip if ENV["CHOPSHOP_VERSION"].present?

    head = begin
      `git rev-parse --short HEAD 2>/dev/null`.to_s.strip
    rescue StandardError
      ""
    end
    head.present? ? "git #{head}" : "unknown"
  end
end
