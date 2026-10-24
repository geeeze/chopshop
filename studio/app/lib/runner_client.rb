# Thin HTTP client for the chopshop runner contract (docs/runner-contract.md).
# Uses only Ruby stdlib (net/http, json) so the app runs with the default bundle.
require "net/http"
require "json"

module RunnerClient
  TIMEOUT = 15

  # Jev is a live third-party model call: measured ~40s for a real manifest, so
  # it gets its own read timeout rather than the 15s every other call uses.
  JEV_READ_TIMEOUT = 150

  # An archive is BUILT at request time on the runner rather than stored, so it
  # is the one read that can legitimately take half a minute. Named here because
  # a proof's dataset package is built the same way, and one number in one place
  # is the only way the two cannot drift.
  ARCHIVE_READ_TIMEOUT = 120

  # The proof dataset package (the `.dataset.7z` of a proof's variants) is an
  # on-demand build exactly like the archive -- a dozen-plus derived rasters and
  # their vector twins, compressed on the runner while the caller waits -- so it
  # takes the archive's timeout rather than the 15s everything else uses.
  DATASET_READ_TIMEOUT = ARCHIVE_READ_TIMEOUT

  module_function

  # The studio's own upload store. Everything this app hands a runner is a file
  # in here (a stepped chain's output is stored back into it precisely so it can
  # be handed over), so this is the root the relative form is derived from.
  def uploads_root
    Rails.root.join("storage", "uploads").to_s
  end

  # A runner is handed the RELATIVE name of a stored upload, not an absolute
  # path through OUR filesystem.
  #
  # An absolute path is a claim about the CALLER's world, and the runner has no
  # way to check it: it maps the path through its own configured roots, so the
  # claim has to stay true forever. It stopped being true the day the studio was
  # containerised — it began sending /app/storage/uploads/... while the runner
  # still expected the host prefix — and EVERY trace job died with
  # "input is outside shared upload directory" and a file that was present,
  # correct, and mounted on both sides. A relative name says the only thing that
  # is actually true: "a file in the shared store".
  #
  # A path that is NOT under our upload root is passed through UNCHANGED rather
  # than reduced to its basename. Reducing would be guesswork: a foreign
  # /mnt/scratch/upload_x.png would silently become upload_x.png and could
  # resolve to a DIFFERENT file in the mount. Unchanged, the runner resolves it
  # against its roots or refuses it by name.
  def runner_input_path(path)
    given = path.to_s.strip
    return given if given.empty?

    root = uploads_root
    expanded = File.expand_path(given)
    return given unless expanded.start_with?(root + File::SEPARATOR)

    expanded[(root.length + 1)..]
  end

  # The `input_path` field of a /jobs body, in the form the contract prefers.
  # Applied here, in the ONE place every runner call goes through, rather than at
  # each call site: four sites doing it by hand is four chances to drift, which
  # is the whole failure this replaced.
  def normalize_input_path(body)
    return body unless body.is_a?(Hash)

    key = if body.key?(:input_path) then :input_path
          elsif body.key?("input_path") then "input_path"
          end
    return body if key.nil?

    given = body[key].to_s
    handed = runner_input_path(given)
    return body if handed == given

    body.merge(key => handed)
  end

  def post(url, body, read_timeout: TIMEOUT)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req["Authorization"] = "Bearer #{token}" if token
    req.body = JSON.generate(normalize_input_path(body))
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

  # --- a proof's training-set dataset --------------------------------------
  #
  # When a proof was run with the variants opt-in on, the runner writes a
  # SELF-CONTAINED dataset next to the proof: a directory per candidate stem
  # holding the derived copies, the contact sheet and the manifest, plus a 7z of
  # the lot. Two routes reach it, and they are the only two in this contract
  # with these shapes.

  # `<candidate_01.svg>` -> `<candidate_01>`: the manifest names every dataset
  # artifact after the candidate's STEM, not after the candidate file.
  def dataset_stem(candidate_file)
    File.basename(candidate_file.to_s).sub(/\.[^.\/]+\z/, "")
  end

  # One file out of a dataset directory. NAMED FOR THE SHAPE ON PURPOSE: this is
  # the only /files/ URL in the contract with FOUR path segments (the dataset
  # directory is the third), which is exactly the detail a future "tidy-up" of
  # the file routes would flatten.
  def dataset_file(job, candidate_file, name)
    "#{job.base_url}/files/#{job.runner_job_id}/" \
      "#{dataset_stem(candidate_file)}.dataset/#{name}"
  end

  # The whole dataset as one 7z, built on demand. The candidate file is what
  # identifies it -- the runner derives the stem itself -- so it travels as a
  # query parameter rather than as a path segment.
  def dataset_package(job, candidate_file)
    get_file("#{job.base_url}/jobs/#{job.runner_job_id}/dataset" \
             "?candidate=#{URI.encode_www_form_component(candidate_file.to_s)}",
             read_timeout: DATASET_READ_TIMEOUT)
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
