# Collega il montaggio dei video (Assistant::Video, Ruby puro) ai dati dell'app:
# - i brani della musicoteca, indicati da Claude per numero;
# - gli allegati dei post in Active Storage, che sul disco non hanno estensione: il formato
#   si ricava dal nome originale del file, salvato nel database.
module VideoSetup
  def self.apply!
    Assistant::Video.music_resolver = MusicTrack.method(:for_video)
    Assistant::Video.storage_root = ActiveStorage::Blob.service.root
    Assistant::Video.stored_extension = method(:stored_extension)
  end

  def self.reset!
    Assistant::Video.music_resolver = nil
    Assistant::Video.storage_root = nil
    Assistant::Video.stored_extension = nil
  end

  # L'estensione del file originale («.jpg»), solo se il percorso è proprio quello del file in Active Storage.
  def self.stored_extension(path)
    blob = ActiveStorage::Blob.find_by(key: File.basename(path)) or return nil
    stored = ActiveStorage::Blob.service.path_for(blob.key)
    File.extname(blob.filename.to_s) if File.exist?(stored) && File.realpath(stored) == path
  end
end
