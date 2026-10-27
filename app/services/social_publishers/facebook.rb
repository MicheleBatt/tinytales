module SocialPublishers
  # Pubblica, programma, modifica e toglie i post di una pagina Facebook con le Graph API.
  #
  # Regole di Facebook di cui tenere conto:
  # - si può programmare fra 10 minuti e 30 giorni da adesso;
  # - un post può avere più foto oppure un solo video;
  # - di un post già pubblicato si può cambiare il testo, non le foto;
  # - un'app può modificare solo i post che ha creato lei.
  class Facebook
    MIN_LEAD = 10.minutes
    MAX_LEAD = 30.days

    # Nei test si sostituisce con un client finto.
    cattr_accessor :client_builder, default: ->(page) { FacebookGraph::Client.new(page.access_token) }

    def initialize(page, client: nil)
      unless page.connected?
        raise PublishError, "La pagina «#{page.name}» non è ancora collegata a Facebook: " \
                            "esegui «bin/rails social:facebook:connect» (istruzioni nel README)."
      end

      @page = page
      @client = client || self.class.client_builder.call(page)
    end

    def publish(post, now: Time.current)
      create(post, scheduled_at: nil, now:)
    end

    def schedule(post, now: Time.current)
      check_schedule_window!(post.publish_at, now)
      create(post, scheduled_at: post.publish_at, now:)
    end

    # Un post programmato non ha ancora reazioni: lo ricreiamo con testo, file e ora nuovi.
    # Di un post pubblicato aggiorniamo il testo; le foto Facebook non le lascia cambiare.
    def update(publication, post, now: Time.current)
      if post.scheduled?
        # Prima il nuovo, poi via il vecchio: se qualcosa va storto, su Facebook resta almeno una versione.
        check_schedule_window!(post.publish_at, now)
        replacement = create(post, scheduled_at: post.publish_at, now:)
        begin
          remove(publication)
          replacement
        rescue PublishError => error
          replacement.with(warnings: [ "la versione programmata precedente non è stata tolta (#{error.message}): " \
                                       "cancellala a mano da Meta Business Suite, altrimenti uscirà due volte." ])
        end
      else
        field = publication.remote_kind == "video" ? :description : :message
        call { @client.post(publication.remote_id, { field => post.body }) }

        warnings = []
        if publication.synced_media_order != post.ordered_media.map(&:blob_id)
          warnings << "Su Facebook le foto e i video di un post già pubblicato non si possono cambiare: " \
                      "è stato aggiornato solo il testo. Per cambiare i file, spubblica il post e pubblicalo di nuovo."
        end
        Result.new(remote_id: publication.remote_id, remote_kind: publication.remote_kind,
                   remote_media_ids: publication.remote_media_ids, warnings:)
      end
    end

    # Toglie il post dalla pagina. Se su Facebook non c'è più, va bene lo stesso.
    def remove(publication)
      delete_quietly(publication.remote_id, ignore_errors: false)
      publication.remote_media_ids.each { |id| delete_quietly(id) }
    end

    private

    def create(post, scheduled_at:, now:)
      media = post.ordered_media
      videos = media.select(&:video?)
      images = media.select(&:image?)

      if videos.any? && (videos.size > 1 || images.any?)
        raise PublishError, "Su Facebook un post può avere più foto oppure un solo video, non entrambi."
      end
      raise PublishError, "Il post non ha né testo né immagini: su Facebook non uscirebbe niente." if post.body.blank? && media.empty?

      timing = scheduled_at ? { published: false, scheduled_publish_time: scheduled_at.to_i } : { published: true }

      if videos.one?
        response = upload(videos.first, "#{@page.external_id}/videos", { description: post.body, **timing }, video: true)
        Result.new(remote_id: response.fetch("id"), remote_kind: "video")
      else
        photo_ids = []
        begin
          images.each do |image|
            photo_ids << upload(image, "#{@page.external_id}/photos", { published: false, temporary: scheduled_at.present? }).fetch("id")
          end
          params = { message: post.body, **timing }
          photo_ids.each_with_index { |id, i| params[:"attached_media[#{i}]"] = { media_fbid: id } }
          response = call { @client.post("#{@page.external_id}/feed", params) }
        rescue PublishError
          photo_ids.each { |id| delete_quietly(id) }
          raise
        end
        Result.new(remote_id: response.fetch("id"), remote_kind: "feed", remote_media_ids: photo_ids)
      end
    end

    def upload(attachment, path, params, video: false)
      attachment.blob.open do |file|
        source = { io: file, filename: attachment.filename.to_s, content_type: attachment.content_type }
        call { @client.post(path, params, files: { "source" => source }, video:) }
      end
    end

    def check_schedule_window!(time, now)
      if time < now + MIN_LEAD
        raise PublishError, "Facebook programma i post solo da 10 minuti in poi: sposta l'ora più avanti, " \
                            "oppure aspetta l'ora e usa «Pubblica»."
      elsif time > now + MAX_LEAD
        raise PublishError, "Facebook programma i post al massimo 30 giorni prima: " \
                            "tienilo in bozza e programmalo più avanti."
      end
    end

    def delete_quietly(id, ignore_errors: true)
      call { @client.delete(id) }
    rescue PublishError => error
      raise unless ignore_errors || error.cause.is_a?(FacebookGraph::Error) && missing_object?(error.cause)
    end

    # Codice 100 con sottocodice 33: l'oggetto non esiste più (già cancellato da Facebook o a mano).
    def missing_object?(error)
      error.code.to_i == 100 && error.subcode.to_i == 33
    end

    def call
      yield
    rescue FacebookGraph::Error => error
      raise PublishError, error.message
    end
  end
end
