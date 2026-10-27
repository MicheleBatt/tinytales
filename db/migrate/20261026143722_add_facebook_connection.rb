# Il collegamento vero con i social:
# - ogni pagina tiene il suo id sul social e il token di accesso (cifrato);
# - ogni pubblicazione tiene l'id del post sul social, i file inviati e l'ultimo errore.
class AddFacebookConnection < ActiveRecord::Migration[8.1]
  def change
    change_table :social_pages, bulk: true do |t|
      t.string :external_id
      t.text :access_token
    end

    change_table :publications, bulk: true do |t|
      t.string :remote_id
      t.string :remote_kind
      t.string :remote_media_ids, array: true, null: false, default: []
      t.bigint :synced_media_order, array: true, null: false, default: []
      t.datetime :synced_at
      t.text :sync_error
    end

    add_index :publications, :remote_id
  end
end
