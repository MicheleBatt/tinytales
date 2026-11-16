require "open3"

# Il report in PDF dei post (pulsante «Esporta PDF» dell'elenco): frontespizio, premessa, indice navigabile
# e una scheda di una pagina per post, in un unico flusso dal più vecchio al più recente (le bozze senza data
# in fondo), con stato, data e quello che è ancora provvisorio.
#
# La pagina HTML (posts/report_pdf) la stampa Google Chrome senza finestra, in due passaggi:
# dal primo PDF si legge (con pdftotext) a che pagina comincia ogni scheda, e nel secondo
# quei numeri vanno nell'indice. Le schede cominciano sempre su una pagina nuova e i numeri dell'indice
# hanno larghezza fissa, quindi fra un passaggio e l'altro le pagine non si spostano.
class PostsReport
  class Error < StandardError; end

  CHROME = ENV.fetch("CHROME_BIN", "google-chrome")
  PDFTOTEXT = ENV.fetch("PDFTOTEXT_BIN", "pdftotext")
  FFMPEG = ENV.fetch("FFMPEG_BIN", "ffmpeg")
  TIMEOUT = 120
  WORK_ROOT = Rails.root.join("tmp/report")
  RESOURCES = Rails.root.join("lib/assistant/risorse")

  # Segnaposto lasciati nel testo, come «[DA CONFERMARE: data]» o un «DA COMPLETARE» isolato.
  PLACEHOLDER = /\[[^\]\n]*\bDA (?:CONFERMARE|COMPLETARE|DEFINIRE|VERIFICARE|INSERIRE)\b[^\]\n]*\]|\bDA (?:CONFERMARE|COMPLETARE|DEFINIRE)\b/
  # Lo stato dichiarato nelle note di lavoro: «Stato della bozza: PROVVISORIO: manca la data».
  NOTE_STATE = /^\s*Stato(?: della bozza)?:\s*(.+)$/i
  # Nelle note, l'elenco di ciò che manca: «Cosa manca o è provvisorio:» seguito da righe «- …».
  NOTE_MISSING = /^\s*(?:cosa manca|da confermare|da completare|mancano|manca)\b[^\n]*:\s*$/i
  MAX_FILES_SHOWN = 8

  # Nei test si sostituiscono, per non lanciare Chrome: printer.(html_path, pdf_path), text_of.(pdf_path) → [pagine].
  cattr_accessor :printer, :text_of

  Card = Data.define(:number, :post, :checks, :note_state, :note_points, :files) do
    def provisional? = checks.any? || note_points.any? || note_state&.dig(:provisional)
    def anchor = "scheda-#{number}"
  end
  FileInfo = Data.define(:position, :name, :kind, :detail, :preview, :placeholder)

  attr_reader :filters, :generated_at

  def initialize(posts, filters: [], now: Time.current)
    @posts = posts.to_a
    @filters = filters
    @generated_at = now
  end

  # Un unico flusso per data di pubblicazione, dal più vecchio; i post senza data in fondo.
  def cards
    @cards ||= @posts.sort_by { |post| [ post.publish_at ? 0 : 1, post.publish_at || Time.at(0), post.id ] }
                     .each_with_index.map do |post, index|
      Card.new(number: index + 1, post:, checks: checks(post), note_state: note_state(post),
               note_points: note_points(post), files: [])
    end
  end

  def total = cards.size
  def count(status) = @posts.count { |post| post.status == status }
  def provisional_count = cards.count(&:provisional?)

  # Le cose ancora da sistemare, viste dai dati del post. Per i pubblicati contano solo gli errori con Facebook.
  def checks(post)
    errors = post.publications.filter_map { |p| "Ultimo aggiornamento su #{p.social_page.platform_label} non riuscito: #{p.sync_error}" if p.sync_error.present? }
    return errors if post.published?

    list = []
    list << "Data di pubblicazione da definire." if post.publish_at.nil?
    list << "La data prevista (#{I18n.l(post.publish_at, format: :long)}) è passata: va scelta una nuova data." if post.date_expired?(@generated_at)
    list << "Manca il testo del post." if post.body.blank?
    post.body.to_s.scan(PLACEHOLDER).uniq.each { |text| list << "Da completare nel testo: «#{text}»." }
    list << "Mancano immagini o video." if post.media.empty?
    post.ordered_media.select { |file| file.filename.to_s.start_with?("PROVVISORIA_") }
        .each { |file| list << "Immagine provvisoria da sostituire: #{file.filename}." }
    list << "Nessuna pagina social scelta." if post.social_pages.empty?
    list + errors
  end

  # Lo stato scritto nelle note («PRONTO», «PROVVISORIO: manca…»), solo per programmati e bozze.
  def note_state(post)
    return if post.published?

    text = post.notes.to_s[NOTE_STATE, 1]&.strip
    return unless text

    ready = text.match?(/\A(?:PRONT[OA]|PROGRAMMAT[OA])\b/i) && !text.match?(/\b(?:manca|mancano|da confermare|da verificare)\b/i)
    { text:, provisional: !ready }
  end

  # I punti di «Cosa manca…» scritti nelle note, solo per programmati e bozze.
  def note_points(post)
    return [] if post.published?

    points = []
    collecting = false
    post.notes.to_s.each_line do |line|
      if line.match?(NOTE_MISSING)
        collecting = true
      elsif collecting && (point = line[/^\s*[-•]\s*(.+)$/, 1])
        points << point.strip
      elsif line.strip.present?
        collecting = false
      end
    end
    points
  end

  # Il mese di un post, per i separatori dell'indice («Novembre 2026», «Data da definire»).
  def month_label(post) = post.publish_at ? I18n.l(post.publish_at.to_date, format: "%B %Y").capitalize : "Data da definire"

  # Data e ora in breve, per l'indice: «mar 24/11/2026 · 11.30».
  def short_date(post) = post.publish_at ? I18n.l(post.publish_at, format: "%a %d/%m/%Y · %H.%M") : "da definire"

  # Il testo del post, con i segnaposto evidenziati.
  def body_html(post)
    escaped = ERB::Util.html_escape(post.body.to_s.strip)
    marked = escaped.gsub(PLACEHOLDER) { |text| %(<mark>#{text}</mark>) }
    marked.split(/\n{2,}/).map { |paragraph| "<p>#{paragraph.gsub("\n", '<br>')}</p>" }.join.html_safe
  end

  def date_line(post)
    return "Data di pubblicazione da definire" unless post.publish_at

    date = I18n.l(post.publish_at, format: :long)
    case post.status
    when "published" then "Pubblicato #{date}"
    when "scheduled" then "In uscita #{date}"
    else "Data prevista, provvisoria: #{date}"
    end
  end

  def facebook_links(post)
    return [] unless post.published?

    post.publications.filter_map(&:remote_url)
  end

  def resource_url(name) = "file://#{RESOURCES.join(name)}"

  def html(pages: {})
    ApplicationController.render(template: "posts/report_pdf", layout: false, assigns: { report: self, pages: })
  end

  def to_pdf
    WORK_ROOT.mkpath
    dir = Pathname(Dir.mktmpdir("report-", WORK_ROOT))
    prepare_files(dir)
    first = print(html, dir, "bozza")
    pages = locate(first)
    File.binread(print(html(pages:), dir, "report"))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  # A che pagina comincia ogni scheda (e la premessa): il primo foglio che contiene la sua riga di riconoscimento.
  def locate(pdf)
    texts = (text_of || method(:pdf_pages)).call(pdf)
    find = ->(marker) { texts.index { |text| text.include?(marker) }&.+(1) }
    pages = cards.to_h { |card| [ card.anchor, find.("Scheda #{card.number} di #{total}") ] }
    pages["premessa"] = find.("Premessa")
    pages.compact
  end

  private

  # Le anteprime degli allegati, ridotte (il PDF resta leggero): JPEG per le foto, un fotogramma per i video.
  def prepare_files(dir)
    cards.each do |card|
      card.post.ordered_media.each_with_index do |file, index|
        source = ActiveStorage::Blob.service.path_for(file.blob.key)
        target = dir.join("allegato-#{file.id}.jpg").to_s
        preview = File.exist?(source) && (file.video? ? video_frame(source, target) : image_preview(source, target)) ? target : nil
        card.files << FileInfo.new(position: index + 1, name: file.filename.to_s, kind: file.video? ? "video" : "immagine",
                                   detail: file_detail(file), preview: preview && "file://#{preview}",
                                   placeholder: file.filename.to_s.start_with?("PROVVISORIA_"))
      end
    end
  end

  def file_detail(file)
    meta = file.blob.metadata
    size = "#{meta['width'].to_i}×#{meta['height'].to_i}" if meta["width"] && meta["height"]
    duration = "#{meta['duration'].to_f.round} s" if file.video? && meta["duration"]
    bytes = file.blob.byte_size
    weight = bytes < 1.megabyte ? "#{(bytes / 1024.0).round} KB" : "#{format('%.1f', bytes / 1.megabyte.to_f).tr('.', ',')} MB"
    [ size, duration, weight ].compact.join(" · ")
  end

  def image_preview(source, target)
    run([ "convert", "#{source}[0]", "-auto-orient", "-resize", "800x800>", "-strip", "-quality", "78", "jpg:#{target}" ])
  end

  def video_frame(source, target)
    [ "1", "0" ].any? do |second|
      run([ FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", second, "-i", source,
            "-frames:v", "1", "-vf", "scale=900:-2", "-q:v", "3", target ]) && File.size?(target)
    end
  end

  def run(cmd)
    _output, status = Open3.capture2e(*cmd)
    status.success?
  rescue Errno::ENOENT
    false
  end

  def print(html, dir, name)
    page = dir.join("#{name}.html")
    pdf = dir.join("#{name}.pdf")
    page.write(html)
    (printer || method(:chrome_print)).call(page.to_s, pdf.to_s)
    raise Error, "Chrome non ha prodotto il PDF." unless pdf.file? && pdf.size.positive?

    pdf.to_s
  end

  def chrome_print(html_path, pdf_path)
    cmd = [ CHROME, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
            "--disable-extensions", "--disable-background-networking", "--allow-file-access-from-files",
            "--user-data-dir=#{File.dirname(html_path)}/profilo-chrome",
            "--no-pdf-header-footer", "--generate-pdf-document-outline", "--print-to-pdf=#{pdf_path}", "file://#{html_path}" ]
    Open3.popen2e(*cmd, pgroup: true) do |stdin, output, wait|
      stdin.close
      reader = Thread.new { output.read }
      unless wait.join(TIMEOUT)
        Process.kill("KILL", -wait.pid) rescue nil
        raise Error, "Chrome ci ha messo più di #{TIMEOUT / 60} minuti a preparare il PDF."
      end
      log = reader.value.to_s
      raise Error, "Chrome non è riuscito a preparare il PDF: #{log.lines.last(2).join.strip}" unless wait.value.success?
    end
  rescue Errno::ENOENT
    raise Error, "Per esportare il PDF serve Google Chrome (#{CHROME}), che non è stato trovato."
  end

  def pdf_pages(pdf)
    text, status = Open3.capture2(PDFTOTEXT, "-enc", "UTF-8", pdf, "-")
    raise Error, "Non riesco a leggere il PDF per numerare l'indice." unless status.success?

    text.split("\f")
  rescue Errno::ENOENT
    raise Error, "Per numerare l'indice serve pdftotext (pacchetto poppler-utils), che non è stato trovato."
  end
end
