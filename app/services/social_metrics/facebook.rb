module SocialMetrics
  # Le statistiche dei post di una pagina Facebook (serve il permesso read_insights).
  #
  # - Visualizzazioni: post_media_view. Persone raggiunte: post_total_media_view_unique.
  #   Facebook le dà solo come totale dalla pubblicazione (period=lifetime).
  # - Tutti i post si leggono con una sola richiesta (batch, fino a 50); oltre, più richieste in parallelo.
  # - Un video pubblicato dall'app è spesso un reel: l'id che abbiamo è quello del video, che non ha statistiche.
  #   Si chiede una volta l'id del post che lo contiene (post_id) e lo si ricorda in publications.remote_post_id.
  class Facebook
    METRICS = { "post_media_view" => :views, "post_total_media_view_unique" => :reach }.freeze

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
      slices = targets.each_slice(FacebookGraph::Client::BATCH_LIMIT).to_a
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
      responses = client.batch(slice.map { |_, id| "#{id}/insights?#{query}" })
      @usages << client.last_usage

      slice.zip(responses).each_with_object({}) do |((publication, _), response), readings|
        if response.is_a?(FacebookGraph::Error)
          note(publication, response)
        elsif (reading = reading_from(response))
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

    def reading_from(response)
      values = Array(response["data"]).to_h { |metric| [ metric["name"], metric.dig("values", 0, "value") ] }
      views, reach = METRICS.keys.map { |name| values[name] }
      Reading.new(views:, reach:) if views.is_a?(Integer) && reach.is_a?(Integer)
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
