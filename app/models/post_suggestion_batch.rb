# Una sessione di «Proponi post con Claude»: le proposte di post che Claude prepara in background.
# Finché la persona non le approva restano fuori dal database, in tmp/proposte/<token>:
# un file proposte.json e i file (grafiche, foto) da allegare.
# Approvando, quelle tenute diventano bozze vere; annullando, la cartella viene cancellata.
class PostSuggestionBatch
  class InvalidProposal < StandardError; end

  ROOT = Rails.root.join("tmp/proposte")
  TOKEN_FORMAT = /\A[a-f0-9-]{36}\z/
  MAX_PROPOSALS = 12
  HORIZON = 3.months
  MEDIA = /\.(jpe?g|png|gif|webp|mp4|mov|m4v|webm)\z/i

  attr_reader :token

  def self.find(token)
    new(token) if token.to_s.match?(TOKEN_FORMAT)
  end

  def initialize(token)
    raise ArgumentError, "token non valido" unless token.to_s.match?(TOKEN_FORMAT)

    @token = token.to_s
  end

  # La cartella di lavoro: Claude può scriverci, e da qui si servono le anteprime.
  def outbox = ROOT.join(token).tap(&:mkpath)

  # Il motore della chat lo usa per riprendere una conversazione: qui si parte sempre da zero.
  def claude_session_id = nil

  def proposals
    file = ROOT.join(token, "proposte.json")
    file.file? ? JSON.parse(file.read) : []
  end

  # Controlla una proposta arrivata da Claude, copia nella cartella di lavoro i file presi dal sito
  # e la salva. Restituisce la proposta salvata, con il suo id.
  def add(raw, today: Date.current)
    list = proposals
    raise InvalidProposal, "raggiunto il massimo di #{MAX_PROPOSALS} proposte" if list.size >= MAX_PROPOSALS

    title = raw["titolo"].to_s.strip
    raise InvalidProposal, "manca il titolo" if title.blank?

    publish_at = parse_time(raw["data"])
    raise InvalidProposal, "«#{title}»: data mancante o non valida" unless publish_at
    unless publish_at.to_date.between?(today, today + HORIZON)
      raise InvalidProposal, "«#{title}»: la data #{I18n.l(publish_at, format: :short)} è fuori dai prossimi tre mesi"
    end

    proposal = {
      "id" => (list.map { |p| p["id"] }.max || 0) + 1,
      "title" => title.truncate(200),
      "body" => raw["testo"].to_s.strip,
      "notes" => raw["note"].to_s.strip,
      "reason" => raw["motivo"].to_s.strip,
      "publish_at" => publish_at.iso8601,
      "files" => Array(raw["file"]).filter_map { |path| import_file(path) }.uniq.first(10)
    }
    ROOT.join(token, "proposte.json").write(JSON.pretty_generate(list << proposal))
    proposal
  end

  # Claude consegna ogni proposta come file JSON nella cartella di lavoro (proposta-01.json, …).
  # Qui si leggono quelli nuovi, nell'ordine dei nomi; una volta letti si rinominano, così non si rileggono.
  # Restituisce, per ciascuno, la proposta salvata oppure il motivo dello scarto.
  def import_pending(today: Date.current)
    outbox.glob("proposta-*.json").sort.map do |path|
      result =
        begin
          raw = JSON.parse(path.read)
          raw.is_a?(Hash) ? add(raw, today:) : "#{path.basename}: non è una proposta"
        rescue JSON::ParserError
          "#{path.basename}: il file non è JSON valido"
        rescue InvalidProposal => error
          error.message
        end
      path.rename(path.dirname.join("_letta-#{path.basename}"))
      result
    end
  end

  def file(name)
    name = File.basename(name.to_s)
    path = outbox.join(name)
    path if name.match?(MEDIA) && path.file? && path.realpath.to_s.start_with?(outbox.realpath.to_s + "/")
  end

  # Crea le bozze delle proposte tenute (nell'ordine di Claude), tutte sulla pagina Facebook,
  # poi cancella la cartella di lavoro. Tutto o niente.
  def approve!(ids)
    ids = Array(ids).map(&:to_i)
    chosen = proposals.select { |p| ids.include?(p["id"]) }
    pages = SocialPage.where(platform: "facebook")

    posts = Post.transaction do
      chosen.map do |p|
        post = Post.new(title: p["title"], body: p["body"].presence, notes: p["notes"].presence,
                        publish_at: Time.zone.parse(p["publish_at"]), status: :draft, social_pages: pages)
        post.media = p["files"].filter_map { |name| file(name) }.map do |path|
          { io: path.open, filename: path.basename.to_s, content_type: Marcel::MimeType.for(path) }
        end
        post.save!
        post
      end
    end
    discard!
    posts
  end

  def discard!
    FileUtils.rm_rf(ROOT.join(token))
    FileUtils.rm_rf(AssistantRunner::POLICY_ROOT.join(token)) # le regole di ImageMagick di questa sessione
  end

  private

  def parse_time(value)
    return unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/)

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # Un file può venire dalla cartella di lavoro (grafiche create da Claude) o dalle immagini del sito:
  # in questo secondo caso lo copiamo, così tutto ciò che serve sta in un posto solo.
  def import_file(path)
    path = Pathname(path.to_s.strip)
    return unless path.absolute? && path.file? && path.basename.to_s.match?(MEDIA)

    real = path.realpath.to_s
    return path.basename.to_s if real.start_with?(outbox.realpath.to_s + "/")

    site_assets = AssistantRunner::SITE_ROOT.join("assets").realpath.to_s + "/"
    return unless real.start_with?(site_assets)

    name = path.basename.to_s
    name = "#{path.basename('.*')}-#{SecureRandom.hex(2)}#{path.extname}" if outbox.join(name).exist?
    FileUtils.cp(real, outbox.join(name))
    name
  rescue Errno::ENOENT
    nil
  end
end
