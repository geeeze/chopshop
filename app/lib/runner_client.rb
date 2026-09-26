# Thin HTTP client for the chopshop runner contract (doc/runner-contract.md).
# Uses only Ruby stdlib (net/http, json) so the app runs with the default bundle.
require "net/http"
require "json"

module RunnerClient
  TIMEOUT = 15

  module_function

  def post(url, body)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(body)
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

  # proxy a binary file from the runner (candidate SVG, proof PNG, PDF)
  def get_file(url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}" if token
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT
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

  def health(base)
    get("#{base}/health")
  rescue StandardError => e
    { error: e.message }
  end

  def create_job(job)
    post("#{job.base_url}/jobs",
         name: job.name, source_kind: job.source_kind,
         input_path: job.input_path, spec: job.spec)
  end

  def get_job(job)
    get("#{job.base_url}/jobs/#{job.runner_job_id}")
  end

  def create_validation(job:, candidate_file:)
    post("#{job.base_url}/validations",
         job_id: job.runner_job_id, candidate_file: candidate_file)
  end

  def get_validation(validation)
    job = validation.job
    get("#{job.base_url}/validations/#{validation.runner_validation_id}")
  end

  def ask_jev(validation)
    job = validation.job
    post("#{job.base_url}/validations/#{validation.runner_validation_id}/jev", {})
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
