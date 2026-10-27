class CreatePosts < ActiveRecord::Migration[8.1]
  def change
    create_table :posts do |t|
      t.string :title, null: false
      t.text :body, null: false, default: ""
      t.datetime :publish_at
      t.string :status, null: false, default: "draft"
      t.text :notes

      t.timestamps
    end

    add_index :posts, :publish_at
    add_index :posts, :status
    add_check_constraint :posts, "status IN ('draft', 'scheduled', 'published')", name: "posts_status_valid"
  end
end
