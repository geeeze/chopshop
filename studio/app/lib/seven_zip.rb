# The 7z binary the studio's archive builders shell out to, and the ONE place
# the "is 7z installed?" question is answered.
#
# Two surfaces pack a job's outputs into a 7z -- FluxArchive (a flux job's
# provenance bundle) and StudioArchive (a job whose deliverable the studio
# itself holds) -- and both need the same binary off the same PATH. A second
# copy of the PATH walk would be a second answer to one question, so it lives
# here and neither class keeps its own.
module SevenZip
  # In preference order; whichever is on PATH is used. Absent is a real state
  # (a slim image without p7zip), reported by the caller as Unavailable rather
  # than crashing the download action.
  NAMES = %w[7z 7za 7zr].freeze

  # The 7z to use, or nil when none of the names is on PATH.
  def self.binary
    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      NAMES.each do |name|
        candidate = File.join(dir, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
    end
    nil
  end
end
