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
    validation&.update(state: "error", error: e.message)
    redirect_to job, alert: "Runner rejected validation: #{e.message}"
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
  # validation's manifest. Mock runner answers instantly; live runner proxies
  # to api.typesafe.ai with TYPESAFE_API_KEY held on the runner side.
  def ask_jev
    validation = Validation.find(params[:id])
    if validation.state != "done"
      redirect_to validation, alert: "Validation not finished."
      return
    end
    resp = RunnerClient.ask_jev(validation)
    validation.update!(jev_answers: resp[:answers],
                       jev_meta: { model: resp[:model],
                                  endpoint: resp[:endpoint],
                                  latency_ms: resp[:latency_ms] })
    redirect_to validation
  rescue RunnerClient::RunnerError => e
    redirect_to validation, alert: "Jev call failed: #{e.message}"
  end
end
