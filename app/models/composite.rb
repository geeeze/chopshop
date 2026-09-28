# A composite the operator assembles from layers, and then hands to a job as its
# source raster.
#
# Layers are NOT files. Each layer references where its pixels came from (a
# scrapbook item, an upload, or a blank slate) plus the placement that makes it
# a component — x/y/w/h, opacity, hue. The composite is flattened to a single PNG
# only at the moment it becomes a job's artwork, so the parts stay editable for
# as long as the composite exists. That is the whole point: an operator builds a
# piece, changes their mind about a layer's position, and re-runs without
# re-importing anything.
#
# `owner` is the signed-in user's handle, stamped at creation and used to scope
# every read (see Owned).
class Composite < ActiveRecord::Base
  include Owned

  validates :name, presence: true
  validates :width, :height, numericality: { greater_than: 0 }

  # Sensible defaults for a print-area composite: a 300dpi-ish canvas the size of
  # a chest panel, transparent background, layers painted back-to-front.
  DEFAULT_WIDTH = 3000
  DEFAULT_HEIGHT = 3000

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def layers
    raw = read_attribute(:layers)
    raw.is_a?(Array) ? raw : []
  end

  # Layers in paint order, bottom first. Rendering walks them in this order, so
  # index 0 is the backdrop and the last entry sits on top.
  def ordered_layers
    layers.each_with_index.sort_by { |l, i| [l["z"].to_i, i] }.map(&:first)
  end

  def blank_layer_defaults
    { "visible" => true, "opacity" => 1.0, "hue" => 0 }
  end
end
