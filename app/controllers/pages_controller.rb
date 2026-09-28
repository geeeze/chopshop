class PagesController < ApplicationController
  # These pages are ungated by omission and therefore PUBLIC: `/about`, `/json`
  # and `/jev` render without a session, while Jobs and Validations both declare
  # `before_action :require_login`. The spec builder is the important one — it
  # documents the job contract and the palette library, and `/json/use` stashes a
  # spec draft into the session. A password gate that leaves these open is not a
  # gate. Deliberately explicit rather than inherited so a future page is gated
  # by default: add new public pages to the `except:` list with a reason.
  before_action :require_login, except: []

  # JSON — the spec (job contract) builder. Docs live in the view; the
  # generated JSON is assembled client-side and applied via #apply_spec.
  def schema
    # The predefined palettes come from the pipeline (config/palettes.json,
    # kept in sync by bin/sync-palettes) — read-only reference next to the
    # spec's own palette list.
    @palette_library = PaletteLibrary.load
  end

  # Store a validated spec draft in the session and hand it to the new-run
  # form as its default textarea content.
  def apply_spec
    raw = params[:spec].to_s
    begin
      parsed = JSON.parse(raw)
    rescue JSON::ParserError
      parsed = nil
    end
    if parsed.is_a?(Hash)
      session[:spec_draft] = JSON.pretty_generate(parsed)
      redirect_to new_job_path, notice: "Spec loaded into the new-run form."
    else
      redirect_to json_path, alert: "That didn't parse as a JSON object."
    end
  end

  # JEV — the decision sidecar contract: the four questions Jev is asked,
  # the confidence rules, and the verdict the studio renders.
  def jev
  end

  # FLUX — the generation service's configuration and model registry, mirrored
  # from chopshop-flux's config.py and models.py. Read-only by design: the page
  # shows what the service would be started with, validates a request the way the
  # service does, and hands you the env block and JSON to copy. It does not run
  # the service and cannot set its environment.
  def flux
  end

  # PLOT — chopshop-plot's serve surface and contract, mirrored from that repo's
  # config.py, spec.py and metrics.py. The same read-only rule as FLUX: it shows
  # what the service would be started with, which charts and metric fields the
  # contract accepts, and the runner this studio files it under — it does not run
  # the service and cannot set its environment.
  def plot
    # The runners this deployment actually files as plot runners, so the page
    # reports the real map (env-driven) rather than the default it documents.
    # Empty is a normal state: the page then says so and the settings stand alone.
    @plot_runners = Job.plot_runners.to_h { |label| [label, Job.runners[label]] }
  end

  # ??? — basic info about the shop.
  def about
  end
end
