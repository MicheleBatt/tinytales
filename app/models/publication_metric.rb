# Le statistiche di una pubblicazione in un giorno: i totali dalla pubblicazione fino all'ultima lettura di quel giorno.
#
# - measured_on: il giorno, in ora italiana. Si ricava sempre da measured_at, non si imposta mai a mano.
# - measured_at: l'ora esatta dell'ultima lettura del giorno.
# - total_views: le visualizzazioni (le stesse persone si contano ogni volta che vedono il post).
# - total_reach: le persone raggiunte (ognuna una volta sola).
# - total_reactions: le reazioni (Mi piace, Love, Ahah…), e reactions_by_type il loro dettaglio ({"like" => 19, "love" => 2}).
#   Nelle letture salvate prima del 26/11/2026 mancano (nil).
# - total_shares: le condivisioni secondo le statistiche di Facebook: tutte quelle fatte, anche private o poi cancellate
#   (quindi possono essere più di quelle visibili sotto il post). Mancano (nil) nelle letture salvate prima del 26/11/2026.
# - remote_id: l'id del post sul social al momento della lettura. Se cambia, il post è stato ripubblicato
#   e i totali sono ripartiti da zero.
class PublicationMetric < ApplicationRecord
  belongs_to :publication

  before_validation { self.measured_on = self.class.day_of(measured_at) if measured_at }

  validates :measured_at, :remote_id, presence: true
  validates :total_views, :total_reach, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :total_reactions, :total_shares, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # Il giorno di una lettura, in ora italiana (config.time_zone).
  def self.day_of(time) = time.in_time_zone(Time.zone).to_date

  # Salva una lettura: nello stesso giorno aggiorna la riga che c'è già, altrimenti ne crea una.
  # Con l'indice unico del database due letture contemporanee non creano mai due righe.
  def self.record!(publication, views:, reach:, reactions: nil, reactions_by_type: {}, shares: nil, at: Time.current)
    upsert({ publication_id: publication.id, measured_on: day_of(at), measured_at: at,
             total_views: views, total_reach: reach, total_reactions: reactions, reactions_by_type: reactions_by_type || {},
             total_shares: shares,
             remote_id: publication.remote_id },
           unique_by: %i[publication_id measured_on],
           update_only: %i[measured_at total_views total_reach total_reactions reactions_by_type total_shares remote_id])
  end

  # Le visualizzazioni di questo giorno: la differenza con l'ultimo giorno precedente che ha una lettura.
  # Se fra le due letture mancano dei giorni, comprende anche quelli.
  def daily_views = daily(:total_views)

  # Le persone raggiunte per la prima volta in questo giorno.
  def daily_reach = daily(:total_reach)

  # Le reazioni arrivate in questo giorno (nil se una delle due letture non le ha).
  def daily_reactions = daily(:total_reactions)

  # Le condivisioni nuove di questo giorno (nil se una delle due letture non le ha).
  def daily_shares = daily(:total_shares)

  private

  # Senza una lettura precedente dello stesso post sul social, il giorno vale il totale solo se il post
  # è uscito proprio quel giorno; altrimenti non si sa (nil).
  def daily(field)
    previous = publication.metrics.where(measured_on: ...measured_on).order(measured_on: :desc).first
    return if self[field].nil?

    if previous && previous.remote_id == remote_id
      previous[field] && [ self[field] - previous[field], 0 ].max
    elsif publication.post.publish_at && self.class.day_of(publication.post.publish_at) == measured_on
      self[field]
    end
  end
end
