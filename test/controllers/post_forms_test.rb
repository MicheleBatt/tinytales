require "test_helper"

class PostFormsTest < ActionDispatch::IntegrationTest
  def image(name = "sample.jpg")
    Rack::Test::UploadedFile.new(file_fixture("sample.jpg"), "image/jpeg", original_filename: name)
  end

  test "l'elenco ha il pulsante Nuovo post e il dettaglio il pulsante Modifica" do
    get posts_path
    assert_select "a[href='#{new_post_path}']", "Nuovo post"

    get post_path(posts(:mensa))
    assert_select "a[href='#{edit_post_path(posts(:mensa))}']", "Modifica"
  end

  test "il nuovo post propone già la pagina Facebook" do
    get new_post_path
    assert_response :success
    assert_select "input[type=checkbox][value='#{social_pages(:facebook).id}'][checked]"
    assert_select "input[type=checkbox][value='#{social_pages(:instagram).id}']:not([checked])"
  end

  test "crea sempre una bozza con testo, data, pagine e immagini, anche se arriva un altro stato" do
    assert_difference "Post.count", 1 do
      post posts_path, params: { post: {
        title: "Vi presentiamo Elmer", body: "Ciao!", notes: "Mancano le foto",
        publish_at: "2026-11-05T20:30", status: "published",
        social_page_ids: [ "", social_pages(:facebook).id ],
        media: [ "", image("1_elmer.jpg"), image("2_lavoretti.jpg") ]
      } }
    end

    created = Post.order(:id).last
    assert_redirected_to post_path(created)
    assert created.draft?
    assert_equal Time.zone.parse("2026-11-05 20:30"), created.publish_at
    assert_equal [ social_pages(:facebook) ], created.social_pages.to_a
    assert_equal %w[1_elmer.jpg 2_lavoretti.jpg], created.media.map { |m| m.filename.to_s }

    follow_redirect!
    assert_select ".avviso-ok", "Post creato."
  end

  test "non crea un post senza titolo e mostra l'errore" do
    assert_no_difference "Post.count" do
      post posts_path, params: { post: { title: "", body: "x", publish_at: "2026-11-05T20:30", media: [ "", image ] } }
    end
    assert_response :unprocessable_content
    assert_select ".errore-campo", /obbligatorio/i
    assert_select ".avviso-info", /selezionali di nuovo/
  end

  test "un post senza data e ora si salva come bozza da pubblicare subito" do
    assert_difference "Post.count", 1 do
      post posts_path, params: { post: { title: "Promemoria", publish_at: "" } }
    end
    created = Post.order(:id).last
    assert created.draft?
    assert_nil created.publish_at
    assert created.publishable?
  end

  test "a un post programmato non si può togliere la data" do
    patch post_path(posts(:promemoria)), params: { post: { publish_at: "" } }
    assert_response :unprocessable_content
    assert_not_nil posts(:promemoria).reload.publish_at
  end

  test "il form non permette di scegliere lo stato e la data non è obbligatoria" do
    get new_post_path
    assert_select "input[name='post[status]']", 0
    assert_select "input[name='post[publish_at]']:not([required])"
    assert_select ".campo .aiuto", /Facoltativa: è la data prevista/
    assert_select ".stato-fisso .pill-draft", "Bozza"
  end

  test "le miniature del form si aprono a tutto schermo con il file originale" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "sala.jpg", content_type: "image/jpeg")

    get edit_post_path(mensa)
    assert_select "body[data-controller~=lightbox]"
    assert_select "img.apribile[data-lightbox-group=post-media][data-lightbox-caption='sala.jpg'][data-lightbox-type=image]" do |img|
      assert_match %r{/rails/active_storage/blobs/}, img.first["data-lightbox"]
    end
  end

  test "anche nella pagina di dettaglio le immagini si aprono a tutto schermo" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "sala.jpg", content_type: "image/jpeg")

    get post_path(mensa)
    assert_select ".galleria a[data-lightbox-group=post-media][data-lightbox-caption='sala.jpg'][data-lightbox-type=image]"
  end

  test "il form di modifica mostra il contenuto attuale, file compresi" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "sala.jpg", content_type: "image/jpeg")

    get edit_post_path(mensa)
    assert_response :success
    assert_select "input[name='post[title]'][value='La nostra mensa']"
    assert_select "textarea[name='post[body]']", text: mensa.body
    assert_select "input[type=hidden][name='post[media][]'][value='#{mensa.media.first.signed_id}']"
    assert_select "figcaption span", "sala.jpg"
  end

  test "la modifica aggiorna i campi, toglie i file non più elencati e aggiunge i nuovi in coda" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "tieni.jpg", content_type: "image/jpeg")
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "togli.jpg", content_type: "image/jpeg")
    keep = mensa.media.find { |m| m.filename.to_s == "tieni.jpg" }

    patch post_path(mensa), params: { post: {
      title: "La nostra mensa (Riesco)", status: "scheduled", publish_at: "2026-11-12T20:30",
      social_page_ids: [ "", social_pages(:facebook).id, social_pages(:instagram).id ],
      media: [ keep.signed_id, "", image("nuova.jpg") ]
    } }

    assert_redirected_to post_path(mensa)
    mensa.reload
    assert_equal "La nostra mensa (Riesco)", mensa.title
    assert mensa.draft?, "lo stato non si cambia dal form"
    assert_equal 2, mensa.social_pages.count
    assert_equal %w[tieni.jpg nuova.jpg], mensa.media.map { |m| m.filename.to_s }
  end

  test "la modifica salva il nuovo ordine dei file, con i nuovi in fondo" do
    mensa = posts(:mensa)
    %w[a.jpg b.jpg c.jpg].each do |name|
      mensa.media.attach(io: file_fixture("sample.jpg").open, filename: name, content_type: "image/jpeg")
    end
    a, b, c = %w[a.jpg b.jpg c.jpg].map { |name| mensa.media.find { |m| m.filename.to_s == name } }

    patch post_path(mensa), params: { post: { media: [ c.signed_id, a.signed_id, "", image("d.jpg") ] } }
    assert_redirected_to post_path(mensa)
    assert_equal %w[c.jpg a.jpg d.jpg], mensa.reload.ordered_media.map { |m| m.filename.to_s }

    get post_path(mensa)
    assert_equal %w[c.jpg a.jpg d.jpg], css_select(".galleria figcaption").map { |fc| fc.text.strip[/\S+\.jpg/] }

    get edit_post_path(mensa)
    assert_equal %w[c.jpg a.jpg d.jpg], css_select(".galleria-ordinabile figcaption > span:first-child").map { |s| s.text.strip }
    assert_select ".bottone-freccia", 6
  end

  test "i file nuovi vanno al posto scelto nella galleria, anche in mezzo a quelli già salvati" do
    mensa = posts(:mensa)
    %w[a.jpg b.jpg].each do |name|
      mensa.media.attach(io: file_fixture("sample.jpg").open, filename: name, content_type: "image/jpeg")
    end
    a, b = mensa.ordered_media

    patch post_path(mensa), params: { post: {
      media: [ "", "nuovo:x1", a.signed_id, "nuovo:x2", b.signed_id ],
      new_media: { "x1" => image("dalla-chat.jpg"), "x2" => image("dal-computer.jpg") }
    } }
    assert_redirected_to post_path(mensa)
    assert_equal %w[dalla-chat.jpg a.jpg dal-computer.jpg b.jpg], mensa.reload.ordered_media.map { |m| m.filename.to_s }
  end

  test "un file nuovo tolto dalla galleria non si carica, e uno senza posto si scarta" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "a.jpg", content_type: "image/jpeg")

    # «Rimuovi» disattiva segnaposto e file: non arrivano. Un segnaposto senza file non fa danni.
    patch post_path(mensa), params: { post: {
      media: [ "", mensa.media.first.signed_id, "nuovo:manca" ],
      new_media: { "orfano" => image("orfano.jpg") }
    } }
    assert_equal %w[a.jpg], mensa.reload.ordered_media.map { |m| m.filename.to_s }
  end

  test "un post nuovo si crea con i file nell'ordine scelto" do
    post posts_path, params: { post: {
      title: "Con la chat", media: [ "", "nuovo:k2", "nuovo:k1" ],
      new_media: { "k1" => image("primo-scelto.jpg"), "k2" => image("spostato-davanti.jpg") }
    } }
    assert_equal %w[spostato-davanti.jpg primo-scelto.jpg], Post.order(:id).last.ordered_media.map { |m| m.filename.to_s }
  end

  test "si possono togliere tutti i file: l'elenco vuoto arriva comunque" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "a.jpg", content_type: "image/jpeg")
    get edit_post_path(mensa)
    assert_select "input[type=hidden][name='post[media][]'][value='']", 1
    assert_select "input#aggiungi-file[type=file]:not([name])", 1, "il campo per scegliere non invia nulla da sé"
    assert_select ".galleria-nuovi", 0, "niente più galleria separata per i nuovi"

    patch post_path(mensa), params: { post: { media: [ "" ] } }
    assert_empty mensa.reload.media
  end

  test "salvare senza toccare i file non cambia il loro ordine" do
    mensa = posts(:mensa)
    %w[a.jpg b.jpg].each do |name|
      mensa.media.attach(io: file_fixture("sample.jpg").open, filename: name, content_type: "image/jpeg")
    end
    a, b = mensa.ordered_media
    patch post_path(mensa), params: { post: { media: [ b.signed_id, a.signed_id, "" ] } }
    patch post_path(mensa), params: { post: { title: "Titolo nuovo" } }

    assert_equal %w[b.jpg a.jpg], mensa.reload.ordered_media.map { |m| m.filename.to_s }
  end

  test "una modifica non valida non cambia né i campi né i file" do
    mensa = posts(:mensa)
    mensa.media.attach(io: file_fixture("sample.jpg").open, filename: "sala.jpg", content_type: "image/jpeg")

    patch post_path(mensa), params: { post: { title: "", media: [ "" ] } }

    assert_response :unprocessable_content
    mensa.reload
    assert_equal "La nostra mensa", mensa.title
    assert_equal %w[sala.jpg], mensa.media.map { |m| m.filename.to_s }
    assert_select "figcaption span", "sala.jpg"
  end

  test "rifiuta un file che non è un'immagine né un video" do
    patch post_path(posts(:mensa)), params: { post: {
      media: [ "", fixture_file_upload("note.txt", "text/plain") ]
    } }
    assert_response :unprocessable_content
    assert_select ".errore-campo", /note\.txt/
    assert_empty posts(:mensa).reload.media
  end
end
