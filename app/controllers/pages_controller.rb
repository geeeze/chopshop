class PagesController < ApplicationController
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

  # ??? — basic info about the shop.
  def about
  end
end
