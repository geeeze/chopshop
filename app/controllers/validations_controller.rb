class ValidationsController < ApplicationController
  before_action :require_login

  def create
    job = Job.find(params[:job_id])
    if job.state != "done"
      redirect_to job, alert: "Front half has not finished yet."
      return
    end
    file = params[:candidate_file].to_s
    candidate = job.candidates.find_by!(file: file)

    validation = job.validations.create!(candidate: candidate, file: file,
                                         state: "pending")
    resp = RunnerClient.create_validation(job: job, candidate_file: file)
    validation.update!(runner_validation_id: resp[:id], state: "running")
    redirect_to validation
  rescue RunnerClient::RunnerError => e
    validation&.update(state: "error", error: e.message, finished_at: Time.current)
    redirect_to job, alert: "Runner rejected validation: #{e.message}"
  rescue StandardError => e
    # The row is created ABOVE, before the runner call, so ANY failure between
    # there and the redirect leaves it "pending" forever — a phantom queued run
    # the operator never started and that will never execute. That is exactly
    # what a stray ArgumentError (not a RunnerClient::RunnerError) did: five
    # orphan rows, four of them from the operator's own retries. Mark the row
    # terminal FIRST, then let the error surface as a 500.
    validation&.update(state: "error", error: "#{e.class}: #{e.message}",
                       finished_at: Time.current)
    raise
  end

  def show
    @validation = Validation.find(params[:id])
    @job = @validation.job
    @validation.sync_from_runner! if %w[pending running].include?(@validation.state)

    respond_to do |format|
      format.html
      format.json do
        render json: { done: !%w[pending running].include?(@validation.state) }
      end
    end
  end

  def refresh
    @validation = Validation.find(params[:id])
    @validation.sync_from_runner!
    redirect_to @validation
  end

  # Ask Jev (TypeSafe System One) the four advisory questions about this
  # validation's manifest. The runner proxies to api.typesafe.ai with the
  # operator's JEV_API_KEY held on the runner side; the mock runner answers
  # from a canned set.
  #
  # The title row calls this with format: :json and shows the reply in a popup,
  # so the same action serves both the popup and a plain form post that
  # redirects (which is still what a no-JS client gets).
  def ask_jev
    validation = Validation.find(params[:id])
    if validation.state != "done"
      respond_to do |format|
        format.json { render json: { error: "Validation not finished." }, status: :unprocessable_entity }
        format.any { redirect_to validation, alert: "Validation not finished." }
      end
      return
    end
    resp = RunnerClient.ask_jev(validation)
    validation.update!(jev_answers: resp[:answers],
                       jev_meta: { model: resp[:model],
                                  endpoint: resp[:endpoint],
                                  latency_ms: resp[:latency_ms],
                                  verdict: resp[:verdict] })
    respond_to do |format|
      format.json do
        render json: {
          answers: resp[:answers],
          meta: validation.jev_meta,
          cards: resp[:answers].to_h.map { |q, a| card = jev_answer_view(a)
                                           { question: jev_words(q),
                                             value: card[:value],
                                             note: card[:note],
                                             confidence: card[:confidence] } }
        }
      end
      format.any do
        redirect_to validation, notice: "Jev answered #{resp[:answers].to_h.size} questions."
      end
    end
  rescue RunnerClient::RunnerError => e
    # The runner separates "not configured here" (503 with the reason) from a
    # real call failure, so the alert can say which without guessing.
    respond_to do |format|
      format.json { render json: { error: e.message }, status: :bad_gateway }
      format.any { redirect_to validation, alert: "Jev call failed: #{e.message}" }
    end
  end
end
