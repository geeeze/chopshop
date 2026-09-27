require "test_helper"
require "zlib"
require "tmpdir"

# Pins the upload door: PNG/JPEG only, content sniffed by magic bytes (not the
# extension), and a hard 50MB ceiling. The runner reads these paths, so what
# gets past here decides what the pipeline ever sees.
class UploadCapsTest < ActionDispatch::IntegrationTest
  MODERN_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 " \
              "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36".freeze

  def sign_in
    original = ENV["CHOPSHOP_PASSWORD"]
    ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" },
                     headers: { "User-Agent" => MODERN_UA }
  ensure
    ENV["CHOPSHOP_PASSWORD"] = original
  end

  # The smallest real PNG: 4x4 opaque red, so the magic-byte check sees a PNG.
  def write_tiny_png(path)
    raw = ("\x00" + ("\xff\x00\x00\xff" * 4)).b * 4
    png = "\x89PNG\r\n\x1a\n".b +
          png_chunk("IHDR", [ 4, 4, 8, 6, 0, 0, 0 ].pack("NNCCCCC")) +
          png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
          png_chunk("IEND", "".b)
    File.binwrite(path, png)
    path
  end

  def png_chunk(type, data)
    [ data.bytesize ].pack("N") + type + data +
      [ Zlib.crc32(type + data) & 0xffffffff ].pack("N")
  end

  test "a real PNG is accepted and stored under storage/uploads" do
    stored = nil
    Dir.mktmpdir do |dir|
      source = write_tiny_png(File.join(dir, "ok.png"))
      sign_in
      post upload_jobs_path,
           params: { file: Rack::Test::UploadedFile.new(source, "image/png") },
           headers: { "User-Agent" => MODERN_UA }

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal %w[path preview_url name size].sort, body.keys.sort
      assert_equal "ok.png", body["name"]
      assert body["path"].end_with?(".png")
      stored = body["path"]
    end
  ensure
    File.delete(stored) if stored && File.exist?(stored)
  end

  test "a non-image extension is rejected before the file is read" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "notes.txt")
      File.write(source, "not an image")
      sign_in
      post upload_jobs_path,
           params: { file: Rack::Test::UploadedFile.new(source, "text/plain") },
           headers: { "User-Agent" => MODERN_UA }

      assert_response :redirect
      assert_match(/Only PNG or JPEG/, flash[:alert].to_s)
    end
  end

  test "a .png whose bytes are not a PNG is rejected by the magic-byte check" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "fake.png")
      File.binwrite(source, "GIF89a totally not a png".b)
      sign_in
      post upload_jobs_path,
           params: { file: Rack::Test::UploadedFile.new(source, "image/png") },
           headers: { "User-Agent" => MODERN_UA }

      assert_response :redirect
      assert_match(/doesn't look like PNG or JPEG/, flash[:alert].to_s)
    end
  end

  test "a PNG over 50MB is refused" do
    Dir.mktmpdir do |dir|
      source = File.join(dir, "huge.png")
      # Sparse 51MB file: cheap on disk, still reports > 50MB to File.size.
      File.open(source, "wb") { |f| f.truncate(51 * 1024 * 1024) }
      sign_in
      post upload_jobs_path,
           params: { file: Rack::Test::UploadedFile.new(source, "image/png") },
           headers: { "User-Agent" => MODERN_UA }

      assert_response :redirect
      assert_match(/50MB limit/, flash[:alert].to_s)
      assert_empty Dir.glob(Rails.root.join("storage", "uploads", "upload_*"))
                   .select { |p| File.size(p) > 50 * 1024 * 1024 },
                   "an over-cap upload must not be left in storage/uploads"
    end
  end
end
