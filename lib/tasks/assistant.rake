# Comandi di sola lettura per l'assistente della chat: gli fanno vedere i post nel database
# senza dargli modo di modificarli.
namespace :assistant do
  desc "Elenco dei post (per l'assistente): id, stato, data, titolo"
  task posts: :environment do
    Post.newest_first.each do |post|
      date = post.publish_at ? I18n.l(post.publish_at, format: :short) : "senza data"
      puts [ post.id, post.status, date, post.title ].join(" | ")
    end
  end

  desc "Un post completo in JSON (per l'assistente): bin/rails assistant:post ID=12"
  task post: :environment do
    post = Post.includes(publications: :social_page).find(ENV.fetch("ID"))
    data = {
      id: post.id, title: post.title, status: post.status,
      publish_at: post.publish_at&.iso8601, body: post.body, notes: post.notes,
      social_pages: post.publications.map { |p| { name: p.social_page.name, platform: p.social_page.platform,
                                                   online: p.on_social?, url: p.remote_url, error: p.sync_error } },
      media: post.ordered_media.map { |m| { filename: m.filename.to_s, content_type: m.content_type,
                                             path: ActiveStorage::Blob.service.path_for(m.blob.key) } }
    }
    puts JSON.pretty_generate(data)
  rescue KeyError
    abort "Indica il post: bin/rails assistant:post ID=12"
  rescue ActiveRecord::RecordNotFound
    abort "Nessun post con id #{ENV['ID']}."
  end

  desc "I brani della musicoteca utilizzabili, con la loro scheda (per l'assistente)"
  task musica: :environment do
    puts MusicTrack.assistant_listing
  end

  desc "Monta un video dalla ricetta di Claude: bin/rails assistant:video RICETTA=/percorso/_video.json"
  task video: :environment do
    # Brani della musicoteca per numero e allegati dei post: li trova l'app.
    VideoSetup.apply!
    video = Assistant::Video.new(ENV.fetch("RICETTA"))
    video.render!
    puts video.summary
  rescue KeyError
    abort "Indica la ricetta: bin/rails assistant:video RICETTA=/percorso/_video.json"
  rescue Assistant::Video::Error => e
    abort "Errore: #{e.message}"
  end

  desc "Foto e video della pagina Facebook della scuola (per l'assistente): elenco, anteprime o scaricamento"
  task facebook: :environment do
    media = FacebookMedia.new
    ids = ENV.fetch("IDS", "").split(",")
    case ENV["AZIONE"]
    when nil, "" then puts media.listing
    when "anteprime" then puts media.previews!(ENV.fetch("CARTELLA"), ids)
    when "scarica"
      saved = media.download!(ENV.fetch("CARTELLA"), ids)
      puts "Scaricati nella cartella di lavoro:", *saved.map { |path| "- #{path}" }
    else abort "AZIONE sconosciuta: #{ENV['AZIONE']}"
    end
  rescue KeyError
    abort "Indica la cartella di lavoro: CARTELLA=/percorso"
  rescue FacebookMedia::Error => e
    abort "Errore: #{e.message}"
  end

  desc "Una volta sola: porta in Active Storage i file delle chat ancora nelle cartelle tmp/assistant/<token>"
  task import_files: :environment do
    AssistantConversation.find_each do |conversation|
      next unless AssistantConversation::OUTBOX_ROOT.join(conversation.token).directory?

      imported, skipped = conversation.import_legacy_files!
      puts "#{conversation.token} (post #{conversation.post_id || "nuovo"}): #{imported.size} file importati" \
           "#{", tralasciati: #{skipped.sort.join(", ")}" if skipped.any?}"
    end
  end

  desc "Cancella le chat di post nuovi mai salvati, più vecchie di GIORNI (predefinito 14), con i loro file"
  task cleanup: :environment do
    days = Integer(ENV.fetch("GIORNI", "14"))
    old = AssistantConversation.where(post_id: nil).where(updated_at: ...days.days.ago)
    puts "Chat senza post più vecchie di #{days} giorni: #{old.count}"
    old.find_each do |conversation|
      puts "- #{conversation.token}, ultima attività #{I18n.l(conversation.updated_at, format: :short)}"
      conversation.destroy!
    end
  end
end
