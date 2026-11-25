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

  # Ordinamento per statistiche («Ordine» nei filtri: s=views desc, s=reach asc…). Ransack, se l'ordinamento non è
  # una colonna, usa lo scope sort_by_<nome>_<verso>. Conta il totale all'ultima lettura, sommato sui social, come nelle
  # pagine; i post non pubblicati o senza letture vanno in fondo in entrambi i versi.
  STATS_TOTALS_JOIN = <<~SQL.squish
    LEFT JOIN (
      SELECT publications.post_id, SUM(latest.total_views) AS views, SUM(latest.total_reach) AS reach
      FROM (SELECT DISTINCT ON (publication_id) publication_id, total_views, total_reach
            FROM publication_metrics ORDER BY publication_id, measured_on DESC) latest
      JOIN publications ON publications.id = latest.publication_id
      GROUP BY publications.post_id
    ) post_totals ON post_totals.post_id = posts.id AND posts.status = 'published'
  SQL

  %w[views reach].each do |field|
    %w[asc desc].each do |dir|
      scope :"sort_by_#{field}_#{dir}", lambda {
        joins(STATS_TOTALS_JOIN).select("posts.*", "post_totals.#{field} AS stats_#{field}")
                                .order(Arel.sql("stats_#{field} #{dir.upcase} NULLS LAST, posts.publish_at DESC NULLS LAST, posts.id DESC"))
      }
    end
  end

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

  # Pubblicato o programmato: torna bozza. Un programmato tiene la sua data, da riproporre con «Programma».
  def unpublish!
    raise TransitionError, "Si può spubblicare solo un post pubblicato o programmato." unless published? || scheduled?

    update!(status: :draft)
  end

  private

  # L'ordine è quello in cui i file sono stati assegnati: file già salvati (id firmati) e caricamenti nuovi,
  # mescolati come li ha messi la persona. Active Storage tiene i blob nello stesso ordine.
  def store_media_order
    @media_assigned_order = nil

    changes = attachment_changes["media"]
    assigned = changes.respond_to?(:blobs) ? changes.blobs.filter_map(&:id) : []
    current = media_attachments.reload.sort_by(&:id).map(&:blob_id)
    update_column(:media_order, (assigned & current) + (current - assigned))
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
