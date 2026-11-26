# Le condivisioni dei post accanto a visualizzazioni, persone raggiunte e reazioni: il numero che si vede sotto il post
# (campo shares). Le letture già salvate restano senza (nil): si riempiono dalla prossima lettura del giorno.
class AddSharesToPublicationMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :publication_metrics, :total_shares, :integer
  end
end
