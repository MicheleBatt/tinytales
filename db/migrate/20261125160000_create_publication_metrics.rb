# Visualizzazioni e persone raggiunte da ogni pubblicazione, una riga al giorno.
class CreatePublicationMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :publication_metrics do |t|
      t.references :publication, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :measured_on, null: false
      t.datetime :measured_at, null: false
      t.integer :total_views, null: false
      t.integer :total_reach, null: false
      t.string :remote_id, null: false
      t.timestamps
    end
    add_index :publication_metrics, %i[publication_id measured_on], unique: true

    # Per un video (reel) le statistiche stanno sul post che lo contiene, non sul video:
    # qui si ricorda l'id di quel post, così si chiede a Facebook una volta sola.
    add_column :publications, :remote_post_id, :string

    # Il freno sulle letture: fino a quest'ora l'app non chiede statistiche alla pagina.
    add_column :social_pages, :metrics_paused_until, :datetime
  end
end
