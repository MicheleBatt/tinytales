# I tag del brano copiati dalla sua pagina (per esempio su Pixabay): aiutano Claude a compilare e scegliere.
class AddSourceTagsToMusicTracks < ActiveRecord::Migration[8.1]
  def change
    add_column :music_tracks, :source_tags, :string
  end
end
