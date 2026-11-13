require "test_helper"

class FacebookMediaTest < ActiveSupport::TestCase
  # Al posto delle Graph API: risponde con foto e video finti, su due pagine di risultati per le foto.
  class FakeClient
    attr_reader :calls

    def initialize = @calls = []

    def get(path, params = {})
      @calls << [ path, params ]
      if path.end_with?("/photos") && params[:after].nil?
        { "data" => [ photo("111111", "2026-11-10T09:00:00+0000", "Castagnata in giardino") ],
          "paging" => { "cursors" => { "after" => "c1" }, "next" => "https://graph.facebook.com/next" } }
      elsif path.end_with?("/photos")
        { "data" => [ photo("222222", "2021-02-01T12:00:00+0000", nil) ], "paging" => { "cursors" => { "after" => "c2" } } }
      else
        { "data" => [ { "id" => "333333", "created_time" => "2025-05-01T10:00:00+0000", "description" => "Saggio",
                        "length" => 84.05, "source" => "https://video-mxp1-1.xx.fbcdn.net/v.mp4",
                        "picture" => "https://scontent-mxp1-1.xx.fbcdn.net/p.jpg" } ] }
      end
    end

    def photo(id, time, name)
      { "id" => id, "created_time" => time, "name" => name, "width" => 1600, "height" => 1200,
        "images" => [ { "width" => 1600, "source" => "https://scontent-mxp1-1.xx.fbcdn.net/#{id}-grande.jpg" },
                      { "width" => 320, "source" => "https://scontent-mxp1-1.xx.fbcdn.net/#{id}-piccola.jpg" },
                      { "width" => 130, "source" => "https://scontent-mxp1-1.xx.fbcdn.net/#{id}-mini.jpg" } ] }
    end
  end

  setup do
    @client = FakeClient.new
    @media = FacebookMedia.new(social_pages(:facebook), client: @client)
    @outbox = AssistantConversation::OUTBOX_ROOT.join(SecureRandom.uuid).tap(&:mkpath)
    @fetched = []
    FacebookMedia.fetcher = lambda do |uri, path, _max|
      @fetched << uri.to_s
      FileUtils.cp(file_fixture("sample.jpg"), path)
    end
  end

  teardown do
    FacebookMedia.fetcher = nil
    FileUtils.rm_rf(@outbox)
  end

  test "serve la pagina Facebook collegata" do
    assert_raises(FacebookMedia::Error) { FacebookMedia.new(social_pages(:instagram)) }
  end

  test "l'elenco ha foto e video della pagina, dai più recenti, scorrendo tutte le pagine dei risultati" do
    listing = @media.listing
    assert_match(/\A2 foto e 1 video della pagina/, listing)
    lines = listing.lines.drop(1).map(&:strip)
    assert_equal [ "foto 111111 | 10/11/2026 | 1600×1200 | Castagnata in giardino",
                   "video 333333 | 01/05/2025 | 84 s | Saggio",
                   "foto 222222 | 01/02/2021 | 1600×1200 | (senza testo)" ], lines
    assert_equal "c1", @client.calls.second.last[:after]
    assert_equal({ type: "uploaded", fields: "id,created_time,name,width,height,images", limit: 100 }, @client.calls.first.last)
  end

  test "scarica la foto alla risoluzione più alta, con l'estensione giusta" do
    saved = @media.download!(@outbox.to_s, [ "111111" ])
    assert_equal [ @outbox.join("facebook-111111.jpg").to_s ], saved
    assert_equal [ "https://scontent-mxp1-1.xx.fbcdn.net/111111-grande.jpg" ], @fetched
    assert_equal [ "facebook-111111.jpg" ], @outbox.children.map { |path| path.basename.to_s }
  end

  test "le anteprime usano le immagini piccole e finiscono in un foglio solo" do
    message = @media.previews!(@outbox.to_s, %w[111111 333333])
    assert_includes message, "#{@outbox.join('_anteprime-facebook.jpg')} (guardale con Read)"
    assert_includes message, "2. video 333333 (video: anteprima)"
    assert_equal [ "https://scontent-mxp1-1.xx.fbcdn.net/111111-piccola.jpg", "https://scontent-mxp1-1.xx.fbcdn.net/p.jpg" ], @fetched
    assert_equal [ "_anteprime-facebook.jpg" ], @outbox.children.map { |path| path.basename.to_s }, "le miniature temporanee spariscono"
  end

  test "solo id della pagina della scuola, solo numeri, non troppi per volta" do
    error = assert_raises(FacebookMedia::Error) { @media.download!(@outbox.to_s, [ "999999" ]) }
    assert_match "non è fra le foto e i video della pagina", error.message
    assert_raises(FacebookMedia::Error) { @media.download!(@outbox.to_s, [ "../../x" ]) }
    assert_raises(FacebookMedia::Error) { @media.download!(@outbox.to_s, []) }
    assert_raises(FacebookMedia::Error) { @media.download!(@outbox.to_s, Array.new(11) { |i| "11111#{i}" }) }
    assert_empty @fetched
  end

  test "si scarica solo nella cartella di lavoro di una chat" do
    [ Rails.root.join("tmp").to_s, Rails.root.join("public").to_s, "/nessuna/cartella" ].each do |dir|
      assert_raises(FacebookMedia::Error) { @media.download!(dir, [ "111111" ]) }
    end
    assert_empty @fetched
  end

  test "un file che non è un'immagine o un video non resta nella cartella" do
    FacebookMedia.fetcher = ->(_uri, path, _max) { File.write(path, "<html>non una foto</html>") }
    error = assert_raises(FacebookMedia::Error) { @media.download!(@outbox.to_s, [ "111111" ]) }
    assert_match "non è un'immagine o un video", error.message
    assert_empty @outbox.children
  end

  test "solo indirizzi https dei server di Facebook" do
    evil = FakeClient.new
    def evil.photo(id, time, name)
      super.merge("images" => [ { "width" => 1600, "source" => "https://altro-sito.example/#{id}.jpg" } ])
    end
    media = FacebookMedia.new(social_pages(:facebook), client: evil)
    error = assert_raises(FacebookMedia::Error) { media.download!(@outbox.to_s, [ "111111" ]) }
    assert_match "indirizzo del file", error.message
    assert_empty @fetched
  end
end
