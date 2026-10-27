require "io/console"

namespace :social do
  namespace :facebook do
    desc "Collega la pagina Facebook all'app: chiede App ID, App Secret e un token utente, salva il token della pagina"
    task connect: :environment do
      page = SocialPage.find_by!(platform: "facebook")
      puts "Collegamento della pagina «#{page.name}» (#{page.url})"
      puts "Le istruzioni per ottenere i dati richiesti sono nel README, sezione «Collegare la pagina Facebook»."
      puts

      app_id = ask("App ID")
      app_secret = ask("App Secret", secret: true)
      user_token = ask("Token utente (da Graph API Explorer)", secret: true)

      # 1. Il token utente dura un'ora: lo scambiamo con uno di lunga durata.
      exchange = FacebookGraph::Client.new(nil).get("oauth/access_token",
        grant_type: "fb_exchange_token", client_id: app_id, client_secret: app_secret, fb_exchange_token: user_token)
      long_user_token = exchange.fetch("access_token")

      # 2. Con il token di lunga durata, il token della pagina non scade.
      accounts = FacebookGraph::Client.new(long_user_token).get("me/accounts", fields: "id,name,link,access_token,tasks")
      pages = accounts.fetch("data", [])
      abort "Il tuo account non gestisce nessuna pagina, o il token non ha il permesso pages_show_list." if pages.empty?

      slug = URI(page.url).path.delete("/").downcase
      chosen = pages.find { |p| p["link"].to_s.downcase.include?(slug) || p["id"] == page.external_id }
      unless chosen
        puts "Pagine trovate:"
        pages.each_with_index { |p, i| puts "  #{i + 1}. #{p['name']} (#{p['id']})" }
        chosen = pages[ask("Numero della pagina della scuola").to_i - 1] or abort "Scelta non valida."
      end

      missing = %w[CREATE_CONTENT MANAGE] - Array(chosen["tasks"])
      puts "Attenzione: sulla pagina ti mancano i permessi #{missing.join(', ')}." if missing.any?

      page.update!(external_id: chosen.fetch("id"), access_token: chosen.fetch("access_token"))
      puts
      puts "Collegata: #{chosen['name']} (id #{chosen['id']}). Verifica con: bin/rails social:facebook:check"
    rescue FacebookGraph::Error => error
      abort "Collegamento non riuscito. #{error.message}"
    end

    desc "Controlla che il token della pagina Facebook funzioni"
    task check: :environment do
      page = SocialPage.find_by!(platform: "facebook")
      abort "La pagina non è collegata: esegui bin/rails social:facebook:connect" unless page.connected?

      info = FacebookGraph::Client.new(page.access_token).get(page.external_id, fields: "name,link,followers_count")
      puts "OK: #{info['name']} · #{info['link']} · follower: #{info['followers_count'] || '?'}"
    rescue FacebookGraph::Error => error
      abort "Il token non funziona. #{error.message}"
    end

    def ask(label, secret: false)
      print "#{label}: "
      value = secret ? $stdin.noecho(&:gets).tap { puts } : $stdin.gets
      value.to_s.strip.presence or abort "#{label} mancante."
    end
  end
end
