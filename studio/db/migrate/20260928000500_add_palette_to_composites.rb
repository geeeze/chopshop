# The composite's palette: the colours a compose may draw with.
#
# Guarded on what it would create, in the same style as CreateEvents and
# AddUsersAndOwnerIsolation: `composites` has no create migration of its own
# (schema.rb is its source), so a database built from schema.rb already carries
# the column and a database that predates it gains it here. `migrate` is a no-op
# on the former and correct on the latter.
#
# It is JSON rather than a string so the value is the LIST the compose contract
# speaks (["#rrggbb", …]) rather than a second encoding for it, and it defaults
# to `[]` — "no palette" — because the wire contract makes `palette` optional and
# an absent key and an empty list must mean the same thing.
class AddPaletteToComposites < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:composites, :palette)
      add_column :composites, :palette, :json, default: []
    end
  end
end
