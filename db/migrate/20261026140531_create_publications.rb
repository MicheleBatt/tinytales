# Su quali pagine social esce un post. Più avanti potrà tenere anche lo stato
# della pubblicazione su ciascuna pagina.
class CreatePublications < ActiveRecord::Migration[8.1]
  def change
    create_table :publications do |t|
      t.references :post, null: false, foreign_key: { on_delete: :cascade }
      t.references :social_page, null: false, foreign_key: true

      t.timestamps
    end

    add_index :publications, [ :post_id, :social_page_id ], unique: true
  end
end
