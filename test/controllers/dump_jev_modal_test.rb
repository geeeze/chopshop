require "test_helper"

# Temporary probe. The critical bit: aether.js is injected as a real
# <script type="module"> so it is DEFERRED, exactly as javascript_importmap_tags
# emits it. That is the ordering the old code got wrong, and it cannot be
# reproduced by stubbing window.CsModal the way the previous probe did -- that
# stub is what let the bug through.
class DumpJevModalTest < ActionDispatch::IntegrationTest
  test "dump" do
    o = ENV["CHOPSHOP_PASSWORD"]; ENV["CHOPSHOP_PASSWORD"] = "test-password"
    post login_path, params: { password: "test-password" }
    ENV["CHOPSHOP_PASSWORD"] = o
    get jev_path
    assert_response :success

    body = response.body
    aether = File.read(Rails.root.join("app/javascript/aether.js"))
    probe = File.read("/home/unodos/.hermes/cache/scratch/jev2_tpl.html")
    out = probe.sub("__AETHER__", aether.gsub("</script", "<\\/script"))
              .sub("__CSS__", (Rails.root.join("app/assets/stylesheets/application.css").read +
                               Rails.root.join("app/assets/stylesheets/palette-tool.css").read)
                              .gsub("</style", "<\\/style"))
              .sub("__BODY__", body)
    File.write("/home/unodos/.hermes/cache/scratch/jev2.html", out)
  end
end
