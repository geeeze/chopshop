# A compose step's document, in the shape `ComposeSpec.build` reads a composite.
#
# A compose step is a step list's studio-side operation: the studio, not a
# runner, builds the wire spec and inlines every layer's source (see
# `RunJob#run_compose_step`). The builder it uses is the SAME one a flattened
# composite uses — `ComposeSpec` — because a second builder for the step path
# would drift from the one that actually composes.
#
# That builder reads a composite (`.width`, `.height`, `.background`,
# `.palette`, `.paintable_layers`), and a step's document is JSON, not a row. So
# this is the adapter between the two: the composite's five readers, answered
# from the step's own document. Deliberately a value object with no behaviour
# beyond that — every rule about what a layer may be, and what a source resolves
# to, stays in ComposeSpec where it already lives and is already tested.
class ComposeDocument
  attr_reader :width, :height, :background, :palette, :layers

  def initialize(width:, height:, background: nil, palette: nil, layers: [])
    @width = width
    @height = height
    @background = background
    @palette = palette
    @layers = layers.is_a?(Array) ? layers : []
  end

  # Everything a compose would paint. A step's document has no visibility flag
  # (a layer that should not be composed is left out of the list), so this is
  # the list as given — the same answer `Composite#paintable_layers` gives for a
  # composite whose layers are all visible.
  def paintable_layers
    layers.select { |layer| layer.is_a?(Hash) }
  end
end
