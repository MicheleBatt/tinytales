# Un post da pubblicare su una o più pagine social della scuola.
class Post < ApplicationRecord
  enum :status, { draft: "draft", scheduled: "scheduled", published: "published" },
       default: :draft, validate: true

  has_many :publications, dependent: :destroy
  has_many :social_pages, through: :publications
  has_one :assistant_conversation, dependent: :destroy

  # Immagini e video, nell'ordine in cui vanno caricati sul social.
  has_many_attached :media do |attachable|
    attachable.variant :thumb, resize_to_fill: [ 640, 480, { gravity: "North" } ], preprocessed: false
  end

  class TransitionError < StandardError; end

  validates :title, presence: true
  # La data può mancare solo nelle bozze: chi è programmato o pubblicato ce l'ha sempre.
  validates :publish_at, presence: true, unless: :draft?
  validate :media_are_images_or_videos
  validate :scheduled_time_in_future, if: -> { scheduled? && publish_at_changed? && publish_at.present? }

  # Va dichiarato dopo has_many_attached: così parte quando gli allegati sono già salvati.
  after_save :store_media_order, if: -> { @media_assigned_order }

  # Senza un ordinamento scelto nei filtri: dal più lontano nel futuro al più vecchio.
  # In PostgreSQL i post senza data vengono per primi, come bozze ancora da collocare.
  scope :newest_first, -> { order(publish_at: :desc, id: :desc) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[title body notes status publish_at created_at updated_at]
  end

  def self.ransackable_associations(_auth_object = nil)
    %w[social_pages]
  end

  # Il form assegna i file nell'ordine voluto: prima gli id firmati di quelli da tenere,
  # poi i nuovi caricamenti. Ci annotiamo quell'ordine per salvarlo dopo il salvataggio.
  def media=(attachables)
    @media_assigned_order = Array(attachables).compact_blank
    super
  end

  # Gli allegati nell'ordine salvato; quelli non ancora ordinati vanno in fondo, per data di caricamento.
  def ordered_media
    positions = media_order.each_with_index.to_h
    media.sort_by { |file| [ positions.fetch(file.blob_id, positions.size), file.id || 0 ] }
  end

  def images = ordered_media.select(&:image?)
  def videos = ordered_media.select(&:video?)
  def cover = images.first || ordered_media.first

  # Un post con la data passata che non risulta pubblicato va controllato.
  def overdue?(now = Time.current)
    publish_at.present? && publish_at < now && !published?
  end

  # Ogni post nasce bozza. Una bozza si può sempre:
  # - pubblicare subito, qualunque data abbia: la data diventa quella vera di uscita;
  # - programmare, a una data futura (scelta nella finestra di Programma, o quella già impostata).
  # Un post pubblicato si può sempre spubblicare: torna bozza.
  def publishable?(_now = Time.current) = draft?
  def schedulable?(now = Time.current) = draft? && publish_at.present? && publish_at > now
  # Una bozza con la data passata: per programmarla bisogna sceglierne una nuova.
  def date_expired?(now = Time.current) = draft? && publish_at.present? && publish_at <= now

  def publish!(now = Time.current)
    raise TransitionError, "Si può pubblicare solo una bozza." unless publishable?(now)

    update!(status: :published, publish_at: now)
  end

  # Facebook pubblica da sé i post programmati quando arriva l'ora: qui li segniamo pubblicati.
  def self.promote_due_scheduled!(now = Time.current)
    scheduled.where(publish_at: ..now).update_all(status: "published", updated_at: now)
  end

  def schedule!(now = Time.current)
    raise TransitionError, "Per programmare una bozza serve una data di pubblicazione nel futuro." unless schedulable?(now)

    update!(status: :scheduled)
  end

  def unpublish!
    raise TransitionError, "Si può spubblicare solo un post pubblicato." unless published?

    update!(status: :draft)
  end

  private

  def store_media_order
    attachables = @media_assigned_order
    @media_assigned_order = nil

    kept = attachables.grep(String).filter_map { |signed_id| ActiveStorage::Blob.find_signed(signed_id)&.id }
    current = media_attachments.reload.sort_by(&:id).map(&:blob_id)
    update_column(:media_order, (kept & current) + (current - kept))
  end

  def scheduled_time_in_future
    return if publish_at > Time.current

    errors.add(:publish_at, "per un post programmato deve essere nel futuro")
  end

  def media_are_images_or_videos
    media.each do |file|
      next if file.image? || file.video?

      errors.add(:media, "contiene #{file.filename}, che non è un'immagine né un video")
    end
  end
end
