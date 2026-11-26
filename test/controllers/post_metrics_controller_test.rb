require "test_helper"

# Visualizzazioni e persone raggiunte nelle pagine: si mostrano subito quelle salvate, poi il browser chiede
# quelle aggiornate (PostsController#stats). Il report le aggiorna prima di prepararsi.
class PostMetricsControllerTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.local(2026, 11, 16, 16, 0) # prima che esca «Promemoria», programmato per il 18/11
    @post = posts(:open_day)
    @open_day = publications(:open_day_facebook)
  end

  def save_readings
    PublicationMetric.record!(@open_day, views: 455, reach: 200, at: Time.zone.local(2026, 11, 14, 9))
    PublicationMetric.record!(@open_day, views: 916, reach: 320, at: Time.zone.local(2026, 11, 15, 18, 30))
  end

  test "lista e griglia mostrano i numeri salvati, con le icone, e chiedono quelli aggiornati senza aspettare Facebook" do
    save_readings
    %w[lista griglia].each do |view|
      get posts_path(vista: view)
      assert_response :success
      assert_select ".elenco-testa span", text: "Statistiche"
      assert_select "#metriche-#{@post.id}.riga-metriche" do
        assert_select ".metrica[title=Visualizzazioni] svg.icona-statistica"
        assert_select ".metrica[title=Visualizzazioni] .metrica-numero", text: "916"
        assert_select ".metrica[title='Persone raggiunte'] .metrica-numero", text: "320"
      end
      assert_select ".elenco-post[data-controller=stats-refresh][data-stats-refresh-url-value=?]",
                    statistiche_posts_path(ids: @post.id.to_s, contesto: "elenco")
    end
    assert_select ".elenco-post.vista-griglia"
    assert_empty @facebook.batches
  end

  def save_readings_with_reactions
    save_readings
    PublicationMetric.record!(@open_day, views: 1000, reach: 350, reactions: 21, reactions_by_type: { "love" => 2, "like" => 19 },
                                         at: Time.zone.local(2026, 11, 16, 9))
  end

  test "con le reazioni: terza misura in elenco, riquadro con il dettaglio per tipo e terzo grafico nella pagina" do
    save_readings_with_reactions
    get posts_path(vista: "lista")
    assert_select "#metriche-#{@post.id} .metrica[title=Reazioni] .metrica-numero", text: "21"

    get post_path(@post)
    assert_select "#statistiche-#{@post.id} .statistica-reactions" do
      assert_select ".statistica-etichetta", text: "REAZIONI"
      assert_select ".statistica-numero", text: "21"
      assert_select ".statistica-tipi span[title='Mi piace']", text: "👍 19"
      assert_select ".statistica-tipi span[title=Love]", text: "❤️ 2"
    end
    assert_select "#statistiche-#{@post.id} .statistica-reactions .statistica-variazione", count: 0, message: "il giorno prima non c'erano"
    assert_select "#grafici-#{@post.id} figure.grafico", count: 3
    assert_select "#grafici-#{@post.id} figcaption", text: "Reazioni"
  end

  test "senza reazioni lette, la terza misura e il terzo grafico non compaiono" do
    save_readings
    get post_path(@post)
    assert_select ".statistica-reactions", count: 0
    assert_select "#grafici-#{@post.id} figure.grafico", count: 2
    get posts_path(vista: "lista")
    assert_select "#metriche-#{@post.id} .metrica[title=Reazioni]", count: 0
  end

  test "l'elenco si ordina anche per reazioni; il report le mostra con il dettaglio" do
    save_readings_with_reactions
    other = Post.create!(title: "Altro pubblicato", body: "Testo", status: :published, publish_at: Time.zone.local(2026, 11, 10, 9))
    other_publication = Publication.create!(post: other, social_page: social_pages(:facebook), remote_id: "1234_777", remote_kind: "feed")
    PublicationMetric.record!(other_publication, views: 5, reach: 5, reactions: 40, at: Time.zone.local(2026, 11, 16, 9))

    titles = ->(sort) { get posts_path(vista: "lista", q: { s: sort }); css_select(".riga h3").map(&:text) }
    assert_equal [ other.title, @post.title ], titles.("reactions desc").first(2)
    assert_equal [ @post.title, other.title ], titles.("reactions asc").first(2)
    assert_select "#q_s option", text: "Più reazioni"

    printed = []
    PostsReport.printer = ->(html, pdf_path) { printed << File.read(html); File.write(pdf_path, "%PDF-1.4 finto") }
    PostsReport.text_of = ->(_pdf) { [] }
    get report_posts_path
    card = Nokogiri::HTML(printed.last).css(".scheda").find { |section| section.at_css("h2").text == @post.title }
    assert_equal [ "VISUALIZZAZIONI", "PERSONE RAGGIUNTE", "REAZIONI" ], card.css(".statistica .etichetta").map { |e| e.text.strip }
    assert_equal [ "👍 19", "❤️ 2" ], card.css(".statistica .tipi span").map(&:text)
    assert_equal 3, card.css(".grafici svg.trend-chart").size
  ensure
    PostsReport.printer = nil
    PostsReport.text_of = nil
  end

  test "i post non pubblicati non hanno numeri né letture" do
    save_readings
    get posts_path(q: { status_eq: "draft" })
    assert_select ".riga-metriche .metrica", count: 0
    assert_select "[data-controller=stats-refresh]", count: 0
  end

  test "il calendario non chiede le statistiche dell'elenco" do
    get posts_path(vista: "calendario")
    assert_select "[data-controller=stats-refresh]", count: 0
  end

  test "l'aggiornamento dell'elenco legge da Facebook e sostituisce i numeri delle righe" do
    save_readings
    @facebook.insights("1234_999", views: 1000, reach: 350)

    get statistiche_posts_path(ids: "#{@post.id},#{posts(:mensa).id}", contesto: "elenco")
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_select "turbo-stream[action=replace][target=metriche-#{@post.id}] .metrica-numero", text: "1.000"
    assert_select "turbo-stream[target=metriche-#{posts(:mensa).id}] .metrica", count: 0
    assert_equal 1000, @open_day.latest_metric.total_views
  end

  test "la pagina del post scrive i numeri per esteso e mostra i due grafici dell'andamento" do
    save_readings
    get post_path(@post)
    assert_select "#statistiche-#{@post.id}" do
      assert_select ".statistica-etichetta", text: "VISUALIZZAZIONI"
      assert_select ".statistica-etichetta", text: "PERSONE RAGGIUNTE"
      assert_select ".statistica-numero", text: "916"
      assert_select ".statistica-numero", text: "320"
      assert_select ".statistica-variazione", text: "+461 dal 14 nov"
      assert_select ".statistica-variazione", text: "+120 dal 14 nov"
    end
    assert_select "#grafici-#{@post.id} .grafici-periodo", text: /2 giorni di lettura, dal 14 nov al 15 nov 2026/
    assert_select "#grafici-#{@post.id} figure.grafico", count: 2
    assert_select "#grafici-#{@post.id} svg.trend-chart", count: 2
    assert_select "#grafici-#{@post.id} figcaption", text: "Visualizzazioni"
    assert_select "#grafici-#{@post.id} figcaption", text: "Persone raggiunte"
    assert_select "span[hidden][data-controller=stats-refresh][data-stats-refresh-url-value=?]",
                  statistiche_posts_path(ids: @post.id.to_s, contesto: "pagina")
  end

  test "l'elenco si ordina per visualizzazioni e persone raggiunte, nei due versi; chi non ha numeri va in fondo" do
    save_readings
    other = Post.create!(title: "Altro pubblicato", body: "Testo", status: :published, publish_at: Time.zone.local(2026, 11, 10, 9))
    other_publication = Publication.create!(post: other, social_page: social_pages(:facebook), remote_id: "1234_777", remote_kind: "feed")
    PublicationMetric.record!(other_publication, views: 500, reach: 400, at: Time.zone.local(2026, 11, 15, 9))

    titles = ->(sort) { get posts_path(vista: "lista", q: { s: sort }); css_select(".riga h3").map(&:text) }
    assert_equal [ @post.title, other.title ], titles.("views desc").first(2)
    assert_equal [ other.title, @post.title ], titles.("views asc").first(2)
    assert_equal [ other.title, @post.title ], titles.("reach desc").first(2)
    assert_equal [ @post.title, other.title ], titles.("reach asc").first(2)
    assert_select "#q_s option[selected][value=?]", "reach asc"
    assert_select "#q_s option", text: "Più visualizzazioni"
    assert_select "#q_s option", text: "Meno persone raggiunte"
    assert_equal Post.count, css_select(".riga").size, "anche i post senza numeri restano nell'elenco, in fondo"
  end

  test "la pagina di un post pubblicato senza letture lo dice; quella di una bozza non ne parla" do
    get post_path(@post)
    assert_select "#statistiche-#{@post.id}", text: /in arrivo dai social/
    assert_select "#grafici-#{@post.id} .vuoto"

    get post_path(posts(:mensa))
    assert_select ".statistiche", count: 0
    assert_select ".grafici", count: 0
    assert_select "[data-controller=stats-refresh]", count: 0
  end

  test "l'aggiornamento della pagina sostituisce numeri e grafici" do
    save_readings
    @facebook.insights("1234_999", views: 1200, reach: 400)

    get statistiche_posts_path(ids: @post.id.to_s, contesto: "pagina")
    assert_select "turbo-stream[action=replace][target=statistiche-#{@post.id}] .statistica-numero", text: "1.200"
    assert_select "turbo-stream[action=replace][target=grafici-#{@post.id}] svg.trend-chart", count: 2
  end

  test "il popup del calendario ha numeri, grafici uno sotto l'altro e la sua lettura" do
    save_readings
    get preview_post_path(@post)
    assert_select ".anteprima-post #statistiche-#{@post.id} .statistica-numero", text: "916"
    assert_select ".anteprima-post #grafici-#{@post.id}.grafici-popup svg.trend-chart", count: 2
    assert_select "span[data-controller=stats-refresh][data-stats-refresh-url-value=?]",
                  statistiche_posts_path(ids: @post.id.to_s, contesto: "popup")

    get statistiche_posts_path(ids: @post.id.to_s, contesto: "popup")
    assert_select "turbo-stream[target=grafici-#{@post.id}] .grafici-popup"
  end

  test "il report aggiorna le statistiche e le mette nella pagina dei post pubblicati" do
    printed = []
    PostsReport.printer = ->(html, pdf_path) { printed << File.read(html); File.write(pdf_path, "%PDF-1.4 finto") }
    PostsReport.text_of = ->(_pdf) { [] }
    save_readings
    @facebook.insights("1234_999", views: 1500, reach: 410)

    get report_posts_path
    assert_response :success
    assert_equal [ 1500, 410 ], [ @open_day.latest_metric.total_views, @open_day.latest_metric.total_reach ]
    html = Nokogiri::HTML(printed.last)
    card = html.css(".scheda").find { |section| section.at_css("h2").text == @post.title }
    assert_equal [ "VISUALIZZAZIONI", "PERSONE RAGGIUNTE" ], card.css(".statistica .etichetta").map { |e| e.text.strip }
    assert_equal [ "1.500", "410" ], card.css(".statistica strong").map(&:text)
    assert_equal 2, card.css(".grafici svg.trend-chart").size
    other = html.css(".scheda").find { |section| section.at_css("h2").text == posts(:mensa).title }
    assert_empty other.css(".statistiche, .grafici")
  ensure
    PostsReport.printer = nil
    PostsReport.text_of = nil
  end

  test "se Facebook non risponde il report si fa lo stesso" do
    PostsReport.printer = ->(_html, pdf_path) { File.write(pdf_path, "%PDF-1.4 finto") }
    PostsReport.text_of = ->(_pdf) { [] }
    @facebook.fail_on(:batch, //, "Facebook non risponde")

    get report_posts_path
    assert_response :success
    assert_empty PublicationMetric.all
  ensure
    PostsReport.printer = nil
    PostsReport.text_of = nil
  end
end
