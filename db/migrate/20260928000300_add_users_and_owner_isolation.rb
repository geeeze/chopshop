# Per-user identity and the owner handle every user-scoped row carries.
#
# Written as a real migration (rather than a hand-edit to schema.rb) so that
# `db:migrate` — the deploy path the live server uses — creates the table and
# the columns. The `users` table is password-only: the password IS the identity
# (no username, no directory), and `handle` is the internal owner key that jobs,
# candidates, proofs, scrapbook items and composites all scope their rows to.
class AddUsersAndOwnerIsolation < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :handle, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :handle, unique: true

    add_column :jobs, :owner, :string
    add_column :validations, :owner, :string
  end
end
