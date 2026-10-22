# Per-user identity and the owner handle every user-scoped row carries.
#
# Written as a real migration (rather than a hand-edit to schema.rb) so that
# `db:migrate` — the deploy path the live server uses — records the change.
# The `users` table is password-only: the password IS the identity (no username,
# no directory), and `handle` is the internal owner key that jobs, candidates,
# proofs, scrapbook items and composites all scope their rows to.
#
# Idempotent on purpose: the auth work that introduced this schema was deployed
# by applying the hand-edited schema.rb directly, so a database may already have
# the table and columns while schema_migrations lacks this version. Each step
# guards on what it would create, so migrate() is a no-op there and still builds
# the schema correctly on a fresh checkout.
class AddUsersAndOwnerIsolation < ActiveRecord::Migration[8.1]
  def change
    unless table_exists?(:users)
      create_table :users do |t|
        t.string :handle, null: false
        t.string :password_digest, null: false
        t.timestamps
      end
    end
    add_index :users, :handle, unique: true unless index_exists?(:users, :handle)

    add_column :jobs, :owner, :string unless column_exists?(:jobs, :owner)
    add_column :validations, :owner, :string unless column_exists?(:validations, :owner)
  end
end
