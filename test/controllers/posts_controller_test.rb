require "test_helper"

class PostsControllerTest < ActionDispatch::IntegrationTest
  test "l'elenco mostra tutti i post, prima quelli senza data e poi dal più recente" do
    get posts_path
    assert_response :success

    titles = css_select(".scheda h3").map { |h3| h3.text.strip }
    assert_equal [ "Festa di Natale", "Promemoria Open Day", "La nostra mensa", "Open Day di novembre" ], titles
  end

  test "i filtri restringono l'elenco" do
    get posts_path, params: { q: { status_eq: "draft" } }
    assert_select ".scheda", 2

    get posts_path, params: { q: { title_or_body_or_notes_cont: "Open Day" } }
    assert_select ".scheda", 2

    get posts_path, params: { q: { social_pages_id_eq: social_pages(:instagram).id } }
    assert_select ".scheda h3", text: "Festa di Natale"
    assert_select ".scheda", 1
  end

  test "la testata ha il link alla checklist e la favicon del sito" do
    get posts_path
    assert_select ".link-pagine a[href='https://claude.ai/artifact/Tos8L3ykB7QKwQzQs2HGaK'][target=_blank]", "Checklist ↗"
    assert_select "link[rel=icon][href*='favicon']", 3
    assert_select "link[rel=apple-touch-icon][href*='apple-touch-icon']"
  end

  test "l'elenco si apre in lista, con le icone per passare alla griglia" do
    get posts_path
    assert_select ".elenco-post:not(.vista-griglia)"
    assert_select ".icona-vista[data-view=lista][aria-pressed=true]"
    assert_select ".icona-vista[data-view=griglia][aria-pressed=false]"
  end

  test "la vista a griglia scelta resta ricordata" do
    cookies[:vista_post] = "griglia"
    get posts_path
    assert_select ".elenco-post.vista-griglia .scheda", 4
    assert_select ".icona-vista[data-view=griglia][aria-pressed=true]"

    cookies[:vista_post] = "qualcos'altro"
    get posts_path
    assert_select ".elenco-post:not(.vista-griglia)"
  end

  test "la vista a calendario mostra il mese con i post nei loro giorni, colorati per stato" do
    get posts_path, params: { vista: "calendario", mese: "2026-11" }
    assert_response :success
    assert_select ".calendario-mese", "Novembre 2026"
    assert_select ".calendario-intestazione", 7
    assert_select ".giorno", 42 # sei settimane: da lunedì 26 ottobre a domenica 6 dicembre
    assert_select ".giorno[aria-label^='giovedì 12 novembre 2026'] .evento.evento-draft .evento-titolo", "La nostra mensa"
    assert_select ".giorno[aria-label^='mercoledì 18 novembre 2026'] .evento.evento-scheduled .evento-ora", "20.30"
    assert_select ".giorno.fuori-mese[aria-label^='lunedì 26 ottobre 2026'] .evento-published"
    assert_select ".calendario-senza-data .evento", text: /Festa di Natale/
    assert_select ".risultati", /2 post in novembre 2026/ # mensa e promemoria; l'Open Day è del 26 ottobre
    assert_equal "calendario", cookies[:vista_post]
  end

  test "il calendario si sposta di mese e tiene i filtri" do
    get posts_path, params: { vista: "calendario", mese: "2026-11", q: { status_eq: "draft" } }
    assert_select ".calendario-nav a[href*='mese=2026-10'][href*='status_eq%5D=draft']", "‹"
    assert_select ".calendario-nav a[href*='mese=2026-12'][href*='status_eq%5D=draft']", "›"
    assert_select ".giorno .evento-scheduled", 0
    assert_select "form.calendario-salta input[type=hidden][name='q[status_eq]'][value=draft]"
  end

  test "un mese non valido mostra il mese corrente; il cookie ricorda il calendario" do
    cookies[:vista_post] = "calendario"
    get posts_path, params: { mese: "pippo" }
    assert_select ".calendario-mese", I18n.l(Date.current, format: "%B %Y").upcase_first
  end

  test "il filtro per data include tutto l'ultimo giorno" do
    get posts_path, params: { q: { publish_at_gteq: "2026-11-12", publish_at_lteq: "2026-11-18" } }
    assert_select ".scheda", 2
  end

  test "l'ordine si può invertire" do
    get posts_path, params: { q: { s: "publish_at asc" } }
    first = css_select(".scheda h3").first.text.strip
    assert_equal "Open Day di novembre", first
  end

  test "il dettaglio mostra testo, pagine social e immagini" do
    post = posts(:promemoria)
    post.media.attach(io: file_fixture("sample.jpg").open, filename: "PROVVISORIA_sample.jpg", content_type: "image/jpeg")

    get post_path(post)
    assert_response :success
    assert_select "h1", "Promemoria Open Day"
    assert_select ".testo-post", text: "Mancano pochi giorni all'Open Day!"
    assert_select ".chip-facebook"
    assert_select ".galleria figure.provvisoria", 1
  end

  test "risponde 404 per un post che non esiste" do
    get post_path(id: 0)
    assert_response :not_found
  end
end
