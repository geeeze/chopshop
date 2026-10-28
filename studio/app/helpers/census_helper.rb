# THE CENSUS LINE — the kb's right-aligned mono status line ("1004 records ·
# 8 classes"), backported (#10).
#
# One line, resolved in ONE place. A page states the scale of what it is
# looking at, and the numbers are the page's own: the projects list states how
# many projects its search found out of how many exist, and the workspace
# states the project's own runs, candidates and proofs. Nothing here re-derives
# a list's filters — the filtered count is the count the action already
# resolved for the list it rendered, so the line and the table under it cannot
# disagree.
#
# It renders a bare <span class="mono page-census"> and nothing around it, so
# the SLOT decides where it sits. The intended slot is the header's `.nav-side`
# (kb: `.status { margin-left: auto; font: 12px var(--mono) }`); that lives in
# the layout, which this change does not own, so the surfaces that own the line
# render it under their page head for now. Moving it is a one-line render in
# the layout, not a rewrite: the helper is the whole mechanism.
#
# A page with no scale to state renders nothing at all — an empty string, not
# "0 jobs" — so the line never becomes noise on a form or a login screen.
module CensusHelper
  # "214 jobs · 37 candidates · 12 projects", right-aligned, mono.
  def census_line
    parts = census_parts
    return "".html_safe if parts.blank?

    content_tag(:span, safe_join(parts, " · "), class: "mono page-census", id: "header-census")
  end

  private

  # The page CONTEXT decides what is counted. Adding a surface is one `when`
  # here plus one `census_line` call in that view — the format, the class and
  # the id stay identical everywhere.
  def census_parts
    case [ controller_name, action_name ]
    when %w[projects index] then projects_census_parts
    when %w[projects show]  then project_census_parts(@project) if @project
    end
  end

  # The Projects index — the app's root page, and the one place the operator
  # sees the whole workspace at once. A search states its own result ("3 of 12
  # projects") rather than the workspace total alone, because a narrowed list
  # whose census still read "12 projects" would describe a page it is not.
  def projects_census_parts
    total = Project.count
    projects = if @query.present? && @project_count
                 "#{number_with_delimiter(@project_count)} of #{count_label(total, 'project')}"
               else
                 count_label(total, "project")
               end
    [ projects, count_label(Job.count, "job"), count_label(Candidate.count, "candidate") ]
  end

  # The project workspace. Its own scale: the runs this project owns, and what
  # those runs have produced. When the run list is filtered, the census says so
  # in the same breath ("3 of 8 jobs") — the page is not lying about how many
  # runs the project has.
  def project_census_parts(project)
    total = @jobs_total || project.jobs.count
    jobs = if @state.present?
             "#{number_with_delimiter(@jobs_count || 0)} of #{count_label(total, 'job')}"
           else
             count_label(total, "job")
           end
    scope = project.jobs.select(:id)
    [ jobs,
      count_label(Candidate.where(job_id: scope).count, "candidate"),
      count_label(Validation.where(job_id: scope).count, "proof") ]
  end

  # One noun, pluralised and delimited: "1 job", "1,204 jobs". `pluralize`
  # alone does not group digits, and a six-figure count reads as a blur without
  # them.
  def count_label(count, noun)
    "#{number_with_delimiter(count.to_i)} #{noun}#{'s' unless count.to_i == 1}"
  end
end
