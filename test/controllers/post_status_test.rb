require "test_helper"

class PostStatusTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup { travel_to Time.zone.parse("2026-11-01 10:00") }
  teardown { travel_back }

  test "una bozza con l'ora nel futuro mostra Programma" do
    get post_path(posts(:mensa))
    assert_select "form[action='#{schedule_post_path(posts(:mensa))}'] button", "Programma"
    assert_select "form[action='#{publish_post_path(posts(:mensa))}']", 0
  end

  test "una bozza con l'ora passata o uguale a adesso mostra Pubblica" do
    posts(:mensa).update_column(:publish_at, Time.current)
    get post_path(posts(:mensa))
    assert_select "form[action='#{publish_post_path(posts(:mensa))}'] button", "Pubblica"
    assert_select "form[action='#{schedule_post_path(posts(:mensa))}']", 0
  end

  test "una bozza senza data non mostra né Pubblica né Programma" do
    get post_path(posts(:festa_di_natale))
    assert_select "form[action$='/publish'], form[action$='/schedule']", 0
    assert_select ".azioni-post .aiuto", /imposta prima data e ora/
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
    posts(:mensa).update_column(:publish_at, 1.hour.ago)
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
end
