require "test_helper"
require "securerandom"

# The inverse twin of a raster-only flux job's generated PNG.
#
# A raster-only job has no pipeline runner, so there is no prep stage to write
# source.inverse.png and the studio makes the twin itself. It has to be a REAL,
# viewable PNG — the job page shows it as an image and the download bundle ships
# it — so what is pinned here is the pixel maths (255 - x on the three colour
# channels, alpha untouched), the file's PNG-ness, and the two ways a twin is
# legitimately absent.
#
# The mock runner's own invert_hex() is the same maths on a colour, and the
# tile's dashed border is the same claim on screen: the twin is a view of the
# SAME raster, not a second generation.
class FluxInverseTwinTest < ActiveSupport::TestCase
  def uploads
    path = Rails.root.join("storage", "uploads")
    path.mkpath
    path
  end

  def twins
    Dir[uploads.join("flux_inverse_*.png")].sort
  end

  # A real 4x4 PNG with known pixels, so the flip is checkable corner to corner:
  # black, a mid triplet, an alpha pixel and a wall of background.
  def source_png
    image = ChunkyPNG::Image.new(4, 4, ChunkyPNG::Color.rgb(10, 20, 30))
    image[0, 0] = ChunkyPNG::Color.rgb(0, 0, 0)
    image[1, 0] = ChunkyPNG::Color.rgb(255, 128, 1)
    image[2, 0] = ChunkyPNG::Color.rgba(200, 100, 50, 128)
    image.to_blob
  end

  def rgb(pixel)
    [ ChunkyPNG::Color.r(pixel), ChunkyPNG::Color.g(pixel), ChunkyPNG::Color.b(pixel) ]
  end

  def with_source
    uploads.mkpath
    path = uploads.join("flux_src_#{SecureRandom.hex(4)}.png")
    File.binwrite(path, source_png)
    yield path
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def cleanup
    # UploadsSandboxHelper: only what THIS test wrote. A bare glob here is a
    # delete in the LIVE uploads directory.
    cleanup_test_uploads(/\Aflux_inverse_/)
    cleanup_test_uploads(/\Aflux_src_/)
  end

  test "the twin is a real PNG with every colour channel inverted and alpha kept" do
    cleanup
    begin
      with_source do |source|
        name = FluxInverseTwin.write(File.basename(source.to_s))
        refute_nil name, "the twin was written"
        assert_match(/\Aflux_inverse_[0-9a-f]+\.png\z/, name)

        twin = uploads.join(name)
        assert twin.file?, "the twin is stored beside the raster"
        assert_equal "\x89PNG\r\n\x1a\n".b, twin.binread(8),
          "the twin is a PNG, not the raw bytes of something else"

        out = ChunkyPNG::Image.from_file(twin.to_s)
        assert_equal 4, out.width
        assert_equal 4, out.height

        assert_equal [ 255, 255, 255 ], rgb(out[0, 0]), "black inverts to white"
        assert_equal [ 0, 127, 254 ], rgb(out[1, 0])
        assert_equal [ 55, 155, 205 ], rgb(out[2, 0]), "a mid triplet flips per channel"
        assert_equal [ 245, 235, 225 ], rgb(out[1, 1]), "the background flips too"

        assert_equal 128, ChunkyPNG::Color.a(out[2, 0]), "alpha is untouched"
        assert_equal 255, ChunkyPNG::Color.a(out[0, 0])
      end
    ensure
      cleanup
    end
  end

  test "a twin left next to the raster is named, never overwritten" do
    cleanup
    begin
      with_source do |source|
        first = FluxInverseTwin.write(File.basename(source.to_s))
        second = FluxInverseTwin.write(File.basename(source.to_s))
        refute_equal first, second, "two inversions are two files"
        assert_equal 2, twins.size
      end
    ensure
      cleanup
    end
  end

  test "a name that is not a stored upload yields no twin at all" do
    cleanup
    before = twins

    # The name arrives from the job's spec, which is editable text.
    assert_nil FluxInverseTwin.write("../../../../etc/passwd")
    assert_nil FluxInverseTwin.write("/etc/passwd")
    assert_nil FluxInverseTwin.write("sub/dir.png")
    assert_nil FluxInverseTwin.write("not_stored_#{SecureRandom.hex(4)}.png")
    assert_nil FluxInverseTwin.write(nil)

    assert_equal before, twins, "nothing was written for any of those"
  end

  test "a raster the PNG decoder cannot read yields no twin, not an exception" do
    cleanup
    begin
      uploads.mkpath
      broken = uploads.join("flux_src_broken.png")
      File.binwrite(broken, "\x89PNG\r\n\x1a\nnot really a png at all".b)
      before = twins

      assert_nil FluxInverseTwin.write(File.basename(broken.to_s)),
        "a derived artefact is absent, not a job-killing crash"
      assert_equal before, twins
    ensure
      broken&.delete if broken&.exist?
      cleanup
    end
  end
end
