# Active Storage non tiene un ordine per gli allegati: lo salviamo nel post,
# come elenco degli id dei blob nell'ordine in cui vanno caricati sui social.
class AddMediaOrderToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :media_order, :bigint, array: true, null: false, default: []
  end
end
