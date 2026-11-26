# Aggiorna nel database le statistiche dei post pubblicati (visualizzazioni, persone raggiunte, reazioni e condivisioni),
# leggendole dai social. Si usa quando si apre l'elenco dei post, un post o il popup del calendario
# (lo chiede il browser dopo il caricamento: PostsController#stats) e prima di preparare il report in PDF.
#
# Accorgimenti per non superare i limiti di chiamate dei social:
# - un post letto da meno di FRESH_FOR non si rilegge: si tiene il numero salvato;
# - se il social dice che l'uso dei limiti ha raggiunto USAGE_THRESHOLD %, o risponde «troppe chiamate»,
#   per un po' quella pagina non viene più interrogata (social_pages.metrics_paused_until).
# Non solleva mai errori: chi lo usa va avanti con i numeri salvati, e i problemi finiscono nel log.
class PostMetrics
  FRESH_FOR = 1.minute
  USAGE_THRESHOLD = 75
  PAUSE_NEAR_LIMIT = 15.minutes
  PAUSE_AT_LIMIT = 30.minutes

  # Le pubblicazioni che hanno statistiche da leggere: post pubblicati e presenti sul social.
  def self.readable = Publication.joins(:post).merge(Post.published).where.not(remote_id: nil)

  def self.refresh(publications, now: Time.current) = new(now:).refresh(publications)

  def initialize(now: Time.current)
    @now = now
  end

  # Restituisce quante pubblicazioni sono state aggiornate.
  def refresh(publications)
    candidates = stale(readable(publications))
    candidates.group_by(&:social_page).sum { |page, list| refresh_page(page, list) }
  end

  private

  def readable(publications)
    publications.select { |p| p.on_social? && p.post.published? && p.social_page.connected? && !p.social_page.metrics_paused?(@now) }
  end

  # Senza quelle lette da meno di FRESH_FOR.
  def stale(publications)
    fresh = PublicationMetric.where(publication_id: publications.map(&:id), measured_at: (@now - FRESH_FOR)..).pluck(:publication_id)
    publications.reject { |p| fresh.include?(p.id) }
  end

  def refresh_page(page, publications)
    reader = SocialMetrics.for(page) or return 0
    result = reader.read(publications)

    by_id = publications.index_by(&:id)
    result.readings.each do |id, reading|
      PublicationMetric.record!(by_id.fetch(id), views: reading.views, reach: reading.reach, reactions: reading.reactions,
                                                reactions_by_type: reading.reactions_by_type, shares: reading.shares, at: @now)
    end
    brake(page, result)
    result.errors.each { |error| Rails.logger.warn("[statistiche #{page.platform_label}] #{error}") }
    result.readings.size
  rescue StandardError => error
    Rails.logger.error("[statistiche #{page.platform_label}] lettura non riuscita: #{error.class}: #{error.message}")
    0
  end

  def brake(page, result)
    regain = (result.usage&.regain_minutes || 0).minutes
    pause = if result.rate_limited
              [ regain, PAUSE_AT_LIMIT ].max
            elsif result.usage && result.usage.percent >= USAGE_THRESHOLD
              [ regain, PAUSE_NEAR_LIMIT ].max
            end
    return unless pause

    page.update_column(:metrics_paused_until, @now + pause)
    Rails.logger.warn("[statistiche #{page.platform_label}] vicino ai limiti di Meta " \
                      "(uso #{result.usage&.percent || '?'}%): letture sospese fino a #{I18n.l(@now + pause, format: :short)}")
  end
end
