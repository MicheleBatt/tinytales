# Le reazioni ai post (Mi piace, Love, Ahah…) accanto a visualizzazioni e persone raggiunte:
# il totale e il dettaglio per tipo, come li dà Facebook ({"like" => 19, "love" => 2}).
# Le letture già salvate restano senza reazioni (nil): si riempiono dalla prossima lettura del giorno.
class AddReactionsToPublicationMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :publication_metrics, :total_reactions, :integer
    add_column :publication_metrics, :reactions_by_type, :jsonb, default: {}, null: false
  end
end
