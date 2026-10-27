# Una chat con l'assistente (Claude Code) legata a un post, o a un post non ancora salvato.
#
# I file della chat (allegati della persona, immagini create da Claude) stanno in Active Storage, collegati
# al messaggio che li ha portati. Claude però lavora su file veri: per ogni risposta la cartella di lavoro
# (tmp/assistant/<token>) viene preparata con i file già salvati (prepare_outbox!), e alla fine quelli nuovi
# o modificati vengono salvati sul messaggio di Claude e la cartella si svuota (collect_outbox!).
class AssistantConversation < ApplicationRecord
  class UploadError < StandardError; end

  OUTBOX_ROOT = Rails.root.join("tmp/assistant")

  # I file che si possono allegare a un messaggio, per tipo.
  UPLOAD_KINDS = {
    "testo" => %w[.txt .md .csv],
    "pdf" => %w[.pdf],
    "immagine" => %w[.jpg .jpeg .png .gif .webp .heic .heif],
    "video" => %w[.mp4 .mov .m4v .webm]
  }.freeze
  MAX_UPLOAD_SIZE = 100.megabytes
  MAX_UPLOADS = 10
  # Le immagini e i video creati da Claude che si conservano; gli altri file (script, file intermedi
  # con il prefisso «_») restano solo per la durata della risposta.
  KEPT_EXTENSIONS = %w[.jpg .jpeg .png .gif .webp .heic .heif .mp4 .mov .m4v .webm].freeze

  belongs_to :post, optional: true
  # destroy (e non delete_all), così Active Storage cancella anche i file dei messaggi.
  has_many :messages, -> { order(:created_at, :id) }, class_name: "AssistantMessage", dependent: :destroy

  after_destroy_commit :remove_working_folders

  validates :token, presence: true, uniqueness: true, format: { with: /\A[a-f0-9-]{36}\z/ }

  def self.accepted_extensions = UPLOAD_KINDS.values.flatten

  # La cartella dove l'assistente può creare immagini per questo post, e dove finiscono gli allegati.
  def outbox
    OUTBOX_ROOT.join(token).tap(&:mkpath)
  end

  # I file della conversazione per nome, nella versione più recente (Claude può rifare un'immagine
  # con lo stesso nome: vale l'ultima).
  def latest_files
    ActiveStorage::Attachment.includes(:blob)
                             .where(record_type: "AssistantMessage", name: "files", record_id: messages.unscope(:order).select(:id))
                             .order(:created_at, :id)
                             .index_by { |attachment| attachment.filename.to_s }
  end

  def file_attachment(name) = latest_files[File.basename(name.to_s)]

  # Prima di una risposta: la cartella di lavoro contiene esattamente i file della chat, con il loro nome.
  # Restituisce l'impronta (checksum) di ciascuno, per riconoscere poi quelli nuovi o modificati.
  def prepare_outbox!
    import_legacy_files! # le chat di prima dell'Active Storage: i loro file si salvano prima di svuotare la cartella
    clear_outbox!
    latest_files.to_h do |name, attachment|
      File.open(outbox.join(name), "wb") { |file| attachment.blob.download { |chunk| file.write(chunk) } }
      [ name, attachment.blob.checksum ]
    end
  end

  # Dopo una risposta: i file nuovi o modificati nella cartella di lavoro vengono salvati sul messaggio,
  # poi la cartella si svuota. Si conservano solo immagini e video, non i file intermedi («_…»).
  def collect_outbox!(message, known)
    changed = outbox.children.select do |path|
      name = path.basename.to_s
      path.file? && !name.start_with?("_") && KEPT_EXTENSIONS.include?(path.extname.downcase) &&
        known[name] != Digest::MD5.file(path).base64digest
    end
    changed.sort.each do |path|
      path.open { |io| message.files.attach(io:, filename: path.basename.to_s, content_type: Marcel::MimeType.for(path)) }
    end
    changed.size
  ensure
    clear_outbox!
  end

  # Le chat nate quando i file stavano solo nella cartella di lavoro: porta quei file in Active Storage.
  # Un allegato della persona va sul suo messaggio; un'immagine di Claude sul primo messaggio che la cita,
  # altrimenti sull'ultima risposta di Claude. Script e file intermedi («_…») si tralasciano.
  # Restituisce i nomi importati e quelli tralasciati. Rilanciato non duplica niente.
  def import_legacy_files!
    folder = OUTBOX_ROOT.join(token)
    return [ [], [] ] unless folder.directory?

    list = messages.to_a
    present = latest_files
    imported, skipped = [], []
    folder.children.select(&:file?).sort.each do |path|
      name = path.basename.to_s
      next if present.key?(name) # già in Active Storage

      owner = list.find { |m| m.role == "user" && Array(m.attachments).any? { |a| a["name"] == name } }
      unless owner || name.start_with?("_") || !KEPT_EXTENSIONS.include?(path.extname.downcase)
        owner = list.find { |m| m.role == "assistant" && m.content.include?("/#{name}") } ||
                list.reverse.find { |m| m.role == "assistant" } || list.last
      end
      if owner
        path.open { |io| owner.files.attach(io:, filename: name, content_type: Marcel::MimeType.for(path)) }
        imported << name
      else
        skipped << name
      end
    end
    [ imported, skipped ]
  end

  def clear_outbox!
    FileUtils.rm_rf(OUTBOX_ROOT.join(token))
  end

  # Un file creato dall'assistente o allegato, solo se sta davvero nella sua cartella di lavoro.
  def outbox_file(name)
    name = File.basename(name.to_s)
    path = outbox.join(name)
    path if name.present? && path.file? && path.realpath.to_s.start_with?(outbox.realpath.to_s + "/")
  end

  # Salva un file allegato dalla persona e ne restituisce la descrizione da tenere nel messaggio.
  def store_upload(upload)
    original = upload.original_filename.to_s
    extension = File.extname(original).downcase
    kind = UPLOAD_KINDS.find { |_, extensions| extensions.include?(extension) }&.first
    unless kind
      raise UploadError, "«#{original}»: tipo di file non accettato. Si possono allegare testi (.txt, .md, .csv), " \
                         "PDF, immagini e video. Per un documento Word, copiane il testo o salvalo in PDF."
    end
    raise UploadError, "«#{original}» è troppo grande: il massimo è 100 MB." if upload.size > MAX_UPLOAD_SIZE

    name = free_name(original, extension)
    File.open(outbox.join(name), "wb") { |file| IO.copy_stream(upload.tempfile, file) }
    { "name" => name, "original" => original, "kind" => kind, "size" => upload.size }
  end

  private

  def remove_working_folders
    clear_outbox!
    FileUtils.rm_rf(AssistantRunner::POLICY_ROOT.join(token))
  end

  # Un nome semplice e senza sorprese, che non sovrascrive file già presenti.
  def free_name(original, extension)
    base = File.basename(original, ".*").unicode_normalize(:nfc).gsub(/[^\p{L}\p{N}_-]+/, "_").squeeze("_").delete_prefix("_")
    base = base[0, 60].presence || "file"
    name = "#{base}#{extension}"
    counter = 1
    name = "#{base}-#{counter += 1}#{extension}" while outbox.join(name).exist?
    name
  end
end
