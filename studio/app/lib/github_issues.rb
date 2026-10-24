# Filing a GitHub issue from the studio, for somebody who is USING it rather
# than developing it.
#
# WHY IT EXISTS: the footer's maintenance button lets any operator given an
# account explain what happened, what they expected, or what they would change,
# and have that land in the project's issue tracker as something to TRIAGE --
# not as a chat message, a log line, or an email nobody reads. The alternative
# (they describe it to whoever gave them the password) loses the page, the
# account and the words they actually typed.
#
# CONFIGURATION, both from the environment so the repo never learns anyone's
# topology:
#
#   CHOPSHOP_GITHUB_TOKEN  a PAT with `issues: write` on the repo below. Absent
#                          means the popup still renders and still records
#                          nothing silently: it reports "not configured" rather
#                          than pretending to file.
#   CHOPSHOP_GITHUB_REPO   "owner/name". Defaults to the project's own repo.
#
# Ruby stdlib only, like every other client in app/lib -- no new gem, nothing
# to add to the bundle for one POST.
require "net/http"
require "json"
require "uri"

module GithubIssues
  API = "https://api.github.com".freeze
  TIMEOUT = 10

  # Every report carries this one, so the triage queue is a label view rather
  # than a search. The kind labels below say WHICH queue it is in; this says it
  # has not been looked at yet.
  TRIAGE_LABEL = "needs-triage".freeze
  KIND_LABELS = {
    "bug" => "bug",
    "expected" => "expectation",
    "suggestion" => "suggestion"
  }.freeze

  # Raised when no token is configured. Distinct from a failure, because the fix
  # is an env var rather than a retry: the popup says so instead of showing a
  # connection error.
  class Unconfigured < StandardError; end

  # GitHub said no, or the request never landed. The message is what the
  # operator reads, so it carries GitHub's own words rather than a status code.
  class Error < StandardError; end

  Result = Struct.new(:number, :url, :title, keyword_init: true)

  module_function

  def configured?
    token.present?
  end

  def token
    ENV["CHOPSHOP_GITHUB_TOKEN"].to_s.strip.presence
  end

  def repo
    ENV["CHOPSHOP_GITHUB_REPO"].to_s.strip.presence || "geeeze/chopshop-studio"
  end

  # Create one issue. `title` and `body` are the caller's prose; `kind` is one of
  # KIND_LABELS' keys and only ever selects a label.
  #
  # Returns a Result. Raises Unconfigured or Error -- the controller turns
  # either into a message the operator reads, never a bare 500.
  def create(title:, body:, kind: "bug")
    raise Unconfigured, "CHOPSHOP_GITHUB_TOKEN is not set" unless configured?

    ensure_labels(kind)
    data = post("/repos/#{repo}/issues", {
                  title: title.to_s.strip,
                  body: body.to_s,
                  labels: labels_for(kind)
                })
    Result.new(number: data["number"], url: data["html_url"], title: data["title"])
  end

  def labels_for(kind)
    labels = [TRIAGE_LABEL]
    label = KIND_LABELS[kind.to_s]
    labels << label if label
    labels
  end

  # GitHub silently DROPS a label that does not exist rather than failing the
  # issue, so a report can file with no triage label at all and nobody notices
  # for a week. Create the label first; an existing one answers 422, which is
  # the success case here.
  def ensure_labels(kind)
    ([TRIAGE_LABEL] + KIND_LABELS.values).uniq.each do |name|
      post("/repos/#{repo}/labels",
           { name: name, color: label_color(name) },
           allow: [422])
    end
    # The caller's own kind label, if it is not one of the standard three.
    post("/repos/#{repo}/labels", { name: kind.to_s, color: "ededed" }, allow: [422]) if
      kind.present? && !KIND_LABELS.value?(kind.to_s)
  end

  # Triage red so an untriaged report is visible at a glance; the kinds take
  # neutral greys so they do not compete with it.
  def label_color(name)
    name == TRIAGE_LABEL ? "d93f0b" : "ededed"
  end

  # `allow` lists the status codes that are an expected answer rather than a
  # failure -- used only by the label pre-create, where 422 means "already
  # there".
  def post(path, body, allow: [])
    uri = URI.join(API, path)
    req = Net::HTTP::Post.new(uri)
    req["Accept"] = "application/vnd.github+json"
    req["Content-Type"] = "application/json"
    req["X-GitHub-Api-Version"] = "2022-11-28"
    req["Authorization"] = "Bearer #{token}"
    req["User-Agent"] = "chopshop-studio"
    req.body = JSON.generate(body)

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: TIMEOUT,
                                                        read_timeout: TIMEOUT) do |http|
      http.request(req)
    end
    return {} if allow.include?(res.code.to_i)

    parsed = begin
      JSON.parse(res.body.to_s)
    rescue JSON::ParserError
      {}
    end
    return parsed if res.is_a?(Net::HTTPSuccess)

    raise Error, describe(res, parsed)
  end

  # GitHub's own message when it has one -- it is written for a human and says
  # which field it refused -- and the status alone when it does not.
  def describe(res, parsed)
    message = parsed["message"] || parsed["errors"].to_s
    message.present? ? "GitHub #{res.code}: #{message}" : "GitHub #{res.code} #{res.message}"
  end
end
