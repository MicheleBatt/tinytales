# La musicoteca: i brani che Claude può usare come sottofondo dei video. Il file audio è un allegato (Active Storage).
class CreateMusicTracks < ActiveRecord::Migration[8.1]
  def change
    create_table :music_tracks do |t|
      t.string :title, null: false
      t.string :author
      t.string :source_url, null: false
      t.string :license, null: false
      t.string :moods, array: true, null: false, default: []
      t.string :tempo, null: false
      t.string :instruments
      t.boolean :vocals, null: false, default: false
      t.string :suitable_for
      t.text :notes
      t.float :duration
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end
    add_index :music_tracks, :title
  end
end
