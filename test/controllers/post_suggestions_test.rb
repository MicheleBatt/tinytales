require "test_helper"

class PostSuggestionsTest < ActionDispatch::IntegrationTest
  # Al posto di Claude Code: lavora un po', salva tre proposte come file (una fuori periodo),
  # più un file rovinato, e chiude. L'ultima proposta arriva solo alla fine, senza altri eventi dopo.
  class FakeRunner
    cattr_accessor :proposals

    def initialize(batch)
      @batch = batch
    end

    def run(_message = nil, attachments: [])
      yield({ type: "activity", text: "Leggo orari_calendario.html" })
      yield({ type: "delta", text: "Guardo il calendario.\n" })
      *first, last = proposals
      first.each_with_index do |proposal, index|
        @batch.outbox.join(format("proposta-%02d.json", index + 1)).write(JSON.generate(proposal))
        yield({ type: "activity", text: "Scrivo proposta-0#{index + 1}.json" })
      end
      @batch.outbox.join("proposta-09.json").write("{ non è json")
      "Ho proposto due post\nper coprire dicembre.".chars.each_slice(5) { |piece| yield({ type: "delta", text: piece.join }) }
      @batch.outbox.join("proposta-10.json").write(JSON.generate(last))
      yield({ type: "done", error: nil })
    end

    def stop; end
  end

  setup do
    @original_runner = PostSuggestionsController.runner_class
    PostSuggestionsController.runner_class = FakeRunner
    @token = SecureRandom.uuid
    @batch = PostSuggestionBatch.new(@token)
    graphic = @batch.outbox.join("auguri.png")
    FileUtils.cp(file_fixture("sample.jpg"), graphic)
    FakeRunner.proposals = [
      { "titolo" => "Auguri di Natale", "data" => "2026-12-22T20:30", "testo" => "Buon Natale!\nDa tutti noi.",
        "note" => "", "file" => [ graphic.to_s ], "motivo" => "Dicembre è scoperto." },
      { "titolo" => "Troppo lontano", "data" => "2027-06-01T20:30", "testo" => "", "note" => "", "file" => [] },
      { "titolo" => "Lavoretti", "data" => "2026-12-03T20:30", "testo" => "",
        "note" => "Manca la foto dei lavoretti.", "file" => [ "/etc/passwd" ], "motivo" => "" }
    ]
  end

  teardown do
    PostSuggestionsController.runner_class = @original_runner
    @batch.discard!
  end

  def events
    response.body.lines.map { |line| JSON.parse(line) }
  end

  test "l'elenco ha il bottone e la finestra con la spiegazione" do
    get posts_path
    assert_select ".azioni-testa button.bottone-claude[data-action='post-suggestions#open']", /Proponi post con Claude/
    assert_select "dialog.proposte .proposte-intro", /Nel database\s+non viene salvato niente/
  end

  test "trasmette stato e proposte valide, scartando quelle fuori periodo, senza toccare il database" do
    travel_to Time.zone.local(2026, 10, 27, 10) do
      assert_no_difference "Post.count" do
        post post_suggestions_path, params: { token: @token }
      end
    end
    assert_response :success
    assert_equal "application/x-ndjson", response.media_type

    assert_includes events, { "type" => "activity", "text" => "Leggo orari_calendario.html" }
    assert_includes events, { "type" => "status", "text" => "Guardo il calendario." }
    proposals = events.select { |e| e["type"] == "proposal" }.map { |e| e["proposal"] }
    assert_equal [ "Auguri di Natale", "Lavoretti" ], proposals.map { |p| p["title"] }
    assert_equal [ "auguri.png" ], proposals.first["files"].map { |f| f["name"] }
    assert_empty proposals.last["files"], "un file fuori dalle cartelle permesse non si allega"
    rejected = events.select { |e| e["type"] == "rejected" }.map { |e| e["text"] }
    assert_match(/fuori dai prossimi tre mesi/, rejected.first)
    assert_match(/proposta-09.json: il file non è JSON valido/, rejected.last)
    assert_includes events, { "type" => "status", "text" => "Ho proposto due post" }
    assert_equal({ "type" => "done", "summary" => "per coprire dicembre.", "error" => nil }, events.last)
    assert_empty @batch.outbox.glob("proposta-*.json"), "i file letti vengono rinominati"
    assert_equal 2, @batch.proposals.size

    get proposals.first["files"].first["url"]
    assert_response :success
  end

  test "approvando, le proposte tenute diventano bozze su Facebook, con i file; poi la cartella sparisce" do
    travel_to(Time.zone.local(2026, 10, 27, 10)) { post post_suggestions_path, params: { token: @token } }
    ids = events.select { |e| e["type"] == "proposal" }.map { |e| e.dig("proposal", "id") }

    assert_difference "Post.count", 1 do
      post approve_post_suggestions_path(@token), params: { ids: [ ids.first ] }
    end
    assert_response :success
    assert_equal({ "created" => 1, "redirect" => posts_path }, response.parsed_body)

    created = Post.order(:id).last
    assert created.draft?
    assert_equal "Auguri di Natale", created.title
    assert_equal "Buon Natale!\nDa tutti noi.", created.body
    assert_equal Time.zone.local(2026, 12, 22, 20, 30), created.publish_at
    assert_equal [ "facebook" ], created.social_pages.map(&:platform)
    assert_equal [ "auguri.png" ], created.ordered_media.map { |m| m.filename.to_s }
    assert_not PostSuggestionBatch::ROOT.join(@token).exist?

    follow_redirect! rescue nil
    get posts_path
    assert_select ".flash, .avviso, [class*=notice]", /Creata 1 bozza proposta da Claude/
  end

  test "annulla tutto cancella proposte e file, senza creare niente" do
    travel_to(Time.zone.local(2026, 10, 27, 10)) { post post_suggestions_path, params: { token: @token } }
    assert_no_difference "Post.count" do
      delete post_suggestion_path(@token)
    end
    assert_response :no_content
    assert_not PostSuggestionBatch::ROOT.join(@token).exist?
  end

  test "token e file non validi non passano" do
    post post_suggestions_path, params: { token: "../../etc" }
    assert_response :unprocessable_content

    get post_suggestion_file_path(@token, "proposte.json")
    assert_response :not_found
    delete post_suggestion_path("non-un-token")
    assert_response :not_found
  end
end
