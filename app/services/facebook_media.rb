require "net/http"
require "open3"

# Foto e video pubblicati sulla pagina Facebook della scuola, per Claude (bin/assistant facebook):
# l'elenco, un foglio di anteprime numerate e lo scaricamento nella cartella di lavoro della chat.
#
# Claude indica solo dei numeri (gli id di Facebook); gli indirizzi dei file li prende l'app dalle Graph API:
# - solo contenuti della pagina della scuola: l'id deve comparire nell'elenco della pagina;
# - solo dai server di Facebook (fbcdn.net), in https, senza seguire rimandi altrove;
# - solo immagini e video, riconosciuti dal contenuto del file, entro un limite di dimensione;
# - si scrive solo nella cartella di lavoro di una chat (o di una richiesta di proposte).
class FacebookMedia
  class Error < StandardError; end

  MAX_ITEMS = 300
  MAX_DOWNLOADS = 10
  MAX_PREVIEWS = 12
  MAX_IMAGE_SIZE = 30.megabytes
  MAX_VIDEO_SIZE = 300.megabytes
  CDN_HOST = /\A[a-z0-9.-]+\.fbcdn\.net\z/
  ID = /\A\d{5,30}\z/
  EXTENSIONS = { "image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp",
                 "video/mp4" => ".mp4", "video/quicktime" => ".mov" }.freeze
  FONT = Rails.root.join("lib/assistant/risorse/font/Nunito-800.ttf").to_s

  Item = Data.define(:kind, :id, :created_at, :text, :width, :height, :duration, :source, :preview) do
    def video? = kind == "video"
  end

  # Chi scarica un indirizzo in un file: nei test si sostituisce, per non andare in rete.
  cattr_accessor :fetcher

  def initialize(page = SocialPage.find_by(platform: "facebook"), client: nil)
    raise Error, "La pagina Facebook non è collegata all'app." unless page&.connected?

    @page = page
    @client = client || FacebookGraph::Client.new(page.access_token)
  end

  # Foto e video della pagina, dai più recenti.
  def items
    @items ||= (photos + videos).sort_by { |item| item.created_at || Time.at(0) }.reverse.first(MAX_ITEMS)
  end

  def listing
    return "La pagina Facebook non ha foto né video." if items.empty?

    lines = items.map do |item|
      size = item.video? ? "#{item.duration.to_f.round} s" : "#{item.width}×#{item.height}"
      date = item.created_at ? I18n.l(item.created_at.to_date, format: :default) : "?"
      text = item.text.to_s.squish.truncate(90).presence || "(senza testo)"
      "#{item.kind} #{item.id} | #{date} | #{size} | #{text}"
    end
    "#{items.count { |i| !i.video? }} foto e #{items.count(&:video?)} video della pagina «#{@page.name}», dai più recenti " \
      "(tipo id | data | dimensioni | testo del post):\n#{lines.join("\n")}"
  end

  # Un foglio con le anteprime numerate di alcune foto o video, da guardare con Read prima di scegliere.
  def previews!(dir, ids)
    outbox = self.class.outbox!(dir)
    chosen = find!(ids, MAX_PREVIEWS)
    thumbs = []
    chosen.each_with_index do |item, i|
      thumbs << fetch_media(item.preview, File.join(outbox, "_anteprima-facebook-#{i + 1}"), MAX_IMAGE_SIZE, images_only: true)
    end
    sheet = File.join(outbox, "_anteprime-facebook.jpg")
    labels = chosen.each_with_index.flat_map { |item, i| [ "-label", "#{i + 1} · #{item.kind} #{item.id}", thumbs[i] ] }
    run_montage([ "montage", "-font", FONT, "-pointsize", "14", *labels, "-tile", "4x", "-geometry", "260x260>+8+8",
                  "-background", "white", "jpg:#{sheet}" ])
    legend = chosen.each_with_index.map { |item, i| "#{i + 1}. #{item.kind} #{item.id}#{' (video: anteprima)' if item.video?}" }
    "Anteprime salvate in #{sheet} (guardale con Read):\n#{legend.join("\n")}"
  ensure
    thumbs&.each { |path| File.delete(path) if File.exist?(path) }
  end

  # Scarica le foto (alla risoluzione più alta) o i video nella cartella di lavoro: facebook-<id>.jpg / .mp4.
  def download!(dir, ids)
    outbox = self.class.outbox!(dir)
    find!(ids, MAX_DOWNLOADS).map do |item|
      base = File.join(outbox, "facebook-#{item.id}")
      fetch_media(item.source, base, item.video? ? MAX_VIDEO_SIZE : MAX_IMAGE_SIZE)
    end
  end

  # La cartella di lavoro di una chat o di una richiesta di proposte, come per i video.
  def self.outbox!(dir)
    real = File.realpath(dir.to_s)
    raise Error, "Non è una cartella: #{dir}" unless File.directory?(real)

    Assistant::Video.outbox_of(File.join(real, "x"))
  rescue Errno::ENOENT, Errno::EACCES
    raise Error, "Cartella non trovata: #{dir}"
  rescue Assistant::Video::Error
    raise Error, "Si scarica solo nella cartella di lavoro della chat: #{dir}"
  end

  private

  def photos
    paged("#{@page.external_id}/photos", type: "uploaded", fields: "id,created_time,name,width,height,images").map do |p|
      images = Array(p["images"]).sort_by { |image| image["width"].to_i }
      preview = images.find { |image| image["width"].to_i >= 320 } || images.last
      Item.new(kind: "foto", id: p["id"].to_s, created_at: time(p["created_time"]), text: p["name"],
               width: p["width"], height: p["height"], duration: nil, source: images.last&.dig("source"),
               preview: preview&.dig("source"))
    end
  end

  def videos
    paged("#{@page.external_id}/videos", fields: "id,created_time,description,title,length,source,picture").map do |v|
      Item.new(kind: "video", id: v["id"].to_s, created_at: time(v["created_time"]), text: v["description"].presence || v["title"],
               width: nil, height: nil, duration: v["length"], source: v["source"], preview: v["picture"])
    end
  end

  # Tutte le pagine dei risultati, fino a MAX_ITEMS.
  def paged(path, params)
    results = []
    after = nil
    loop do
      response = @client.get(path, params.merge(limit: 100, after:).compact)
      results.concat(Array(response["data"]))
      after = response.dig("paging", "cursors", "after")
      break if response.dig("paging", "next").blank? || after.blank? || results.size >= MAX_ITEMS
    end
    results
  rescue FacebookGraph::Error => e
    raise Error, e.message
  end

  def time(value) = value.present? ? Time.zone.parse(value) : nil

  def find!(ids, max)
    ids = Array(ids).map(&:to_s).uniq
    raise Error, "Indica da 1 a #{max} id." unless ids.size.between?(1, max)
    raise Error, "Gli id sono numeri, come compaiono nell'elenco." unless ids.all? { |id| id.match?(ID) }

    ids.map do |id|
      items.find { |item| item.id == id } or raise Error, "L'id #{id} non è fra le foto e i video della pagina della scuola."
    end
  end

  # Scarica nel file «base + estensione giusta»; prima in un file «_…» provvisorio, rinominato solo se va bene.
  def fetch_media(url, base, max_size, images_only: false)
    uri = URI(url.to_s)
    raise Error, "Facebook non ha dato l'indirizzo del file." unless uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(CDN_HOST)

    partial = File.join(File.dirname(base), "_scarico-#{File.basename(base)}")
    (fetcher || method(:http_fetch)).call(uri, partial, max_size)
    type = Marcel::MimeType.for(Pathname(partial))
    extension = EXTENSIONS[type]
    raise Error, "Il file scaricato non è un'immagine o un video (#{type})." unless extension
    raise Error, "Il file scaricato non è un'immagine (#{type})." if images_only && !type.start_with?("image/")

    target = "#{base}#{extension}"
    File.rename(partial, target)
    target
  ensure
    File.delete(partial) if partial && File.exist?(partial)
  end

  def http_fetch(uri, path, max_size)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 120) do |http|
      http.request(Net::HTTP::Get.new(uri)) do |response|
        raise Error, "Facebook ha risposto con l'errore HTTP #{response.code}." unless response.is_a?(Net::HTTPOK)
        raise Error, "Il file supera il limite di #{max_size / 1.megabyte} MB." if response.content_length.to_i > max_size

        written = 0
        File.open(path, "wb") do |file|
          response.read_body do |chunk|
            written += chunk.bytesize
            raise Error, "Il file supera il limite di #{max_size / 1.megabyte} MB." if written > max_size

            file.write(chunk)
          end
        end
      end
    end
  rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
    raise Error, "Facebook non risponde (#{e.class.name.demodulize}): riprova tra poco."
  end

  def run_montage(cmd)
    output, status = Open3.capture2e(*cmd)
    raise Error, "Non sono riuscito a comporre le anteprime: #{output.lines.last(3).join.strip}" unless status.success?
  rescue Errno::ENOENT
    raise Error, "ImageMagick (montage) non è installato."
  end
end
