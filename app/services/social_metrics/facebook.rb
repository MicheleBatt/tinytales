module SocialMetrics
  # Le statistiche dei post di una pagina Facebook (servono i permessi read_insights e pages_read_user_content).
  #
  # Per ogni post, due letture nella stessa richiesta:
  # - dalle statistiche (insights): visualizzazioni (post_media_view), persone raggiunte (post_total_media_view_unique)
  #   e condivisioni (la voce share di post_activity_by_action_type), come totale dalla pubblicazione (period=lifetime);
  # - dal post: le reazioni che ci sono adesso, tipo per tipo, cioè gli stessi numeri che si vedono sotto il post.
  # Le condivisioni NON si leggono dal campo shares del post: conta solo quelle che il token può vedere (le pubbliche),
  # cambia da un'ora all'altra e non coincide con quello che vede ciascuno (dipende da chi guarda). Le statistiche contano
  # tutte le condivisioni fatte, anche private o poi cancellate: più alte di quelle visibili, ma stabili (26/11/2026).
  #   La metrica degli insights post_reactions_by_type_total NON va bene: conta le azioni di reazione, comprese quelle
  #   sulle condivisioni e quelle tolte (per «Benvenuti» il 26/11/2026: 21 contro i 14 visibili).
  # - Tutti i post si leggono con una sola richiesta (batch, 50 letture: 25 post); oltre, più richieste in parallelo.
  # - Un video pubblicato dall'app è spesso un reel: l'id che abbiamo è quello del video, che non ha statistiche.
  #   Si chiede una volta l'id del post che lo contiene (post_id) e lo si ricorda in publications.remote_post_id.
  class Facebook
    METRICS = { "post_media_view" => :views, "post_total_media_view_unique" => :reach,
                "post_activity_by_action_type" => :activity }.freeze

    # I tipi di reazione del campo reactions, e come si chiamano nel database (in minuscolo).
    REACTION_TYPES = %w[LIKE LOVE CARE HAHA WOW SAD ANGRY].freeze
    REACTIONS_FIELDS = ([ "reactions.limit(0).summary(total_count).as(totale)" ] +
                        REACTION_TYPES.map { |type| "reactions.type(#{type}).limit(0).summary(total_count).as(#{type.downcase})" }).join(",")

    # I campi letti dal post: le reazioni.
    POST_FIELDS = REACTIONS_FIELDS

    # Due letture per post in ogni batch.
    POSTS_PER_BATCH = FacebookGraph::Client::BATCH_LIMIT / 2

    # Gli errori di Meta che vogliono dire «troppe chiamate».
    RATE_LIMIT_CODES = [ 4, 17, 32, 613, 80001 ].freeze

    # Nei test si sostituisce con un client finto.
    cattr_accessor :client_builder, default: ->(page) { FacebookGraph::Client.new(page.access_token) }

    def initialize(page)
      @page = page
    end

    def read(publications)
      @usages = []
      @errors = []
      @rate_limited = false

      targets = publications.filter_map { |publication| (id = target_id(publication)) && [ publication, id ] }
      slices = targets.each_slice(POSTS_PER_BATCH).to_a
      readings = read_slices(slices).reduce({}, :merge)

      Result.new(readings:, usage: @usages.compact.max_by(&:percent), rate_limited: @rate_limited, errors: @errors)
    end

    private

    # Una sola richiesta si fa qui; più richieste partono insieme, ognuna nel suo thread.
    # In sviluppo i thread che caricano codice devono poterlo fare mentre questo aspetta (guida Rails sui thread).
    def read_slices(slices)
      return slices.map { |slice| read_slice(slice) } if slices.size <= 1

      threads = slices.map { |slice| Thread.new { Rails.application.executor.wrap { read_slice(slice) } } }
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads { threads.map(&:value) }
    end

    def read_slice(slice)
      client = client_builder.call(@page)
      query = "metric=#{METRICS.keys.join(',')}&period=lifetime"
      paths = slice.flat_map { |_, id| [ "#{id}/insights?#{query}", "#{id}?fields=#{POST_FIELDS}" ] }
      responses = client.batch(paths)
      @usages << client.last_usage

      slice.zip(responses.each_slice(2)).each_with_object({}) do |((publication, _), (insights, post)), readings|
        if insights.is_a?(FacebookGraph::Error)
          note(publication, insights)
        elsif (reading = reading_from(insights, post, publication))
          readings[publication.id] = reading
        else
          @errors << "#{label(publication)}: Facebook non ha dato visualizzazioni e persone raggiunte."
        end
      end
    rescue FacebookGraph::Error => error
      @usages << client&.last_usage
      note(nil, error)
      {}
    end

    def reading_from(insights, post, publication)
      values = Array(insights["data"]).to_h { |metric| [ metric["name"], metric.dig("values", 0, "value") ] }
      views, reach, activity = METRICS.keys.map { |name| values[name] }
      return unless views.is_a?(Integer) && reach.is_a?(Integer)

      # Le azioni sul post per tipo ({"share" => 8, "like" => 6, "comment" => 1}); senza condivisioni manca la voce share.
      shares = activity["share"].to_i if activity.is_a?(Hash)

      if post.is_a?(FacebookGraph::Error)
        note(publication, post) # visualizzazioni e persone si salvano lo stesso
        post = nil
      end
      total, by_type = reactions_from(post)
      Reading.new(views:, reach:, reactions: total, reactions_by_type: by_type, shares:)
    end

    # Le reazioni dal campo del post: il totale e i tipi presenti ({"like" => 12, "love" => 2}).
    # Se Facebook non le dà (errore, permesso mancante), nil.
    def reactions_from(response)
      total = response&.dig("totale", "summary", "total_count")
      return [ nil, {} ] unless total.is_a?(Integer)

      by_type = REACTION_TYPES.map(&:downcase).to_h { |type| [ type, response.dig(type, "summary", "total_count").to_i ] }
      [ total, by_type.select { |_, count| count.positive? } ]
    end


    # L'id da interrogare: quello del post, oppure per un video quello del post che lo contiene.
    def target_id(publication)
      return publication.remote_id unless publication.video?
      return publication.remote_post_id if publication.remote_post_id.present?

      client = client_builder.call(@page)
      post_id = client.get(publication.remote_id, fields: "post_id")["post_id"].to_s
      @usages << client.last_usage
      if post_id.blank?
        @errors << "#{label(publication)}: Facebook non dice in quale post si trova il video."
        return
      end

      post_id = "#{@page.external_id}_#{post_id}" unless post_id.include?("_")
      publication.update_column(:remote_post_id, post_id)
      post_id
    rescue FacebookGraph::Error => error
      note(publication, error)
      nil
    end

    def note(publication, error)
      @rate_limited ||= RATE_LIMIT_CODES.include?(error.code)
      @errors << [ (label(publication) if publication), error.message ].compact.join(": ")
    end

    def label(publication) = "pubblicazione #{publication.id} (#{publication.remote_id})"
  end
end
