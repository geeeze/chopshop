require "test_helper"

# The Run Job artwork field used to be mostly filename and size: the image was a
# fixed 96x96 and `.upload-thumb-meta` was flex: 1 1 auto, so the caption took
# the whole rest of the row and the raster you came to look at was the smallest
# thing on the line. The preview is now the content and the caption is capped.
#
# Measured in headless Chromium at a 1100px row, field 796x115:
#   art aspect   element box   art fills   meta
#   2:1          192.0x96.0    100%        160.0
#   1:1           96.0x96.0    100%        160.0
#   1:2           48.0x96.0    100%        160.0
#   6:1          576.0x96.0    100%        160.0
#   row height 115.0px throughout -- the tile/preview swap still does not move
#   the buttons.
class ArtworkPreviewFieldTest < ActionDispatch::IntegrationTest
  def css_without_comments
    Rails.root.join("app/assets/stylesheets/application.css").read
         .gsub(%r{/\*.*?\*/}m, "")
  end

  test "the preview fills the field and the caption is capped" do
    css = css_without_comments
    img = css[/\.upload-thumb img \{[^}]*\}/m]
    refute_nil img, ".upload-thumb img must exist"

    # flex-grow: 0 is the load-bearing part. Growing the ELEMENT to fill the
    # field and letterboxing the art inside it left a square raster at 96px
    # inside a 603px checkerboard -- the same dead space, just patterned.
    assert_match(/flex: 0 1 auto/, img,
      "0 = hug the art; 1 = stretch the element and letterbox it")
    assert_match(/flex-shrink|flex: 0 1 auto/, img)
    assert_match(/height: 96px/, img, "the 96px band is what keeps the row height fixed")
    assert_match(/width: auto/, img, "auto, not a fixed 96px square")
    refute_match(/width: 96px/, img, "the old fixed 96x96 box is gone")
    assert_match(/max-width: 100%/, img, "an extreme panorama must shrink into the row")
    assert_match(/object-fit: contain/, img)

    meta = css[/\.upload-thumb-meta \{[^}]*\}/m]
    refute_nil meta
    assert_match(/flex: 0 0 auto/, meta,
      "the caption must stop growing -- flex: 1 1 auto is what ate the field")
    assert_match(/max-width: 10rem/, meta)
    refute_match(/max-width: none/, meta)
  end

  test "the art and its caption are centred in the leftover field" do
    css = css_without_comments
    thumb = css[/\.upload-thumb \{[^}]*\}/m]
    refute_nil thumb
    assert_match(/justify-content: center/, thumb,
      "the art no longer fills the field, so the pair centres in what is left")
  end

  test "the preview still fills the row without growing it" do
    css = css_without_comments
    thumb = css[/\.upload-thumb \{[^}]*\}/m]
    assert_match(/flex: 1 1 auto/, thumb,
      "the FIELD is what fills the row, so the tile->preview swap does not " \
      "change the row's height and nudge the buttons")
    assert_match(/min-width: 0/, thumb)

    tile = css[/\.upload-tile \{[^}]*\}/m]
    assert_match(/height: 115px/, tile, "unchanged: the band the preview matches")
  end

  test "the preview markup keeps the remove control and the caption" do
    view = Rails.root.join("app/views/jobs/new.html.erb").read
    assert_match(/id="uploadThumb"/, view)
    assert_match(/id="thumbImg"/, view, "the preview image")
    assert_match(/id="thumbMeta"/, view, "the filename and size caption")
    assert_match(/id="thumbRemove"/, view, "the remove control must survive")
  end
end
