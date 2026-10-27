require "test_helper"

class PostStatusTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup { travel_to Time.zone.parse("2026-11-01 10:00") }
  teardown { travel_back }

  test "una bozza mostra sempre Pubblica Ora e Programma; con una data futura il bottone blu è Programma" do
    get post_path(posts(:mensa))
    assert_select "form[action='#{schedule_post_path(posts(:mensa))}'] button.bottone-principale", "Programma"
    assert_select "form[action='#{publish_post_path(posts(:mensa))}'] button.bottone-secondario", "Pubblica Ora"
    assert_select "form[action='#{schedule_post_path(posts(:mensa))}'][data-confirm-datetime-value='2026-11-12T20:30']"
    assert_select "form[action='#{publish_post_path(posts(:mensa))}'][data-turbo-confirm*='verrà sostituita con quella di uscita']"
    assert_select ".azioni-post .aiuto", /Data prevista: giovedì 12 novembre 2026/
  end

  test "una bozza senza data mostra entrambi i bottoni; la finestra di Programma parte senza data" do
    get post_path(posts(:festa_di_natale))
    assert_select "form[action='#{publish_post_path(posts(:festa_di_natale))}'] button.bottone-principale", "Pubblica Ora"
    assert_select "form[action='#{schedule_post_path(posts(:festa_di_natale))}'] button", "Programma"
    assert_select "form[action$='/schedule'][data-confirm-datetime-name=publish_at]:not([data-confirm-datetime-value])"
    assert_select ".azioni-post .aiuto", /Nessuna data prevista: con «Programma» la scegli tu/
  end

  test "una bozza con la data passata si pubblica subito, e la data diventa quella di uscita" do
    posts(:mensa).update_column(:publish_at, 1.hour.ago)
    get post_path(posts(:mensa))
    assert_select "form[action$='/publish'] button", "Pubblica Ora"
    assert_select "form[action$='/schedule'] button", "Programma"
    assert_select ".azioni-post .aiuto-attenzione", /è passata: per programmarlo scegline una nuova con «Programma»/

    patch publish_post_path(posts(:mensa))
    assert posts(:mensa).reload.published?
    assert_equal Time.current, posts(:mensa).publish_at
    assert_equal true, @facebook.calls.find { |c| c.path == "1234/feed" }.params[:published]
  end

  test "una bozza con la data passata si programma con una data nuova, non con quella vecchia" do
    posts(:mensa).update_column(:publish_at, 1.hour.ago)
    patch schedule_post_path(posts(:mensa))
    assert posts(:mensa).reload.draft?
    follow_redirect!
    assert_select ".avviso-ritardo", /scegli una data di pubblicazione nel futuro/

    patch schedule_post_path(posts(:mensa)), params: { publish_at: "2026-11-05T20:30" }
    assert posts(:mensa).reload.scheduled?
    assert_equal Time.zone.parse("2026-11-05 20:30"), posts(:mensa).publish_at
  end

  test "Programma programma il post su Facebook e poi cambia lo stato" do
    patch schedule_post_path(posts(:mensa))

    assert_redirected_to post_path(posts(:mensa))
    assert posts(:mensa).reload.scheduled?
    feed = @facebook.calls.find { |c| c.path == "1234/feed" }
    assert_equal false, feed.params[:published]
    assert_equal Time.zone.parse("2026-11-12 20:30").to_i, feed.params[:scheduled_publish_time]
    assert publications(:mensa_facebook).reload.on_social?

    follow_redirect!
    assert_select ".avviso-ok", /programmato sui social per giovedì 12 novembre 2026, ore 20.30/
    assert_select ".sui-social a[href^='https://www.facebook.com/1234_']"
  end

  test "Pubblica pubblica subito su Facebook" do
    posts(:mensa).update_column(:publish_at, nil)
    patch publish_post_path(posts(:mensa))

    assert posts(:mensa).reload.published?
    assert_equal Time.current, posts(:mensa).publish_at
    assert_equal true, @facebook.calls.find { |c| c.path == "1234/feed" }.params[:published]
  end

  test "se Facebook rifiuta, il post resta bozza e si vede il motivo" do
    @facebook.fail_on(:post, %r{/feed\z}, "Token scaduto")
    patch schedule_post_path(posts(:mensa))

    assert posts(:mensa).reload.draft?
    follow_redirect!
    assert_select ".avviso-ritardo", /Token scaduto/
    assert_select ".sui-social .errore-campo", /Token scaduto/
  end

  test "Programma rifiuta un'ora fra meno di 10 minuti e lo dice" do
    posts(:mensa).update_column(:publish_at, 5.minutes.from_now)
    patch schedule_post_path(posts(:mensa))

    assert posts(:mensa).reload.draft?
    assert_empty @facebook.calls
    follow_redirect!
    assert_select ".avviso-ritardo", /da 10 minuti in poi/
  end

  test "Spubblica toglie il post da Facebook e lo riporta bozza" do
    get post_path(posts(:open_day))
    assert_select "form[action='#{unpublish_post_path(posts(:open_day))}'] button", "Spubblica"

    patch unpublish_post_path(posts(:open_day))
    assert posts(:open_day).reload.draft?
    assert_equal [ "1234_999" ], @facebook.paths(:delete)
    assert_not publications(:open_day_facebook).reload.on_social?
  end

  test "se Facebook non riesce a togliere il post, resta pubblicato" do
    @facebook.fail_on(:delete, /1234_999/, "Errore temporaneo")
    patch unpublish_post_path(posts(:open_day))

    assert posts(:open_day).reload.published?
    follow_redirect!
    assert_select ".avviso-ritardo", /Errore temporaneo/
  end

  test "Elimina toglie il post da Facebook e lo cancella dall'app" do
    assert_difference [ "Post.count", "Publication.count" ], -1 do
      delete post_path(posts(:promemoria))
    end
    assert_equal [ "1234_888" ], @facebook.paths(:delete)
    assert_redirected_to posts_path
  end

  test "una bozza si elimina senza chiamare Facebook" do
    delete post_path(posts(:mensa))
    assert_empty @facebook.calls
    assert_not Post.exists?(posts(:mensa).id)
  end

  test "la modifica di un post pubblicato aggiorna il testo su Facebook" do
    patch post_path(posts(:open_day)), params: { post: { body: "Testo corretto" } }

    assert_equal "Testo corretto", posts(:open_day).reload.body
    call = @facebook.calls.find { |c| c.path == "1234_999" }
    assert_equal "Testo corretto", call.params[:message]
    follow_redirect!
    assert_select ".avviso-ok", "Modifiche salvate anche sui social."
  end

  test "un post programmato o pubblicato resta modificabile ed eliminabile, ma non cambia pagine" do
    [ posts(:promemoria), posts(:open_day) ].each do |post|
      get post_path(post)
      assert_select "a[href='#{edit_post_path(post)}']", "Modifica"
      assert_select "form[action='#{post_path(post)}'] input[name=_method][value=delete]"

      get edit_post_path(post)
      assert_select "fieldset[disabled] input[type=checkbox]"
    end

    patch post_path(posts(:open_day)), params: { post: { social_page_ids: [ "" ] } }
    assert_equal [ social_pages(:facebook) ], posts(:open_day).reload.social_pages.to_a
  end

  test "un post pubblicato a mano, non collegato, si spubblica con un avviso" do
    publications(:open_day_facebook).update!(remote_id: nil)
    patch unpublish_post_path(posts(:open_day))

    assert posts(:open_day).reload.draft?
    assert_empty @facebook.calls
    follow_redirect!
    assert_select ".avviso-info", /toglilo da Facebook a mano/
  end

  test "se la pagina non è collegata lo dice, e il post resta bozza" do
    social_pages(:facebook).update!(access_token: nil)
    get post_path(posts(:mensa))
    assert_select ".avviso-info", /non ancora collegata/

    patch schedule_post_path(posts(:mensa))
    assert posts(:mensa).reload.draft?
    follow_redirect!
    assert_select ".avviso-ritardo", /social:facebook:connect/
  end

  test "un post programmato con l'ora passata diventa pubblicato" do
    travel_to Time.zone.parse("2026-11-18 21:00") do
      get posts_path
      assert posts(:promemoria).reload.published?
    end
  end

  test "il calendario apre i post in un popup, con anteprima, bottoni e link ai social" do
    get posts_path, params: { vista: "calendario", mese: "2026-11" }
    assert_select ".calendario[data-controller=post-preview] dialog.popup-anteprima"
    assert_select ".giorno a.evento[data-action='post-preview#open'][data-preview-url='#{preview_post_path(posts(:mensa))}']"
    assert_select ".calendario-senza-data a.evento[data-action='post-preview#open']"

    back = "/posts?vista=calendario&mese=2026-11"
    get preview_post_path(posts(:promemoria)), params: { return_to: back }
    assert_response :success
    assert_no_match(/<html|<nav/, response.body, "solo il contenuto, senza layout")
    assert_select ".anteprima-post h2", "Promemoria Open Day"
    assert_select ".pill-scheduled"
    assert_select "a.chip-link[href^='https://www.facebook.com/1234_888'][target=_blank]", /Apri il post/
    assert_select ".anteprima-testo", "Mancano pochi giorni all'Open Day!"
    assert_select "form[action='#{post_path(posts(:promemoria))}'] input[name=return_to][value='#{back}']"
    assert_select "a.anteprima-link[href='#{post_path(posts(:promemoria))}']"
  end

  test "un'azione lanciata dal popup torna al calendario; un indirizzo esterno viene ignorato" do
    back = "/posts?vista=calendario&mese=2026-11"
    patch schedule_post_path(posts(:mensa)), params: { return_to: back }
    assert_redirected_to back
    assert posts(:mensa).reload.scheduled?

    patch unpublish_post_path(posts(:open_day)), params: { return_to: "//esempio.com/posts" }
    assert_redirected_to post_path(posts(:open_day))

    delete post_path(posts(:mensa)), params: { return_to: back }
    assert_redirected_to back
  end

  test "le azioni chiedono conferma con la finestra dell'app: titolo, bottone e tono" do
    get post_path(posts(:festa_di_natale))
    assert_select "form[action='#{publish_post_path(posts(:festa_di_natale))}'][data-confirm-title='Pubblicare adesso?'][data-confirm-button='Pubblica Ora']:not([data-confirm-tone])"
    assert_select "form[action='#{post_path(posts(:festa_di_natale))}'][data-confirm-tone=pericolo][data-confirm-button=Elimina][data-turbo-confirm*=\"L'azione è irreversibile\"]"

    get post_path(posts(:open_day))
    assert_select "form[action='#{unpublish_post_path(posts(:open_day))}'][data-confirm-tone=pericolo][data-confirm-button=Spubblica]"
  end

  test "Programma chiede conferma con la data già compilata, modificabile" do
    get post_path(posts(:mensa))
    assert_select "form[action='#{schedule_post_path(posts(:mensa))}'][data-confirm-title='Programmare il post?']" \
                  "[data-confirm-datetime-name=publish_at][data-confirm-datetime-value='2026-11-12T20:30']"
  end

  test "Programma con una nuova data la usa su Facebook e la salva nell'app" do
    patch schedule_post_path(posts(:mensa)), params: { publish_at: "2026-11-20T18:15" }

    post = posts(:mensa).reload
    assert post.scheduled?
    assert_equal Time.zone.parse("2026-11-20 18:15"), post.publish_at
    feed = @facebook.calls.find { |c| c.path == "1234/feed" }
    assert_equal Time.zone.parse("2026-11-20 18:15").to_i, feed.params[:scheduled_publish_time]
    follow_redirect!
    assert_select ".avviso-ok", /programmato sui social per venerdì 20 novembre 2026, ore 18.15/
  end

  test "se Facebook rifiuta la nuova data, nell'app resta quella di prima" do
    patch schedule_post_path(posts(:mensa)), params: { publish_at: "2026-12-25T10:00" } # oltre 30 giorni

    post = posts(:mensa).reload
    assert post.draft?
    assert_equal Time.zone.parse("2026-11-12 20:30"), post.publish_at
    assert_empty @facebook.calls
    follow_redirect!
    assert_select ".avviso-ritardo", /al massimo 30 giorni prima/
  end

  test "una data non valida dalla finestra non cambia niente" do
    patch schedule_post_path(posts(:mensa)), params: { publish_at: "domani" }
    assert posts(:mensa).reload.draft?
    assert_equal Time.zone.parse("2026-11-12 20:30"), posts(:mensa).publish_at
    follow_redirect!
    assert_select ".avviso-ritardo", /non è valida/
  end

  test "i messaggi di conferma nominano le piattaforme, non il nome della pagina" do
    get post_path(posts(:mensa))
    assert_select "form[action$='/publish'][data-turbo-confirm^='Il post «La nostra mensa» viene pubblicato subito sulla pagina Facebook.']"
    assert_select "form[action$='/schedule'][data-turbo-confirm*='verrà pubblicato sulla pagina Facebook in automatico']"
    assert_select "form[data-turbo-confirm*='Creola']", 0

    get post_path(posts(:open_day))
    assert_select "form[action$='/unpublish'][data-turbo-confirm*='sparisce dalla pagina Facebook.']"
    assert_select "form[action='#{post_path(posts(:open_day))}'][data-turbo-confirm*='sparirà anche dalla pagina Facebook']"
  end

  test "le azioni che parlano con i social mostrano il velo di attesa, con un messaggio adatto" do
    get post_path(posts(:mensa))
    assert_select "form[action$='/publish'][data-busy-message='Pubblicazione sulla pagina Facebook in corso…']"
    assert_select "form[action$='/schedule'][data-busy-message='Programmazione sulla pagina Facebook in corso…']"
    assert_select "form[action='#{post_path(posts(:mensa))}']:not([data-busy-message])", 1, "eliminare una bozza non tocca i social"

    get post_path(posts(:open_day))
    assert_select "form[action$='/unpublish'][data-busy-message='Rimozione del post dalla pagina Facebook in corso…']"
    assert_select "form[action='#{post_path(posts(:open_day))}'][data-busy-message^='Eliminazione del post e rimozione dalla pagina Facebook']"

    get edit_post_path(posts(:open_day))
    assert_select "form.modulo[data-busy-message^='Salvataggio e aggiornamento sulla pagina Facebook']"
    get edit_post_path(posts(:mensa))
    assert_select "form.modulo:not([data-busy-message])"
  end

  test "un errore di Facebook su un'azione dal popup del calendario compare in una finestra a sé" do
    @facebook.fail_on(:post, %r{/feed\z}, "Token scaduto")
    back = "/posts?vista=calendario&mese=2026-11"
    patch schedule_post_path(posts(:mensa)), params: { return_to: back }

    assert_redirected_to back
    assert posts(:mensa).reload.draft?
    follow_redirect!
    assert_select "dialog.errore-popup[data-controller=auto-dialog]" do
      assert_select "h2", "Programmazione non riuscita"
      assert_select ".conferma-messaggio", /La nostra mensa.*Token scaduto/m
      assert_select "a[href='#{post_path(posts(:mensa))}']", "Apri il post"
    end
    assert_select ".avviso-ritardo", 0, "niente striscia: l'errore è nella finestra"
  end

  test "dalla pagina del post gli errori restano nella striscia d'avviso" do
    @facebook.fail_on(:post, %r{/feed\z}, "Token scaduto")
    patch schedule_post_path(posts(:mensa))
    follow_redirect!
    assert_select ".avviso-ritardo", /Token scaduto/
    assert_select "dialog.errore-popup", 0
  end
end
