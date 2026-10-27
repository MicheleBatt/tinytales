# Una chat con l'assistente (Claude Code) legata a un post, o a un post non ancora salvato.
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

  belongs_to :post, optional: true
  has_many :messages, -> { order(:created_at, :id) }, class_name: "AssistantMessage", dependent: :delete_all

  validates :token, presence: true, uniqueness: true, format: { with: /\A[a-f0-9-]{36}\z/ }

  def self.accepted_extensions = UPLOAD_KINDS.values.flatten

  # La cartella dove l'assistente può creare immagini per questo post, e dove finiscono gli allegati.
  def outbox
    OUTBOX_ROOT.join(token).tap(&:mkpath)
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
