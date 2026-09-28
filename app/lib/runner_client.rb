# Thin HTTP client for the chopshop runner contract (docs/runner-contract.md).
# Uses only Ruby stdlib (net/http, json) so the app runs with the default bundle.
require "net/http"
require "json"

module RunnerClient
  TIMEOUT = 15

  # Jev is a live third-party model call: measured ~40s for a real manifest, so
  # it gets its own read timeout rather than the 15s every other call uses.
  JEV_READ_TIMEOUT = 150

  module_function

  def post(url, body, read_timeout: TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
    parse(res)
  rescue RunnerError
    raise
  rescue StandardError => e
    raise RunnerError, "runner connection failed: #{e.message}"
  end

  def get(url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.request(req)
    end
    parse(res)
  rescue RunnerError
    raise
  rescue StandardError => e
    raise RunnerError, "runner connection failed: #{e.message}"
  end

  # proxy a binary file from the runner (candidate SVG, proof PNG, PDF, 7z)
  def get_file(url, read_timeout: TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}" if token
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = read_timeout
      http.request(req)
    end
    { status: res.code.to_i, body: res.body,
      content_type: res["Content-Type"] }
  rescue RunnerError
    raise
  rescue StandardError => e
    # Same wrapping as get/post: without it a dead runner surfaces as a raw
    # Errno::ECONNREFUSED, so the file proxy answers 500 instead of its intended
    # 502 — once per thumbnail, on every page view.
    raise RunnerError, "runner connection failed: #{e.message}"
  end

  def delete(url)
    uri = URI(url)
    req = Net::HTTP::Delete.new(uri)
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
      http.request(req)
    end
    parse(res)
  rescue RunnerError
    raise
  rescue StandardError => e
    raise RunnerError, "runner connection failed: #{e.message}"
  end

  def health(base)
    get("#{base}/health")
  rescue StandardError => e
    { error: e.message }
  end

  def create_job(job)
    # Explicit braces around the body hash at every call site, not just here:
    # `post` takes a `read_timeout:` keyword, so a trailing bare `key: value`
    # list is parsed as KEYWORDS and the positional `body` goes missing
    # ("wrong number of arguments (given 1, expected 2)"). That silently broke
    # every caller the moment the keyword was added.
    post("#{job.base_url}/jobs",
         { name: job.name, source_kind: job.source_kind,
           input_path: job.input_path, spec: job.spec })
  end

  def get_job(job)
    get("#{job.base_url}/jobs/#{job.runner_job_id}")
  end

  def cancel_job(job)
    post("#{job.base_url}/jobs/#{job.runner_job_id}/cancel", {})
  end

  def delete_job(job)
    delete("#{job.base_url}/jobs/#{job.runner_job_id}")
  end

  def create_validation(job:, candidate_file:)
    post("#{job.base_url}/validations",
         { job_id: job.runner_job_id, candidate_file: candidate_file })
  end

  def get_validation(validation)
    job = validation.job
    get("#{job.base_url}/validations/#{validation.runner_validation_id}")
  end

  def ask_jev(validation)
    job = validation.job
    # A live TypeSafe call takes ~40s measured (3007 input tokens), so the
    # shared 15s read timeout would abort a call that is working fine — the
    # same reason get_file takes read_timeout: for the on-demand archive.
    #
    # The job and candidate ride along because the runner holds validations in
    # memory only: after a runner restart it has forgotten the validation id but
    # the manifest is still on disk, and this is what lets it answer anyway.
    post("#{job.base_url}/validations/#{validation.runner_validation_id}/jev",
         { job_id: job.runner_job_id, candidate_file: validation.file },
         read_timeout: JEV_READ_TIMEOUT)
  end

  def token
    ENV["RUNNER_TOKEN"].presence
  end

  def parse(res)
    body = res.body.to_s
    parsed = body.presence && JSON.parse(body)
    if res.is_a?(Net::HTTPSuccess)
      (parsed || {}).with_indifferent_access
    else
      raise RunnerError.new("runner #{res.code}: #{parsed&.fetch('error', body)}")
    end
  end

  class RunnerError < StandardError; end
end
