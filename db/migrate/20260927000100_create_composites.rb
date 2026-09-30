# `composites`, whose only source until now was `schema.rb`.
#
# The companion to `CreateStudioCoreTables`, and the table whose absence produced
# the loudest version of the fault this pair fixes: `AddPaletteToComposites` is
# the migration `db:migrate` aborted on with "Could not find table 'composites'",
# because on a database built by replaying migrations in order this table was
# never there. See that migration's comment for the whole shape of the problem.
#
# GUARDED for the same reason and dated so it runs FIRST on a fresh database and
# is a no-op on every existing one.
#
# `palette` is NOT created here: `AddPaletteToComposites` adds it, and creating
# it here as well would make that migration's guarded `add_column` a duplicate.
# The table is reconstructed as it was when the dump first described it and built
# forward from there, which is what makes the replay produce the dump's schema.
#
# `layers` is JSON rather than a string because a layer is a structured record
# ([{kind, src, name, x, y, w, h, z, opacity, hue, visible}]), and the compose
# contract speaks it as a list. It defaults to `[]` -- "no layers" -- because an
# absent key and an empty list must mean the same thing to the builder.
class CreateComposites < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:composites)

    create_table :composites do |t|
      t.string   :name, null: false
      t.integer  :width, null: false
      t.integer  :height, null: false
      t.string   :background, default: "transparent" # transparent | a #rrggbb
      # [{kind, src, name, x, y, w, h, z, opacity, hue, visible}] — `kind` is
      # "raster" (pixels) or "vector" (an SVG composed as vectors); a layer
      # without it is raster. Kept in step with AddPaletteToComposites and the
      # model.
      t.json     :layers, default: []               # [{kind, src, name, x, y, w, h, z, opacity, hue, visible}]
      t.string   :owner                              # nullable: one operator today, pivot-ready
      t.timestamps null: false, default: -> { "CURRENT_TIMESTAMP" }
      # `palette` arrives from AddPaletteToComposites.
    end
  end
end
