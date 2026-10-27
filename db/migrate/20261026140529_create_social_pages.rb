class CreateSocialPages < ActiveRecord::Migration[8.1]
  def change
    create_table :social_pages do |t|
      t.string :name, null: false
      t.string :platform, null: false
      t.string :url, null: false

      t.timestamps
    end

    add_index :social_pages, :url, unique: true
  end
end
