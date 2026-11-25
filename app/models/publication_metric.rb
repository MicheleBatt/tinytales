# Le statistiche di una pubblicazione in un giorno: i totali dalla pubblicazione fino all'ultima lettura di quel giorno.
#
# - measured_on: il giorno, in ora italiana. Si ricava sempre da measured_at, non si imposta mai a mano.
# - measured_at: l'ora esatta dell'ultima lettura del giorno.
# - total_views: le visualizzazioni (le stesse persone si contano ogni volta che vedono il post).
# - total_reach: le persone raggiunte (ognuna una volta sola).
# - remote_id: l'id del post sul social al momento della lettura. Se cambia, il post è stato ripubblicato
#   e i totali sono ripartiti da zero.
class PublicationMetric < ApplicationRecord
  belongs_to :publication

  before_validation { self.measured_on = self.class.day_of(measured_at) if measured_at }

  validates :measured_at, :remote_id, presence: true
  validates :total_views, :total_reach, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Il giorno di una lettura, in ora italiana (config.time_zone).
  def self.day_of(time) = time.in_time_zone(Time.zone).to_date

  # Salva una lettura: nello stesso giorno aggiorna la riga che c'è già, altrimenti ne crea una.
  # Con l'indice unico del database due letture contemporanee non creano mai due righe.
  def self.record!(publication, views:, reach:, at: Time.current)
    upsert({ publication_id: publication.id, measured_on: day_of(at), measured_at: at,
             total_views: views, total_reach: reach, remote_id: publication.remote_id },
           unique_by: %i[publication_id measured_on],
           update_only: %i[measured_at total_views total_reach remote_id])
  end

  # Le visualizzazioni di questo giorno: la differenza con l'ultimo giorno precedente che ha una lettura.
  # Se fra le due letture mancano dei giorni, comprende anche quelli.
  def daily_views = daily(:total_views)

  # Le persone raggiunte per la prima volta in questo giorno.
  def daily_reach = daily(:total_reach)

  private

  # Senza una lettura precedente dello stesso post sul social, il giorno vale il totale solo se il post
  # è uscito proprio quel giorno; altrimenti non si sa (nil).
  def daily(field)
    previous = publication.metrics.where(measured_on: ...measured_on).order(measured_on: :desc).first
    if previous && previous.remote_id == remote_id
      [ self[field] - previous[field], 0 ].max
    elsif publication.post.publish_at && self.class.day_of(publication.post.publish_at) == measured_on
      self[field]
    end
  end
end
