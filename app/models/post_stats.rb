# Le statistiche di un post, sommate su tutte le sue pubblicazioni (oggi solo Facebook, domani anche altri social).
#
# - Totals: i totali all'ultima lettura (visualizzazioni, persone raggiunte e quando sono stati letti).
# - Point: i totali in un giorno di lettura, per i grafici dell'andamento. In un giorno in cui un social non è stato
#   letto vale la sua ultima lettura precedente.
#
# Le persone raggiunte su più social si sommano: chi vede il post su due social conta due volte.
module PostStats
  Totals = Data.define(:views, :reach, :measured_at)
  Point = Data.define(:day, :views, :reach, :measured_at)

  # Si mostrano solo per i post pubblicati.
  def self.shown?(post) = post.published?

  # { post_id => Totals } per i post indicati che hanno almeno una lettura. Una sola query, qualunque sia lo storico.
  def self.latest(post_ids)
    latest = PublicationMetric.joins(:publication).where(publications: { post_id: post_ids })
                              .select("DISTINCT ON (publication_metrics.publication_id) publication_metrics.*, publications.post_id AS post_id")
                              .order("publication_metrics.publication_id, publication_metrics.measured_on DESC")
    latest.group_by(&:post_id).transform_values do |metrics|
      Totals.new(views: metrics.sum(&:total_views), reach: metrics.sum(&:total_reach), measured_at: metrics.map(&:measured_at).max)
    end
  end

  # { post_id => [Point, …] } in ordine di giorno, per i post indicati che hanno almeno una lettura.
  def self.series(post_ids)
    metrics = PublicationMetric.joins(:publication).where(publications: { post_id: post_ids })
                               .select("publication_metrics.*, publications.post_id AS post_id").order(:measured_on)
    metrics.group_by(&:post_id).transform_values do |of_post|
      last = {}
      of_post.group_by(&:measured_on).map do |day, of_day|
        of_day.each { |metric| last[metric.publication_id] = metric }
        Point.new(day:, views: last.values.sum(&:total_views), reach: last.values.sum(&:total_reach),
                  measured_at: last.values.map(&:measured_at).max)
      end
    end
  end

  def self.totals_of(point) = point && Totals.new(views: point.views, reach: point.reach, measured_at: point.measured_at)

  # Quanto è cresciuta una misura (:views o :reach) dall'ultimo giorno letto prima: [aumento, quel giorno],
  # oppure nil se c'è una lettura sola o se il totale è sceso (post ripubblicato: i totali ripartono da zero).
  def self.change(points, kind)
    return if points.size < 2

    before, last = points.last(2)
    diff = last.public_send(kind) - before.public_send(kind)
    [ diff, before.day ] if diff >= 0
  end
end
