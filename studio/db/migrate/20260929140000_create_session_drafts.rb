class CreateSessionDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :session_drafts do |t|
      t.string  :token, null: false
      t.string  :owner, null: false
      t.string  :kind, null: false
      t.text    :body, null: false
      t.string  :source
      t.timestamps
    end
    add_index :session_drafts, :token, unique: true
    add_index :session_drafts, %i[owner kind]
  end
end
