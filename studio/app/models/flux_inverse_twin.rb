require "chunky_png"
require "securerandom"

# The colour-inverted twin of a generated raster, built HERE rather than asked
# for.
#
# A TRACE-mode flux job hands its raster to a pipeline runner, and the runner
# contract's prep stage produces source.inverse.png — a derived artefact the
# studio only proxies through the runner. A RASTER-ONLY flux job stops at the
# raster: there is no runner, so nothing produces a twin, and the job page's
# source/inverse pair would be one tile and one 404. The twin is therefore made
# from the raster the studio already stored, at completion time.
#
# The inversion is the same one the mock runner applies to a colour (a per-pixel
# 255 - x on the three colour channels, alpha untouched) and the same one the
# image on screen shows: it is a view of the SAME raster, not a re-trace.
#
# Pure Ruby through chunky_png, deliberately: the box has no ImageMagick and
# this app has no other image dependency, so a gem with no native extension is
# the whole reason a twin can be produced in-process at all.
#
# A raster chunky_png cannot decode (16-bit or interlaced PNG, say) yields nil
# rather than raising: the twin is a DERIVED artefact, and a job whose raster is
# unusual is still a complete job. Its tile self-hides on error.
class FluxInverseTwin
  # Every name this class reads or writes must match. The raster name arrives
  # from the job's spec (user-editable text) and must never be able to resolve
  # outside storage/uploads.
  NAME_RE = /\A[\w.\-]+\z/.freeze

  # The stored twin's prefix, which is also what marks a file as this class's
  # product rather than a runner artefact or an operator upload.
  PREFIX = "flux_inverse_".freeze

  # The one alpha-preserving RGB flip: chunky_png packs a pixel as 0xRRGGBBAA,
  # so XOR-ing the top three bytes inverts every colour channel and leaves the
  # alpha byte alone. Integer work on the pixel array, not a per-pixel method
  # call — a 1024x1024 raster is a million pixels.
  RGB_MASK = 0xFFFFFF00

  class << self
    # Invert `source_basename` (a file in storage/uploads) and store the twin
    # beside it. Returns the stored BASENAME, or nil when there is nothing to
    # invert or the PNG could not be read.
    def write(source_basename)
      source = uploads.join(source_basename.to_s)
      return nil unless NAME_RE.match?(source_basename.to_s) && source.file?

      dest = uploads.join("#{PREFIX}#{SecureRandom.hex(6)}.png")
      File.binwrite(dest, invert(File.binread(source)))
      File.basename(dest.to_s)
    rescue ChunkyPNG::Exception, Zlib::Error => e
      Rails.logger.warn(
        "flux inverse twin: #{File.basename(source.to_s)} — #{e.class}: #{e.message}"
      )
      nil
    end

    # The inverted PNG bytes for a PNG's bytes.
    def invert(png_bytes)
      image = ChunkyPNG::Image.from_blob(png_bytes)
      inverted = image.pixels.map { |px| px ^ RGB_MASK }.pack("N*")
      ChunkyPNG::Canvas.from_rgba_stream(image.width, image.height, inverted).to_blob
    end

    def uploads
      Rails.root.join("storage", "uploads")
    end
  end
end
