# A composite the operator assembles from layers, and then hands to a job as its
# source artwork.
#
# Layers are NOT files. Each layer references where its pixels came from (a
# scrapbook item, an upload, or a blank slate) plus the placement that makes it
# a component — x/y/w/h, opacity, hue — and a KIND saying how it is composed.
# The composite is flattened to a single artefact only at the moment it becomes
# a job's artwork, so the parts stay editable for as long as the composite
# exists. That is the whole point: an operator builds a piece, changes their mind
# about a layer's position, and re-runs without re-importing anything.
#
# A layer's `kind` is "raster" (pixels: the browser drew them, the flatten posts
# a PNG) or "vector" (an SVG the compose operation places as VECTORS, so a traced
# source is never rasterised and re-traced). A layer with no `kind` is RASTER:
# every composite stored before the field existed must keep compositing exactly
# as it did.
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

  # The two ways a layer can be composed. Named constants, not literals, because
  # the model, the controller, the compose spec and the recipe endpoint all have
  # to agree on the same two words.
  KIND_RASTER = "raster".freeze
  KIND_VECTOR = "vector".freeze

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

  # A layer's kind, defaulting to raster. Deliberately tolerant of anything the
  # stored JSON holds: the column is free-form, and an unknown word must compose
  # as pixels rather than crash a flatten.
  def layer_kind_of(layer)
    self.class.layer_kind(layer)
  end

  def self.layer_kind(layer)
    return KIND_VECTOR if layer.is_a?(Hash) && layer["kind"].to_s == KIND_VECTOR

    KIND_RASTER
  end

  # The layers a compose would actually paint: an invisible layer is not part of
  # the spec at all, because the wire contract has no `visible` field — hiding a
  # layer means not sending it.
  def paintable_layers
    ordered_layers.reject { |l| l["visible"] == false }
  end

  # The vector layers in paint order — the ones that make this composite a
  # COMPOSE rather than a raster flatten.
  def vector_layers
    paintable_layers.select { |l| layer_kind_of(l) == KIND_VECTOR }
  end

  def vector?
    vector_layers.any?
  end
  alias has_vector_layers? vector?

  # True when there is something to paint and every paintable layer is a vector.
  # An empty composite is NOT "all vector": nothing to compose is not a vector
  # composite, and answering true there would route an empty flatten at a runner.
  def all_vector?
    paintables = paintable_layers
    paintables.any? && paintables.all? { |l| layer_kind_of(l) == KIND_VECTOR }
  end

  # The colours the compose operation may draw with, if this composite carries
  # one. The builder's own palette field sets it; a composite with no palette
  # answers `[]`, which ComposeSpec turns into an omitted key (the wire contract
  # makes `palette` optional, so "none" and "empty" must mean the same thing).
  # Read through `has_attribute?` so a database that predates the column still
  # builds a spec rather than raising on an unknown attribute.
  def palette
    return [] unless has_attribute?(:palette)

    value = read_attribute(:palette)
    return [] if value.blank?

    value.is_a?(Array) ? value.map(&:to_s) : [value.to_s]
  end

  def blank_layer_defaults
    { "visible" => true, "opacity" => 1.0, "hue" => 0, "kind" => KIND_RASTER }
  end

  # #composite-layout-metrics — how this composite's pieces SIT, which is a
  # different question from what they are. Read from CompositeLayout, the same
  # scorer the template endpoint and the telemetry aggregate use, so the
  # builder's readout, the agent's endpoint and the ML signal cannot disagree
  # about one arrangement.
  def layout_metrics
    CompositeLayout.metrics(layers: layers, width: width.presence || DEFAULT_WIDTH,
                            height: height.presence || DEFAULT_HEIGHT)
  end

  # The worst unsatisfied constraint scalar, in composite pixels. Zero means
  # every relation this composite declares currently holds.
  def layout_residual
    CompositeLayout.residual(layers: layers, width: width.presence || DEFAULT_WIDTH,
                             height: height.presence || DEFAULT_HEIGHT)
  end

  # Every constraint this composite declares, flattened for reporting: an agent
  # reading /composite/:id/metrics should not have to walk the layer list to
  # find out what the composite PROMISES.
  def layout_links
    layers.flat_map do |l|
      CompositeLayout.links(l).map do |k|
        { "layer" => l["key"], "name" => l["name"], "how" => k["how"], "to" => k["to"],
          "doc" => CompositeLayout::CONSTRAINT_DOCS[k["how"]] }
      end
    end
  end
end
