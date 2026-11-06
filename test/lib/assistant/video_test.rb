require "test_helper"

class Assistant::VideoTest < ActiveSupport::TestCase
  RESOURCES = Rails.root.join("lib/assistant/risorse")
  LOGO = RESOURCES.join("logo_trasparente.png").to_s

  setup do
    @outbox = AssistantConversation::OUTBOX_ROOT.join(SecureRandom.uuid).tap(&:mkpath)
  end

  teardown { FileUtils.rm_rf(@outbox) }

  def recipe(data, name: "_ricetta.json")
    @outbox.join(name).tap { |path| path.write(data.is_a?(String) ? data : JSON.generate(data)) }.to_s
  end

  def scene(**extra) = { "immagine" => LOGO, "durata" => 2 }.merge(extra.transform_keys(&:to_s))

  def video(**extra)
    Assistant::Video.new(recipe({ "uscita" => "prova.mp4", "scene" => [ scene ] }.merge(extra.transform_keys(&:to_s))))
  end

  def refused(data, message)
    error = assert_raises(Assistant::Video::Error) { Assistant::Video.new(recipe(data)) }
    assert_match message, error.message
  end

  test "costruisce il comando: H.264 verticale, solo file locali con il formato scelto da noi, uscita nella cartella di lavoro" do
    v = video("scene" => [ scene("movimento" => "zoom-avanti", "transizione" => { "tipo" => "slideleft", "durata" => 0.5 }),
                           scene("movimento" => "scorri-destra") ])
    cmd = v.command

    assert_equal [ 1080, 1920 ], [ v.width, v.height ]
    assert_in_delta 3.5, v.duration
    assert_equal 2, cmd.count("-protocol_whitelist")
    assert_equal [ "file" ], cmd.each_cons(2).select { |a, _| a == "-protocol_whitelist" }.map(&:last).uniq
    assert_includes cmd, "file:#{LOGO}"
    assert_equal "file:#{@outbox}/prova.mp4", cmd.last
    assert_includes cmd.join(" "), "libx264"
    assert_match "xfade=transition=slideleft:duration=0.5:offset=1.5", cmd[cmd.index("-filter_complex") + 1]
  end

  test "un taglio unisce le scene senza transizione e senza accorciarle" do
    v = video("scene" => [ scene("transizione" => "taglio"), scene ])
    assert_in_delta 4, v.duration
    assert_match "concat=n=2", v.command.join(" ")
  end

  test "scritte che entrano in scena, musica e formato 4:5" do
    @outbox.join("canzone.mp3").write("finta")
    v = video("formato" => "4:5", "musica" => { "file" => @outbox.join("canzone.mp3").to_s, "volume" => 0.6 },
              "scene" => [ scene("livelli" => [ { "immagine" => LOGO, "inizio" => 0.5, "entrata" => "dal-basso", "fine" => 1.5 } ]) ])
    graph = v.command[v.command.index("-filter_complex") + 1]

    assert_equal [ 1080, 1350 ], [ v.width, v.height ]
    assert_match "overlay=", graph
    assert_match "enable='gte(t,0.5)'", graph
    assert_match "fade=t=out:st=1.5", graph
    assert_match "volume=0.6", graph
    assert_includes v.command, "[a]"
    assert_includes v.command, "mp3"
  end

  test "la ricetta deve stare nella cartella di lavoro di una chat o delle proposte" do
    outside = Rails.root.join("tmp", "_ricetta-#{SecureRandom.hex(4)}.json")
    outside.write(JSON.generate("uscita" => "x.mp4", "scene" => [ scene ]))
    error = assert_raises(Assistant::Video::Error) { Assistant::Video.new(outside.to_s) }
    assert_match "cartella di lavoro", error.message
  ensure
    outside&.delete if outside&.exist?
  end

  test "il video esce solo con un nome semplice, senza cartelle" do
    [ "../x.mp4", "/tmp/x.mp4", "sotto/x.mp4", "x.mov", "-y.mp4", "" ].each do |name|
      refused({ "uscita" => name, "scene" => [ scene ] }, "uscita")
    end
  end

  test "legge solo file delle cartelle previste, mai i segreti né file fuori" do
    secret_dir = Rails.root.join("config")
    [ "/etc/passwd.png", "#{Dir.home}/.ssh/id_rsa", "#{@outbox}/../../../config/master.key",
      secret_dir.join("credentials.yml.enc").to_s, "relativo.png" ].each do |path|
      refused({ "uscita" => "x.mp4", "scene" => [ scene("immagine" => path) ] }, /immagine|File non trovato|percorso assoluto/)
    end

    # un collegamento nella cartella di lavoro non porta fuori
    link = @outbox.join("foto.png")
    File.symlink("/etc/hostname", link)
    refused({ "uscita" => "x.mp4", "scene" => [ scene("immagine" => link.to_s) ] }, "solo file del sito")
  end

  test "formati ammessi in base al tipo di file" do
    @outbox.join("testo.txt").write("ciao")
    @outbox.join("lista.m3u8").write("#EXTM3U\nfile:/etc/passwd\n")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("immagine" => @outbox.join("testo.txt").to_s) ] }, "formato non ammesso")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("immagine" => nil, "video" => @outbox.join("lista.m3u8").to_s) ] },
            "formato non ammesso")
  end

  test "nel filtro entrano solo numeri e parole degli elenchi" do
    refused({ "uscita" => "x.mp4", "scene" => [ scene("durata" => "2[x];movie=/etc/passwd") ] }, "durata")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("movimento" => "fermo,drawtext=text=x") ] }, "movimento")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("transizione" => "fade:offset=0"), scene ] }, "transizione")
    refused({ "uscita" => "x.mp4", "sfondo" => "white:x=1", "scene" => [ scene ] }, "colore")
    refused({ "uscita" => "x.mp4", "formato" => "8k", "scene" => [ scene ] }, "formato")
  end

  test "limiti di durata, scene e transizioni" do
    refused({ "uscita" => "x.mp4", "scene" => [] }, "scene")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("durata" => 20) ] }, "durata")
    refused({ "uscita" => "x.mp4", "scene" => Array.new(5) { scene("durata" => 14, "transizione" => "taglio") } }, "massimo è 60")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("transizione" => { "tipo" => "fade", "durata" => 2 }), scene ] },
            "più corta")
    refused({ "uscita" => "x.mp4", "scene" => [ scene("video" => LOGO) ] }, "uno solo dei due")
  end

  test "ricetta non valida" do
    error = assert_raises(Assistant::Video::Error) { Assistant::Video.new(recipe("{ non è json")) }
    assert_match "JSON", error.message
  end

  test "monta davvero il video e ne estrae i fotogrammi" do
    skip "ffmpeg non installato" unless system("which ffmpeg > /dev/null 2>&1")

    v = Assistant::Video.new(recipe({ "uscita" => "vero.mp4", "formato" => "quadrato", "sfondo" => "#FFE8C2",
                                      "scene" => [ scene("durata" => 1, "movimento" => "zoom-avanti", "transizione" => "fade"),
                                                   scene("durata" => 1, "adattamento" => "contieni") ] }))
    assert_equal @outbox.join("vero.mp4").to_s, v.render!
    assert @outbox.join("vero.mp4").size.positive?
    assert_empty @outbox.glob("_montaggio-*"), "il file provvisorio non resta"
    assert_match "Video creato", v.summary

    assert_match "ai secondi", Assistant::Video.contact_sheet(@outbox.join("vero.mp4").to_s, 4)
    assert @outbox.join("_fotogrammi-vero.jpg").file?
    assert_match "Fotogramma salvato", Assistant::Video.frame(@outbox.join("vero.mp4").to_s, "0,5")
    assert_raises(Assistant::Video::Error) { Assistant::Video.frame(@outbox.join("vero.mp4").to_s, 30) }
  end

  test "i fotogrammi si estraggono solo dai video della cartella di lavoro" do
    error = assert_raises(Assistant::Video::Error) { Assistant::Video.contact_sheet(LOGO) }
    assert_match "cartella di lavoro", error.message
  end
end
