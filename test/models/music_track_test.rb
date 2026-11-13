require "test_helper"

class MusicTrackTest < ActiveSupport::TestCase
  def audio(name = "brano.mp3", content_type: "audio/mpeg")
    Rack::Test::UploadedFile.new(file_fixture(name), content_type, original_filename: name)
  end

  def track(**attributes)
    MusicTrack.new({ title: "Giornata felice", author: "Qualcuno", source_url: "https://pixabay.com/music/giornata-123/",
                     license: "Pixabay Content License", moods: %w[allegra giocosa], tempo: "vivace",
                     instruments: "ukulele", suitable_for: "feste", audio: audio }.merge(attributes))
  end

  test "un brano completo si salva e l'app ne legge la durata" do
    t = track
    assert t.save, t.errors.full_messages.to_sentence
    assert_in_delta 1.0, t.duration, 0.15
    assert_equal "0:01", t.duration_label
    assert t.enabled?
  end

  test "servono file audio, titolo, link https, licenza ammessa, atmosfere dell'elenco e ritmo" do
    assert_not track(audio: nil).valid?
    assert_not track(title: "").valid?
    assert_not track(source_url: "pixabay.com/x").valid?
    assert_not track(source_url: "http://pixabay.com/x").valid?
    assert_not track(license: "Tutti i diritti riservati").valid?
    assert_not track(moods: []).valid?
    assert_not track(moods: %w[allegra horror]).valid?
    assert_not track(tempo: "frenetico").valid?
    assert track(license: "CC0").valid?
  end

  test "rifiuta i file che non sono audio, anche con l'estensione giusta" do
    fake = Rack::Test::UploadedFile.new(file_fixture("note.txt"), "audio/mpeg", original_filename: "finto.mp3")
    t = track(audio: fake)
    assert_not t.valid?
    assert_includes t.errors[:audio], "non è un file audio leggibile"

    t = track(audio: Rack::Test::UploadedFile.new(file_fixture("note.txt"), "text/plain"))
    assert_not t.valid?
    assert_match "dev'essere un file", t.errors[:audio].to_sentence
  end

  test "le atmosfere vuote del form si tolgono" do
    t = track(moods: [ "", "dolce", "dolce" ])
    assert t.valid?
    assert_equal [ "dolce" ], t.moods
  end

  test "per Claude: solo i brani attivi, con la scheda e il numero" do
    on = track.tap(&:save!)
    off = track(title: "Spento", enabled: false).tap(&:save!)

    text = MusicTrack.assistant_listing
    assert_match "Musicoteca: 1 brani", text
    assert_match "brano #{on.id}: «Giornata felice» di Qualcuno · 0:01 · ritmo vivace · strumentale", text
    assert_match "atmosfera: allegra, giocosa", text
    assert_match "adatto a: feste", text
    assert_no_match "Spento", text

    found = MusicTrack.for_video(on.id)
    assert_equal ".mp3", found[:ext]
    assert File.file?(found[:path])
    assert_nil MusicTrack.for_video(off.id), "un brano disattivato non si usa"
    assert_nil MusicTrack.for_video(0)
  end

  test "musicoteca vuota" do
    assert_match "è vuota", MusicTrack.assistant_listing
  end
end
