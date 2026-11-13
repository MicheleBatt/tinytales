require "open3"

# Un brano della musicoteca: il file audio più la scheda che Claude legge per sceglierlo
# (Claude non può ascoltare la musica, quindi sceglie in base ad atmosfera, ritmo, strumenti…).
class MusicTrack < ApplicationRecord
  # Solo licenze che permettono l'uso libero anche sui social, senza obblighi.
  LICENSES = [ "Pixabay Content License", "CC0" ].freeze
  # Le sole atmosfere ammesse: niente musiche aggressive, cupe o da discoteca, per scelta della scuola.
  MOODS = %w[allegra vivace giocosa festosa dolce tenera serena rilassante natalizia primaverile estiva autunnale].freeze
  TEMPOS = %w[lento medio vivace].freeze
  # Estensione → formato con cui ffprobe e ffmpeg leggono il file (lo stesso elenco del montaggio video).
  FORMATS = Assistant::Video::AUDIO
  MAX_SIZE = 30.megabytes

  has_one_attached :audio

  validates :title, presence: true
  validates :source_url, format: { with: %r{\Ahttps://\S+\z}, message: "dev'essere il link della pagina del brano (https://…)" }
  validates :license, inclusion: { in: LICENSES, message: "dev'essere una fra: #{LICENSES.join(', ')}" }
  validates :tempo, inclusion: { in: TEMPOS, message: "è obbligatorio" }
  validate :moods_from_the_list
  validate :audio_file

  before_validation :normalize_moods
  before_validation :read_duration, if: -> { attachment_changes["audio"].present? }

  # Filtri dell'elenco (Ransack): atmosfera, voce e stato passano da scope, perché le atmosfere sono una lista
  # e perché Ransack ignora i filtri «uguale a falso».
  scope :with_mood, ->(mood) { MOODS.include?(mood) ? where("? = ANY(moods)", mood) : all }
  scope :voice, ->(value) { { "con-voce" => where(vocals: true), "strumentali" => where(vocals: false) }.fetch(value, all) }
  scope :state, ->(value) { { "attivi" => where(enabled: true), "disattivati" => where(enabled: false) }.fetch(value, all) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[title author instruments suitable_for notes source_tags tempo duration created_at]
  end

  def self.ransackable_associations(_auth_object = nil) = []
  def self.ransackable_scopes(_auth_object = nil) = %i[with_mood voice state]

  # I brani che Claude può usare: attivi e con il file.
  scope :usable, -> { where(enabled: true).joins(:audio_attachment) }
  scope :by_title, -> { order(Arel.sql("lower(title)"), :id) }

  def duration_label
    return "—" unless duration

    seconds = duration.round
    format("%d:%02d", seconds / 60, seconds % 60)
  end

  # Il percorso del file sul disco, per il montaggio dei video.
  def audio_path = ActiveStorage::Blob.service.path_for(audio.key)
  def audio_extension = File.extname(audio.filename.to_s).downcase

  # Il brano per il montaggio dei video (Assistant::Video.music_resolver): solo se è attivo e ha il file.
  def self.for_video(id)
    track = usable.find_by(id:) or return nil
    { path: track.audio_path, ext: track.audio_extension, title: track.title }
  end

  # L'elenco per Claude (bin/assistant musica): solo i brani utilizzabili, con la loro scheda.
  def self.assistant_listing
    tracks = usable.includes(audio_attachment: :blob).by_title.to_a
    return "La musicoteca è vuota: per ora i video si fanno senza musica (o con una traccia allegata nella chat)." if tracks.empty?

    lines = [ "Musicoteca: #{tracks.size} brani. Nella ricetta indica il brano con il suo numero: \"musica\": { \"brano\": N }" ]
    tracks.each do |t|
      lines << ""
      lines << "- brano #{t.id}: «#{t.title}»#{" di #{t.author}" if t.author.present?} · #{t.duration_label} · " \
               "ritmo #{t.tempo} · #{t.vocals? ? 'con voce' : 'strumentale'}"
      lines << "  atmosfera: #{t.moods.join(', ')}"
      lines << "  strumenti: #{t.instruments}" if t.instruments.present?
      lines << "  adatto a: #{t.suitable_for}" if t.suitable_for.present?
      lines << "  tag della fonte: #{t.source_tags}" if t.source_tags.present?
      lines << "  note: #{t.notes.squish}" if t.notes.present?
    end
    lines.join("\n")
  end

  # Durata in secondi letta con ffprobe, oppure nil se il file non è un audio leggibile.
  def self.probe_duration(path, extension)
    format = FORMATS[extension] or return nil
    out, status = Open3.capture2e(ENV.fetch("FFPROBE_BIN", "ffprobe"), "-v", "error", "-protocol_whitelist", "file",
                                  "-f", format, "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", "file:#{path}")
    value = Float(out.strip, exception: false)
    value if status.success? && value&.positive?
  rescue Errno::ENOENT
    nil
  end

  private

  def normalize_moods
    self.moods = Array(moods).compact_blank.uniq
  end

  def moods_from_the_list
    errors.add(:moods, "scegline almeno una") if moods.empty?
    errors.add(:moods, "contiene valori non ammessi") if (moods - MOODS).any?
  end

  # Il file nuovo appena scelto: la durata si legge prima di salvare, e così si controlla anche che sia audio vero.
  def read_duration
    @audio_unreadable = false
    change = attachment_changes["audio"]
    return unless change.respond_to?(:attachable) # il file è stato tolto, non sostituito

    attachable = change.attachable
    path = attachable.respond_to?(:tempfile) ? attachable.tempfile.path : (attachable[:io].path if attachable.is_a?(Hash) && attachable[:io].respond_to?(:path))
    return unless path

    self.duration = self.class.probe_duration(path, audio_extension)
    @audio_unreadable = duration.nil?
  end

  def audio_file
    return errors.add(:audio, "manca: scegli il file del brano") unless audio.attached?

    unless FORMATS.key?(audio_extension)
      return errors.add(:audio, "dev'essere un file #{FORMATS.keys.map { |e| e.delete('.') }.join(', ')}")
    end
    errors.add(:audio, "è troppo grande: il massimo è 30 MB") if audio.blob.byte_size.to_i > MAX_SIZE
    errors.add(:audio, "non è un file audio leggibile") if @audio_unreadable
  end
end
