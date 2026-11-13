require "test_helper"

class VideoSetupTest < ActiveSupport::TestCase
  LOGO = Rails.root.join("lib/assistant/risorse/logo_trasparente.png").to_s

  setup do
    @outbox = AssistantConversation::OUTBOX_ROOT.join(SecureRandom.uuid).tap(&:mkpath)
    post = posts(:mensa)
    post.media.attach(io: file_fixture("sample.jpg").open, filename: "mensa.jpg", content_type: "image/jpeg")
    @photo = File.realpath(ActiveStorage::Blob.service.path_for(post.media.last.blob.key))
  end

  teardown do
    VideoSetup.reset!
    FileUtils.rm_rf(@outbox)
  end

  def video(data)
    recipe = @outbox.join("_ricetta.json")
    recipe.write(JSON.generate({ "uscita" => "prova.mp4", "formato" => "quadrato" }.merge(data)))
    Assistant::Video.new(recipe.to_s)
  end

  test "una foto allegata a un post si usa come scena: il formato lo dice il database" do
    assert_equal "", File.extname(@photo), "in Active Storage il file non ha estensione"

    error = assert_raises(Assistant::Video::Error) { video("scene" => [ { "immagine" => @photo, "durata" => 1 } ]) }
    assert_match(/formato non ammesso|puoi usare solo/, error.message, "senza l'app il file non si usa")

    VideoSetup.apply!
    v = video("scene" => [ { "immagine" => @photo, "durata" => 1 } ])
    assert_includes v.command.each_cons(4).to_a, [ "-f", "image2", "-pattern_type", "none" ]
    assert_includes v.command, "file:#{@photo}"
  end

  test "un file di storage che non è un allegato non si usa" do
    VideoSetup.apply!
    stray = File.join(ActiveStorage::Blob.service.root, "zz", "zz", "nonunallegato")
    FileUtils.mkdir_p(File.dirname(stray))
    File.write(stray, "x")
    error = assert_raises(Assistant::Video::Error) { video("scene" => [ { "immagine" => stray, "durata" => 1 } ]) }
    assert_match "formato non ammesso", error.message
  ensure
    FileUtils.rm_rf(File.join(ActiveStorage::Blob.service.root, "zz"))
  end

  test "un allegato si usa solo per il suo tipo: una foto non diventa musica" do
    VideoSetup.apply!
    error = assert_raises(Assistant::Video::Error) do
      video("scene" => [ { "video" => @photo, "durata" => 1 } ])
    end
    assert_match "formato non ammesso", error.message
  end

  test "monta davvero un video con una foto di un post e un brano della musicoteca" do
    skip "ffmpeg non installato" unless system("which ffmpeg > /dev/null 2>&1")

    track = MusicTrack.create!(title: "Giornata felice", source_url: "https://pixabay.com/music/x-1/", license: "CC0",
                               moods: %w[allegra], tempo: "vivace",
                               audio: { io: file_fixture("brano.mp3").open, filename: "brano.mp3", content_type: "audio/mpeg" })
    VideoSetup.apply!
    v = video("musica" => { "brano" => track.id },
              "scene" => [ { "immagine" => @photo, "durata" => 1, "movimento" => "zoom-avanti" },
                           { "immagine" => LOGO, "durata" => 1, "adattamento" => "contieni" } ])
    v.render!
    assert @outbox.join("prova.mp4").size.positive?
    assert_match "musica «Giornata felice» (brano #{track.id})", v.summary
  end
end
