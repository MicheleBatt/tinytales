require "test_helper"

class PostsReportTest < ActiveSupport::TestCase
  setup { travel_to Time.zone.local(2026, 11, 16, 10, 0) }

  teardown do
    PostsReport.printer = nil
    PostsReport.text_of = nil
  end

  def report(posts = Post.all, **options)
    PostsReport.new(posts.includes(:social_pages, publications: :social_page, media_attachments: :blob).order(:publish_at), **options)
  end

  test "un unico flusso dal post più vecchio al più recente, con quelli senza data in fondo" do
    assert_equal [ posts(:open_day), posts(:mensa), posts(:promemoria), posts(:festa_di_natale) ], report.cards.map(&:post)
    assert_equal (1..4).to_a, report.cards.map(&:number)
    assert_equal 2, report.count("draft")
  end

  test "l'ordine non dipende da quello scelto nell'elenco" do
    reversed = Post.order(publish_at: :desc)
    assert_equal report.cards.map(&:post), PostsReport.new(reversed).cards.map(&:post)
  end

  test "mese e data breve per l'indice" do
    assert_equal "Ottobre 2026", report.month_label(posts(:open_day))
    assert_equal "Data da definire", report.month_label(posts(:festa_di_natale))
    assert_equal "lun 26/10/2026 · 10.51", report.short_date(posts(:open_day))
  end

  test "dalle note si prendono i punti di «Cosa manca», non tutte le note" do
    post = posts(:mensa)
    post.notes = "Stato della bozza: PROVVISORIO\nCosa manca o è provvisorio:\n- FOTO: chiedere alle maestre\n- DATA da confermare\n\nNote:\n- fonte: sito"
    assert_equal [ "FOTO: chiedere alle maestre", "DATA da confermare" ], report.note_points(post)
    post.notes = "Note libere senza elenco"
    assert_empty report.note_points(post)
    assert_empty report.note_points(posts(:open_day))
  end

  test "per una bozza si segnala quello che manca, per un pubblicato no" do
    post = posts(:festa_di_natale)
    post.update_columns(body: "La festa sarà [DA CONFERMARE: giorno e ora] in salone. Orario DA DEFINIRE")
    checks = report.checks(post.reload)

    assert_includes checks, "Data di pubblicazione da definire."
    assert_includes checks, "Da completare nel testo: «[DA CONFERMARE: giorno e ora]»."
    assert_includes checks, "Da completare nel testo: «DA DEFINIRE»."
    assert_includes checks, "Mancano immagini o video."
    assert_includes report.checks(posts(:mensa)), "La data prevista (giovedì 12 novembre 2026, ore 20.30) è passata: va scelta una nuova data."
    assert_empty report.checks(posts(:open_day)), "di un post già uscito non si chiede di completare nulla"
  end

  test "gli errori di sincronizzazione si segnalano anche per i pubblicati" do
    publications(:open_day_facebook).update!(sync_error: "token scaduto")
    assert_equal [ "Ultimo aggiornamento su Facebook non riuscito: token scaduto" ], report.checks(posts(:open_day).reload)
  end

  test "lo stato scritto nelle note dice se la bozza è pronta o provvisoria" do
    post = posts(:mensa)
    {
      "Stato della bozza: PRONTO\nNote: fonti dal sito." => false,
      "Stato della bozza: PRONTO (le foto sarebbero un di più)" => false,
      "Stato: PROGRAMMATO per lunedì" => false,
      "Stato della bozza: PROVVISORIO: manca la data" => true,
      "Stato della bozza: testo pronto, manca l'immagine" => true,
      "Stato della bozza: PRONTO, manca solo la locandina" => true
    }.each do |notes, provisional|
      post.notes = notes
      assert_equal provisional, report.note_state(post)[:provisional], notes
    end
    post.notes = "Note libere"
    assert_nil report.note_state(post)
    assert_nil report.note_state(posts(:open_day))
  end

  test "nel testo i segnaposto sono evidenziati e l'HTML è al sicuro" do
    post = Post.new(body: "Ciao <b>famiglie</b>!\n\nVi aspettiamo [DA COMPLETARE: luogo].\nA presto")
    html = report.body_html(post)
    assert_equal "<p>Ciao &lt;b&gt;famiglie&lt;/b&gt;!</p><p>Vi aspettiamo <mark>[DA COMPLETARE: luogo]</mark>.<br>A presto</p>", html
  end

  test "la pagina del report ha frontespizio, premessa, indice e una scheda per post" do
    html = report(filters: [ "stato: bozza" ]).html(pages: { "premessa" => 2, "scheda-1" => 6 })
    assert_includes html, "Report dei post"
    assert_includes html, "DOCUMENTO INTERNO"
    assert_includes html, "quasi uno al giorno"
    assert_includes html, "incuriosire"
    assert_includes html, "realtà viva e vegeta"
    assert_includes html, "informazione e marketing insieme"
    assert_includes html, "sviluppata interamente da <strong>Michele Battistelli</strong>"
    assert_includes html, "open day, giornate aperte, merende aperte"
    assert_includes html, "cambieranno certamente"
    assert_includes html, "pubblicati automaticamente"
    assert_includes html, "stato: bozza"
    assert_includes html, %(<a href="#scheda-1">6</a>)
    assert_includes html, "Scheda 4 di 4"
    assert_includes html, "https://www.facebook.com/1234_999"
    assert_includes html, %(<tr class="mese"><td colspan="6">Ottobre 2026</td></tr>)
    assert_not_includes html, "Manca la data della festa.", "le note di lavoro intere non finiscono nel report"
    assert_equal 4, html.scan(%(<section class="scheda")).size
  end

  test "le pagine dell'indice si ricavano dal primo PDF" do
    PostsReport.text_of = ->(_pdf) { [ "copertina", "Premessa ...", "Indice", "Scheda 1 di 4", "Scheda 2 di 4", "segue", "Scheda 3 di 4", "Scheda 4 di 4" ] }
    pages = report.locate("finto.pdf")
    assert_equal({ "premessa" => 2, "scheda-1" => 4, "scheda-2" => 5, "scheda-3" => 7, "scheda-4" => 8 }, pages)
  end

  test "il PDF si stampa in due passaggi, con i numeri di pagina nel secondo, e i file temporanei spariscono" do
    printed = []
    folders = []
    PostsReport.printer = lambda do |html_path, pdf_path|
      folders << File.dirname(html_path)
      printed << File.read(html_path)
      File.write(pdf_path, "%PDF-#{printed.size}")
    end
    PostsReport.text_of = ->(_pdf) { [ "", "Premessa", "", "Scheda 1 di 4", "Scheda 2 di 4", "Scheda 3 di 4", "Scheda 4 di 4" ] }

    assert_equal "%PDF-2", report.to_pdf
    assert_equal 2, printed.size
    assert_not_includes printed.first, %(<a href="#scheda-1">4</a>)
    assert_includes printed.last, %(<a href="#scheda-1">4</a>)
    assert_equal 1, folders.uniq.size
    assert_not File.exist?(folders.first), "la cartella temporanea viene cancellata"
  end

  test "se Chrome non produce il file, l'errore è chiaro" do
    PostsReport.printer = ->(_html, _pdf) { }
    error = assert_raises(PostsReport::Error) { report.to_pdf }
    assert_match "Chrome", error.message
  end

  test "con Chrome vero: una pagina esatta per post e indice numerato" do
    skip "serve Google Chrome" unless system("command -v #{PostsReport::CHROME} > /dev/null 2>&1")
    skip "serve pdftotext" unless system("command -v #{PostsReport::PDFTOTEXT} > /dev/null 2>&1")

    pdf = report.to_pdf
    assert pdf.start_with?("%PDF")
    text = Tempfile.create([ "report", ".pdf" ]) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      `#{PostsReport::PDFTOTEXT} -enc UTF-8 #{file.path} -`
    end
    pages = text.split("\f").reject(&:blank?)
    assert_equal 7, pages.size, "copertina, premessa, indice e 4 schede di una pagina"
    assert_includes pages[1], "Premessa"
    (1..4).each { |n| assert_includes pages[2 + n], "Scheda #{n} di 4" }
    assert_includes pages[2], "Open Day di novembre"
    assert_equal %w[4 5 6 7], pages[2].scan(/^\s*([4-7])\s*$/).flatten.uniq.sort, "i numeri di pagina delle schede nell'indice"
  end
end
