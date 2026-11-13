require "test_helper"

class MusicTracksControllerTest < ActionDispatch::IntegrationTest
  def audio(name = "brano.mp3", content_type = "audio/mpeg") = fixture_file_upload(name, content_type)

  def form(**extra)
    { title: "Giornata felice", author: "Qualcuno", source_url: "https://pixabay.com/music/giornata-123/",
      license: "Pixabay Content License", moods: [ "", "allegra", "festosa" ], tempo: "vivace",
      instruments: "ukulele", vocals: "0", suitable_for: "feste", notes: "", enabled: "1", audio: audio }.merge(extra)
  end

  def saved_track(**extra)
    MusicTrack.create!(form(**extra).except(:vocals, :enabled).merge(moods: %w[allegra festosa]))
  end

  test "la testata porta alla musicoteca, che da vuota mostra la guida aperta" do
    get posts_path
    assert_select "a.link-pagina[href=?]", music_tracks_path, text: "Musicoteca"

    get music_tracks_path
    assert_response :success
    assert_select "details.guida-musica[open]"
    assert_select "p.vuoto", /vuota/
  end

  test "si aggiunge un brano con il suo file" do
    get new_music_track_path
    assert_response :success
    assert_select "input[type=file][name='music_track[audio]']"
    assert_select "input[type=checkbox][name='music_track[moods][]']", MusicTrack::MOODS.size

    assert_difference -> { MusicTrack.count } do
      post music_tracks_path, params: { music_track: form }
    end
    assert_redirected_to music_tracks_path
    track = MusicTrack.last
    assert_equal %w[allegra festosa], track.moods
    assert track.audio.attached?
    assert track.duration.positive?

    follow_redirect!
    assert_select ".riga-brano .riga-titolo", "Giornata felice"
    assert_select ".riga-brano audio"
    assert_select "details.guida-musica:not([open])"
  end

  test "un brano non valido non si salva e il file va scelto di nuovo" do
    assert_no_difference -> { MusicTrack.count } do
      post music_tracks_path, params: { music_track: form(moods: [ "" ], license: "") }
    end
    assert_response :unprocessable_content
    assert_select ".avviso-ritardo", /non è stato salvato/
    assert_select ".avviso-info", /selezionalo di nuovo/
  end

  test "la modifica senza un file nuovo tiene quello di prima" do
    track = saved_track
    blob = track.audio.blob

    get edit_music_track_path(track)
    assert_response :success
    assert_select ".brano-attuale audio"

    patch music_track_path(track), params: { music_track: { title: "Nuovo titolo", enabled: "0", audio: "" } }
    assert_redirected_to music_tracks_path
    track.reload
    assert_equal "Nuovo titolo", track.title
    assert_not track.enabled?
    assert_equal blob, track.audio.blob

    follow_redirect!
    assert_select ".brano-spento .pill", "Disattivato"
  end

  test "si elimina un brano, con il suo file" do
    track = saved_track
    assert_difference -> { MusicTrack.count }, -1 do
      delete music_track_path(track)
    end
    assert_redirected_to music_tracks_path
    assert_not ActiveStorage::Attachment.exists?(record_type: "MusicTrack", record_id: track.id)
  end

  test "il form ha il bottone «Compila con Claude»" do
    get new_music_track_path
    assert_select "form[data-controller=music-autofill][data-music-autofill-url-value=?]", autofill_music_tracks_path
    assert_select "button[data-action='music-autofill#fill']", /Compila con Claude/
    assert_select "input[name='music_track[source_tags]']"
  end

  test "Compila con Claude: dal file appena scelto propone i campi, senza salvare" do
    MusicAutofill.runner = lambda do |prompt|
      assert_match "Tag copiati dalla pagina: <<<kids, happy>>>", prompt
      { "is_error" => false, "structured_output" => { "title" => "Happy Kids", "moods" => %w[allegra], "tempo" => "vivace" } }.to_json
    end
    assert_no_difference -> { MusicTrack.count } do
      post autofill_music_tracks_path, params: { audio: audio, source_url: "https://pixabay.com/music/x-1/", source_tags: "kids, happy" }
    end
    assert_response :success
    assert_equal "Happy Kids", response.parsed_body.dig("fields", "title")
    assert_equal %w[allegra], response.parsed_body.dig("fields", "moods")
  ensure
    MusicAutofill.runner = nil
  end

  test "Compila con Claude: usa il file già salvato di un brano in modifica" do
    track = saved_track
    MusicAutofill.runner = ->(_) { { "is_error" => false, "structured_output" => { "title" => "Dal file salvato" } }.to_json }
    post autofill_music_tracks_path, params: { track_id: track.id }
    assert_response :success
    assert_equal "Dal file salvato", response.parsed_body.dig("fields", "title")
  ensure
    MusicAutofill.runner = nil
  end

  test "Compila con Claude: errori chiari senza file, con un file sbagliato o se Claude non risponde" do
    post autofill_music_tracks_path, params: { source_url: "https://x.y/" }
    assert_response :unprocessable_content
    assert_match "Scegli prima il file", response.parsed_body["error"]

    post autofill_music_tracks_path, params: { audio: fixture_file_upload("note.txt", "text/plain") }
    assert_response :unprocessable_content
    assert_match "MP3", response.parsed_body["error"]

    MusicAutofill.runner = ->(_) { raise MusicAutofill::Error, "Claude ci ha messo troppo: riprova tra poco." }
    post autofill_music_tracks_path, params: { audio: audio }
    assert_response :bad_gateway
    assert_match "troppo", response.parsed_body["error"]
  ensure
    MusicAutofill.runner = nil
  end

  # Brani senza file, inseriti direttamente: per filtri e paginazione il file non serve.
  def insert_tracks(count, **attributes)
    now = Time.current
    MusicTrack.insert_all!(Array.new(count) do |i|
      { title: "Brano #{format('%02d', i + 1)}", source_url: "https://pixabay.com/music/b-#{i}/", license: "CC0",
        moods: [ "allegra" ], tempo: "medio", vocals: false, enabled: true, created_at: now, updated_at: now }.merge(attributes)
    end)
  end

  test "l'homepage ha il bottone per la musicoteca" do
    get root_path
    assert_select ".azioni-testa a.bottone[href=?]", music_tracks_path, text: /Musicoteca/
  end

  test "i filtri restringono l'elenco dei brani" do
    insert_tracks(1, title: "Campanelli di Natale", moods: %w[natalizia serena], tempo: "lento", instruments: "campanelli")
    insert_tracks(1, title: "Ukulele allegro", moods: %w[allegra giocosa], tempo: "vivace", vocals: true)
    insert_tracks(1, title: "Carillon", moods: %w[dolce], tempo: "lento", enabled: false, source_tags: "music box, lullaby")

    get music_tracks_path
    assert_select ".riga-brano", 3
    assert_select ".risultati", /3 brani/

    get music_tracks_path, params: { q: { with_mood: "natalizia" } }
    assert_select ".riga-brano .riga-titolo", "Campanelli di Natale"
    assert_select ".riga-brano", 1
    assert_select ".risultati", /1 brano trovati con questi filtri/

    get music_tracks_path, params: { q: { tempo_eq: "lento" } }
    assert_select ".riga-brano", 2

    get music_tracks_path, params: { q: { voice: "con-voce" } }
    assert_select ".riga-brano .riga-titolo", "Ukulele allegro"

    get music_tracks_path, params: { q: { state: "disattivati" } }
    assert_select ".riga-brano .riga-titolo", "Carillon"

    get music_tracks_path, params: { q: { title_or_author_or_instruments_or_suitable_for_or_notes_or_source_tags_cont: "lullaby" } }
    assert_select ".riga-brano .riga-titolo", "Carillon"

    get music_tracks_path, params: { q: { with_mood: "horror" } }
    assert_select ".riga-brano", 3, "un'atmosfera fuori elenco non filtra"

    get music_tracks_path, params: { q: { with_mood: "estiva" } }
    assert_select "p.vuoto", /Nessun brano corrisponde/
  end

  test "l'ordine si sceglie solo fra quelli previsti" do
    insert_tracks(1, title: "Alfa", duration: 90)
    insert_tracks(1, title: "Zeta", duration: 30)

    get music_tracks_path, params: { q: { s: "title desc" } }
    assert_equal %w[Zeta Alfa], css_select(".riga-brano .riga-titolo").map { |e| e.text.strip }

    get music_tracks_path, params: { q: { s: "duration asc" } }
    assert_equal %w[Zeta Alfa], css_select(".riga-brano .riga-titolo").map { |e| e.text.strip }

    get music_tracks_path, params: { q: { s: "source_url asc" } }
    assert_equal %w[Alfa Zeta], css_select(".riga-brano .riga-titolo").map { |e| e.text.strip }, "ordine sconosciuto → per titolo"
  end

  test "20 brani per pagina, e i filtri restano cambiando pagina" do
    insert_tracks(45)

    get music_tracks_path
    assert_select ".riga-brano", 20
    assert_select ".paginazione-stato", /Pagina\s+1\s+di\s+3/
    assert_select ".paginazione a[rel=next][href=?]", music_tracks_path(page: 2)

    get music_tracks_path, params: { page: 3 }
    assert_select ".riga-brano", 5
    assert_select ".riga-brano .riga-titolo", "Brano 41"

    get music_tracks_path, params: { page: 99 }
    assert_select ".paginazione-stato", /Pagina\s+3\s+di\s+3/, "una pagina che non c'è porta all'ultima"

    get music_tracks_path, params: { q: { tempo_eq: "medio" }, page: 2 }
    next_link = css_select(".paginazione a[rel=next]").first["href"]
    assert_includes CGI.unescape(next_link), "q[tempo_eq]=medio"
    assert_includes next_link, "page=3"
  end

  test "con pochi brani niente paginazione" do
    insert_tracks(3)
    get music_tracks_path
    assert_select ".paginazione", 0
  end
end
