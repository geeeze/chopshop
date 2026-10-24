require "test_helper"

# The DISPLAY mapping for a proof's name, in BOTH live spellings of a candidate.
#
# A runner stamps the JOB'S NAME into what it publishes -- a job called "jobby"
# yields jobby-candidate-06.svg and proves it as jobby-proof-06.png -- while a
# job directory published before that carries the pipeline's own
# candidate_06.svg / candidate_06.proof.png. One method decides what a proof is
# CALLED (ApplicationHelper#proof_name) and every page that prints or links a
# proof reads it, so a job-named run whose proof rendered as
# "jobby-candidate-06.svg" would mislabel the thing it links to.
class ProofNamingTest < ActiveSupport::TestCase
  include ApplicationHelper

  test "a proof's name follows the candidate it was made from" do
    assert_equal "proof_06.svg", proof_name("candidate_06.svg")
    assert_equal "proof_06", proof_label("candidate_06.svg")
  end

  test "a job-named candidate keeps the job's name and swaps candidate for proof" do
    assert_equal "jobby-proof-06.svg", proof_name("jobby-candidate-06.svg")
    assert_equal "jobby-proof-06", proof_label("jobby-candidate-06.svg")
  end

  test "a name that is already a proof is left alone" do
    assert_equal "jobby-proof-06.png", proof_name("jobby-proof-06.png")
    assert_equal "proof_06.png", proof_name("proof_06.png")
  end

  test "the label a page prints matches the PNG the runner publishes" do
    # The mapping is the SAME on both sides of the wire: the runner publishes
    # <job>-proof-06.png for <job>-candidate-06.svg. If these ever disagree the
    # page links a filename the runner has nothing at.
    assert_equal "jobby-proof-06.png", "#{proof_label('jobby-candidate-06.svg')}.png"
    assert_equal "proof_06.png", "#{proof_label('candidate_06.svg')}.png"
  end

  # A favourite is classified from the runner's own filename (never the client's
  # word for it), and BOTH spellings must land in their kind: a star saved off a
  # named run otherwise shows in the sidebar as an anonymous "upload".
  def kind_for(name)
    ScrapbooksController.new.send(:kind_from_name, name)
  end

  test "the scrapbook classifies candidates and proofs in either spelling" do
    assert_equal "candidate", kind_for("candidate_06.svg")
    assert_equal "candidate", kind_for("jobby-candidate-06.svg")
    assert_equal "proof",     kind_for("candidate_06.proof.png")
    assert_equal "proof",     kind_for("jobby-proof-06.png")
  end

  test "the neighbouring kinds keep working, and a print PDF is not a proof PNG" do
    assert_equal "source", kind_for("source.png")
    assert_equal "invert", kind_for("source.inverse.png")
    assert_equal "flux",   kind_for("flux_ab12cd34ef56.png")

    # The print PDF is the same proof, but the kind names the PNG the sidebar
    # shows -- a PDF is not renderable in the tile, so it stays an upload.
    assert_equal "upload", kind_for("jobby-proof-06.pdf")
    assert_equal "upload", kind_for("jobby-proof-06.manifest.json")
  end
end
