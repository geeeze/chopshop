# The shop's predefined colour palettes.
#
# chopshop-svg's scripts/palettes.json is the single source of truth for these
# colours (the Chopshop-Aided-Design library); `bin/sync-palettes` copies it
# verbatim into config/. This class only ever reads that copy, so the JSON page
# still renders when the pipeline checkout is nowhere near — a missing or
# malformed file degrades to "no palettes", never a 500.
class PaletteLibrary
  HEX = /\A#[0-9a-fA-F]{6}\z/

  # colours are ordered background-first then by role importance, so a colour's
  # role caption is positional: index i takes the i-th key of the file's _roles.
  Colour = Struct.new(:hex, :role, keyword_init: true)

  Palette = Struct.new(:id, :name, :note, :background, :colours, :map, keyword_init: true)

  Library = Struct.new(:version, :roles, :palettes, keyword_init: true) do
    def any?
      palettes.any?
    end
  end

  EMPTY = Library.new(version: nil, roles: [], palettes: []).freeze

  class << self
    def path
      Rails.root.join("config", "palettes.json")
    end

    # Where a sync pulls FROM: the sibling pipeline checkout. Overridable for
    # the layouts where it is not a sibling (jail, container, separate clone).
    def source_path
      root = ENV["CHOPSHOP_SVG_DIR"].presence || Rails.root.join("..", "chopshop-svg").to_s
      File.join(root, "scripts", "palettes.json")
    end

    def load
      raw = JSON.parse(File.read(path))
      return EMPTY unless raw.is_a?(Hash)

      roles = raw["_roles"].is_a?(Hash) ? raw["_roles"].keys : []
      palettes = Array(raw["palettes"]).filter_map { |entry| build_palette(entry, roles) }
      Library.new(version: raw["version"], roles: roles, palettes: palettes)
    rescue SystemCallError, ArgumentError, JSON::ParserError
      # SystemCallError covers the whole family (ENOENT, EACCES, EISDIR when the
      # path is a directory) — a narrow Errno list leaves the rest escaping to a
      # 500, which is exactly what this class promises never to do.
      EMPTY
    end

    private

    def build_palette(entry, roles)
      return nil unless entry.is_a?(Hash)

      colours = Array(entry["colours"]).map { |c| c.to_s.downcase }.select { |c| HEX.match?(c) }
      return nil if colours.empty?

      bg = entry["background"].to_s.downcase
      Palette.new(
        id: entry["id"].to_s,
        name: entry["name"].presence || entry["id"].to_s,
        note: entry["note"].to_s,
        background: (HEX.match?(bg) ? bg : nil),
        colours: colours.each_with_index.map { |hex, i| Colour.new(hex: hex, role: roles[i] || "extra") },
        map: entry["map"].is_a?(Hash) ? entry["map"] : {}
      )
    end
  end
end
