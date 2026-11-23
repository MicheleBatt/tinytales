module PostsHelper
  STATUS_LABELS = { "draft" => "Bozza", "scheduled" => "Programmato", "published" => "Pubblicato" }.freeze

  def status_label(status) = STATUS_LABELS.fetch(status.to_s, status.to_s)

  def status_options
    STATUS_LABELS.map { |value, label| [ label, value ] }
  end

  def publish_time(post, format: :long)
    post.publish_at ? l(post.publish_at, format: format) : "Data da definire"
  end

  def days_label(time)
    return unless time

    days = (time.to_date - Date.current).to_i
    case days
    when 0 then "oggi"
    when 1 then "domani"
    when -1 then "ieri"
    when 2.. then "fra #{days} giorni"
    else "#{-days} giorni fa"
    end
  end

  def status_pill(post)
    if post.overdue? && post.scheduled?
      tag.span("Programmato, ora passata", class: "pill pill-late")
    else
      tag.span(status_label(post.status), class: "pill pill-#{post.status}")
    end
  end

  # Le piattaforme del post, per i messaggi di conferma: «sulla pagina Facebook», «dalle pagine Facebook e Instagram».
  # from: true per «dalla/dalle» (togliere), altrimenti «sulla/sulle» (pubblicare).
  def social_pages_phrase(post, from: false)
    order = SocialPage::PLATFORMS.keys
    platforms = post.social_pages.map(&:platform).uniq.sort_by { |platform| order.index(platform) || order.size }
                    .map { |platform| SocialPage::PLATFORMS.fetch(platform, platform) }
    return from ? "da nessuna pagina social" : "su nessuna pagina social" if platforms.empty?

    one = platforms.one?
    preposition = from ? (one ? "dalla" : "dalle") : (one ? "sulla" : "sulle")
    "#{preposition} #{one ? 'pagina' : 'pagine'} #{platforms.to_sentence(two_words_connector: ' e ', last_word_connector: ' e ')}"
  end

  def social_page_chip(page)
    tag.span(page.platform_label, class: "chip chip-#{page.platform}", title: page.name)
  end

  # Gli spunti con cui si apre la chat dell'assistente, adatti a quanto il post è già pronto.
  def assistant_hints(post)
    if post.title.blank? && post.body.blank?
      [ "Proponimi 3 idee di post per le prossime settimane, guardando calendario e avvisi della scuola ed evitando quelli già preparati",
        "Prepara un post sul prossimo appuntamento della scuola",
        "Scrivi un post che presenti la scuola alle famiglie che non la conoscono",
        "Prepara un post che ricordi le prossime chiusure del calendario scolastico" ]
    elsif post.body.blank?
      [ "Scrivi il testo del post partendo dal titolo e dalle note",
        "Proponi un titolo più chiaro",
        "Suggerisci data e ora di pubblicazione",
        "Prepara una grafica 4:5 originale per questo post, diversa da quelle degli altri post" ]
    else
      [ "Rendi il testo più breve e più caldo",
        "Controlla che date e informazioni del testo coincidano con il sito",
        "Proponi un titolo più chiaro",
        "Prepara una grafica 4:5 originale per questo post, diversa da quelle degli altri post" ]
    end
  end

  def field_error(record, attribute)
    messages = record.errors.messages_for(attribute)
    tag.span(messages.to_sentence.upcase_first, class: "errore-campo") if messages.any?
  end

  # L'indirizzo del calendario per un certo mese, tenendo i filtri attivi.
  def calendar_month_path(month)
    posts_path(request.query_parameters.except("vista", "mese").merge(vista: "calendario", mese: month.strftime("%Y-%m")))
  end

  WEEKDAYS = %w[lun mar mer gio ven sab dom].freeze

  # Gli attributi per aprire un file del post nell'anteprima a tutto schermo (controller lightbox).
  def lightbox_data(file, group: "post-media")
    { lightbox: rails_blob_path(file, disposition: "inline"), lightbox_group: group,
      lightbox_caption: file.filename.to_s, lightbox_type: file.video? ? "video" : "image",
      lightbox_download: rails_blob_path(file, disposition: "attachment") }
  end

  # I file che iniziano con PROVVISORIA_ sono segnaposto da sostituire.
  def placeholder?(attachment)
    attachment.filename.to_s.start_with?("PROVVISORIA_")
  end
end
