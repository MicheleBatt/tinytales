require "json"
require "open3"

module Assistant
  # Monta un video per i social a partire da una «ricetta» JSON che Claude scrive nella cartella di lavoro
  # della chat: scene fatte di immagini (o spezzoni di video), con movimenti, scritte che entrano in scena,
  # transizioni e musica. Le grafiche e le scritte Claude le prepara con ImageMagick; qui si animano.
  #
  # Claude non usa mai ffmpeg direttamente: ffmpeg può leggere da internet e da qualsiasi file (anche
  # attraverso i filtri) e scrivere ovunque. Il comando lo costruisce questa classe, con valori controllati:
  # - legge solo file del sito, delle risorse dell'assistente, degli allegati dei post e della cartella di lavoro;
  # - per ogni file sceglie lei il formato (niente playlist o altri formati che rimandano ad altri file)
  #   e ammette solo il protocollo «file»;
  # - nel filtro entrano solo numeri e parole di elenchi fissi, mai testo libero;
  # - scrive solo nella cartella di lavoro da cui viene la ricetta.
  #
  # Funziona anche senza Rails, perché la usa bin/assistant.
  class Video
    class Error < StandardError; end

    APP_ROOT = File.expand_path("../..", __dir__)
    SITE_ROOT = ENV.fetch("ASSISTANT_SITE_ROOT", "/home/michele/Progetti/scuola-infanzia-creola")
    OUTBOX_ROOTS = %w[tmp/assistant tmp/proposte].map { |dir| File.join(APP_ROOT, dir) }.freeze
    TOKEN = /\A[a-f0-9-]{36}\z/
    FFMPEG = ENV.fetch("FFMPEG_BIN", "ffmpeg")
    FFPROBE = ENV.fetch("FFPROBE_BIN", "ffprobe")

    FORMATS = { "verticale" => [ 1080, 1920 ], "4:5" => [ 1080, 1350 ], "quadrato" => [ 1080, 1080 ] }.freeze
    FPS = 30
    MAX_TOTAL = 60
    MAX_SCENES = 20
    MAX_LAYERS = 6
    SCENE_DURATION = (0.5..15)
    TIMEOUT = 300

    MOVEMENTS = %w[fermo zoom-avanti zoom-indietro scorri-sinistra scorri-destra scorri-su scorri-giu].freeze
    FITS = %w[riempi contieni].freeze
    ENTRIES = %w[nessuna dissolvenza da-sinistra da-destra dal-basso dall-alto].freeze
    # «taglio» è il passaggio secco; le altre sono le transizioni di ffmpeg (filtro xfade).
    TRANSITIONS = %w[taglio fade fadeblack fadewhite dissolve wipeleft wiperight wipeup wipedown
                     slideleft slideright slideup slidedown smoothleft smoothright smoothup smoothdown
                     circleopen circleclose radial zoomin pixelize diagtl diagbr hlslice vuslice
                     squeezeh squeezev coverleft coverright revealleft revealright].freeze

    # Estensione → formato che ffmpeg deve usare per leggere il file (mai indovinato dal contenuto).
    IMAGES = { ".jpg" => "image2", ".jpeg" => "image2", ".png" => "image2", ".webp" => "image2" }.freeze
    VIDEOS = { ".mp4" => "mov", ".mov" => "mov", ".m4v" => "mov", ".webm" => "matroska" }.freeze
    AUDIO = { ".mp3" => "mp3", ".m4a" => "mov", ".wav" => "wav", ".ogg" => "ogg" }.freeze
    FORBIDDEN = [ /\.key\z/, /credentials/, %r{/\.env} ].freeze
    OUTPUT_NAME = /\A[\p{L}\p{N}][\p{L}\p{N}_-]*\.mp4\z/

    attr_reader :outbox, :output, :width, :height

    def initialize(recipe_path)
      path = self.class.real_path(recipe_path)
      raise Error, "La ricetta deve essere un file .json." unless File.extname(path).downcase == ".json"

      @outbox = self.class.outbox_of(path)
      @recipe = parse(path)
      validate!
    end

    # Comando ffmpeg completo, come lista di argomenti (nessuna shell di mezzo).
    def command(target = output)
      [ FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *@inputs,
        "-filter_complex", @graph, "-map", "[v]", *(@audio ? [ "-map", "[a]", "-c:a", "aac", "-b:a", "160k" ] : []),
        "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-r", FPS.to_s,
        "-movflags", "+faststart", "-t", num(@total), "-f", "mp4", "file:#{target}" ]
    end

    def duration = @total

    # Monta il video: prima in un file «_…» (che non viene conservato), poi lo rinomina solo se è riuscito,
    # così un video a metà non finisce mai fra i file proposti.
    def render!
      partial = File.join(outbox, "_montaggio-#{File.basename(output)}")
      self.class.execute(command(partial))
      File.rename(partial, output)
      output
    ensure
      File.delete(partial) if partial && File.exist?(partial)
    end

    def summary
      size = File.size(output) / 1024.0 / 1024
      "Video creato: #{output}\n#{width}×#{height}, #{num_it(@total)} s, #{@scenes.size} scene, " \
        "#{@audio ? 'con musica' : 'senza audio'}, #{format('%.1f', size).tr('.', ',')} MB.\n" \
        "Per controllarlo: #{File.join(APP_ROOT, 'bin/assistant')} fotogrammi #{output}"
    end

    # --- Controllo del video finito -------------------------------------------------------------------

    # Un foglio con `count` fotogrammi presi a intervalli regolari, per guardare il video con Read.
    def self.contact_sheet(video_path, count = 9)
      video = video_in_outbox(video_path)
      count = Integer(count, exception: false)
      raise Error, "Il numero di fotogrammi va da 2 a 16." unless count&.between?(2, 16)

      length = probe_duration(video)
      columns = count <= 4 ? 2 : (count <= 9 ? 3 : 4)
      rows = (count.to_f / columns).ceil
      target = File.join(File.dirname(video), "_fotogrammi-#{File.basename(video, '.*')}.jpg")
      step = length / count
      execute([ FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", *input_args(video),
                # tpad allunga di poco la fine, così anche l'ultimo fotogramma richiesto esiste.
                "-vf", "tpad=stop_mode=clone:stop_duration=1,fps=1/#{num(step)}:start_time=#{num(step / 2)}," \
                       "scale=360:-2,tile=#{columns}x#{rows}:padding=6:color=white",
                "-frames:v", "1", "-q:v", "3", "-f", "image2", "-update", "1", "file:#{target}" ])
      times = Array.new(count) { |i| num_it(step / 2 + i * step) }
      "Fotogrammi salvati in #{target} (guardali con Read), da sinistra a destra e dall'alto in basso, " \
        "ai secondi: #{times.join(' · ')}. Durata del video: #{num_it(length)} s."
    end

    # Un solo fotogramma a piena risoluzione, per controllare da vicino scritte e logo.
    def self.frame(video_path, seconds)
      video = video_in_outbox(video_path)
      at = Float(seconds.to_s.tr(",", "."), exception: false)
      length = probe_duration(video)
      raise Error, "Indica il secondo, fra 0 e #{num_it(length)}." unless at && at >= 0 && at <= length

      target = File.join(File.dirname(video), "_fotogramma-#{File.basename(video, '.*')}-#{num_it(at).tr(',', '_')}.jpg")
      execute([ FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", num(at), *input_args(video),
                "-frames:v", "1", "-q:v", "2", "-f", "image2", "-update", "1", "file:#{target}" ])
      "Fotogramma salvato in #{target} (guardalo con Read)."
    end

    # --- Percorsi -------------------------------------------------------------------------------------

    def self.real_path(path)
      raise Error, "Serve un percorso assoluto: #{path}" unless path.to_s.start_with?("/")

      File.realpath(path.to_s)
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "File non trovato: #{path}"
    end

    # La cartella di lavoro di una chat (tmp/assistant/<token>) o di una richiesta di proposte (tmp/proposte/<token>).
    def self.outbox_of(path)
      dir = File.dirname(path)
      ok = OUTBOX_ROOTS.any? { |root| File.exist?(root) && File.dirname(dir) == File.realpath(root) } &&
           File.basename(dir).match?(TOKEN)
      raise Error, "Il file deve stare nella cartella di lavoro della chat: #{path}" unless ok

      dir
    end

    def self.video_in_outbox(path)
      video = real_path(path)
      outbox_of(video)
      raise Error, "Non è un video (mp4, mov, m4v, webm): #{path}" unless VIDEOS.key?(File.extname(video).downcase)

      video
    end

    def self.input_args(path)
      ext = File.extname(path).downcase
      demuxer = IMAGES[ext] || VIDEOS[ext] || AUDIO[ext] or raise Error, "Formato non ammesso: #{path}"
      extra = demuxer == "image2" ? [ "-pattern_type", "none" ] : []
      [ "-protocol_whitelist", "file", "-f", demuxer, *extra, "-i", "file:#{path}" ]
    end

    def self.probe_duration(path)
      ext = File.extname(path).downcase
      out, status = Open3.capture2e(FFPROBE, "-v", "error", "-protocol_whitelist", "file", "-f", VIDEOS.fetch(ext),
                                    "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", "file:#{path}")
      value = Float(out.strip, exception: false)
      raise Error, "Non riesco a leggere il video #{path}." unless status.success? && value&.positive?

      value
    end

    # Esegue ffmpeg con un tempo massimo; in caso di errore riporta le ultime righe dei suoi messaggi.
    def self.execute(cmd)
      Open3.popen2e(*cmd, pgroup: true) do |stdin, output, wait|
        stdin.close
        reader = Thread.new { output.read }
        unless wait.join(TIMEOUT)
          Process.kill("KILL", -wait.pid) rescue nil
          raise Error, "ffmpeg ci ha messo più di #{TIMEOUT / 60} minuti: prova un video più corto o più semplice."
        end
        log = reader.value.to_s
        raise Error, "ffmpeg non è riuscito a montare il video:\n#{log.lines.last(8).join}" unless wait.value.success?
      end
    rescue Errno::ENOENT
      raise Error, "ffmpeg non è installato."
    end

    def self.num(value) = format("%.3f", value).sub(/\.?0+\z/, "")
    def self.num_it(value) = format("%.1f", value).sub(/\.0\z/, "").tr(".", ",")

    private

    def num(value) = self.class.num(value)
    def num_it(value) = self.class.num_it(value)

    def parse(path)
      data = JSON.parse(File.read(path))
      raise Error, "La ricetta deve essere un oggetto JSON." unless data.is_a?(Hash)

      data
    rescue JSON::ParserError => e
      raise Error, "La ricetta non è un JSON valido: #{e.message.lines.first.strip}"
    end

    # --- Controlli e costruzione del comando ----------------------------------------------------------

    def validate!
      @inputs = []
      @filters = []
      @input_count = 0

      name = @recipe["uscita"].to_s
      raise Error, "«uscita»: un nome come «festa-autunno.mp4» (lettere, numeri, - e _, senza cartelle)." unless name.match?(OUTPUT_NAME)

      @output = File.join(outbox, name)
      @width, @height = FORMATS.fetch(@recipe.fetch("formato", "verticale")) do
        raise Error, "«formato»: uno fra #{FORMATS.keys.join(', ')}."
      end
      @background = color(@recipe.fetch("sfondo", "#FFFFFF"), "sfondo")

      @scenes = @recipe["scene"]
      raise Error, "«scene»: una lista da 1 a #{MAX_SCENES} scene." unless @scenes.is_a?(Array) && @scenes.size.between?(1, MAX_SCENES)

      streams = @scenes.each_with_index.map { |scene, i| build_scene(scene, i) }
      video = join_scenes(streams)
      raise Error, "Il video dura #{num_it(@total)} s: il massimo è #{MAX_TOTAL} s." if @total > MAX_TOTAL

      finish(video)
      @audio = build_music(@recipe["musica"]) if @recipe["musica"]
      @graph = @filters.join(";")
    end

    def add_input(args)
      @inputs.concat(args)
      (@input_count += 1) - 1
    end

    def build_scene(scene, i)
      label = "Scena #{i + 1}"
      raise Error, "#{label}: dev'essere un oggetto JSON." unless scene.is_a?(Hash)

      d = number(scene["durata"], "#{label}, «durata»", SCENE_DURATION)
      movement = choice(scene.fetch("movimento", "fermo"), MOVEMENTS, "#{label}, «movimento»")
      fit = choice(scene.fetch("adattamento", "riempi"), FITS, "#{label}, «adattamento»")
      zoom = number(scene.fetch("intensita", 0.12), "#{label}, «intensita»", (0.02..0.4))

      index =
        if scene["immagine"] && !scene["video"]
          path = readable(scene["immagine"], IMAGES, "#{label}, «immagine»")
          add_input([ "-loop", "1", "-framerate", FPS.to_s, "-t", num(d), *self.class.input_args(path) ])
        elsif scene["video"] && !scene["immagine"]
          path = readable(scene["video"], VIDEOS, "#{label}, «video»")
          from = number(scene.fetch("da", 0), "#{label}, «da»", (0..3600))
          add_input([ "-ss", num(from), "-t", num(d), *self.class.input_args(path) ])
        else
          raise Error, "#{label}: serve «immagine» oppure «video» (uno solo dei due)."
        end

      cw, ch = canvas(movement, zoom)
      sized = fit == "riempi" ? "scale=#{cw}:#{ch}:force_original_aspect_ratio=increase,crop=#{cw}:#{ch}" :
                                "scale=#{cw}:#{ch}:force_original_aspect_ratio=decrease,pad=#{cw}:#{ch}:(ow-iw)/2:(oh-ih)/2:color=#{@background}"
      chain = [ "setpts=PTS-STARTPTS", "fps=#{FPS}", "tpad=stop_mode=clone:stop_duration=#{num(d)}",
                "trim=duration=#{num(d)}", "setpts=PTS-STARTPTS", sized, *motion(movement, zoom, d, cw, ch),
                "setsar=1", "format=yuv420p", "settb=1/#{FPS}" ]
      @filters << "[#{index}:v]#{chain.join(',')}[b#{i}]"

      layers = scene.fetch("livelli", [])
      raise Error, "#{label}, «livelli»: una lista di al massimo #{MAX_LAYERS} immagini." unless layers.is_a?(Array) && layers.size <= MAX_LAYERS

      layers.each_with_index.reduce("b#{i}") { |current, (layer, j)| build_layer(layer, current, i, j, d, label) }
        .then { |last| { label: last, duration: d, transition: transition(scene, i, label) } }
    end

    # La tela su cui si muove la «telecamera»: più grande del video nella direzione del movimento.
    # Per gli zoom si lavora al doppio della risoluzione, così l'ingrandimento è fluido e non trema.
    def canvas(movement, zoom)
      case movement
      when "zoom-avanti", "zoom-indietro" then [ even(width * 2), even(height * 2) ]
      when "scorri-sinistra", "scorri-destra" then [ even(width * (1 + zoom)), height ]
      when "scorri-su", "scorri-giu" then [ width, even(height * (1 + zoom)) ]
      else [ width, height ]
      end
    end

    def motion(movement, zoom, d, cw, ch)
      p = "(t/#{num(d)})"
      case movement
      when "zoom-avanti", "zoom-indietro"
        s = movement == "zoom-avanti" ? "(1+#{num(zoom)}*#{p})" : "(1+#{num(zoom)}*(1-#{p}))"
        [ "scale=w='2*trunc(#{cw}*#{s}/2)':h='2*trunc(#{ch}*#{s}/2)':eval=frame", "crop=#{cw}:#{ch}", "scale=#{width}:#{height}" ]
      when "scorri-destra" then [ "crop=#{width}:#{height}:x='(in_w-out_w)*#{p}':y=0" ]
      when "scorri-sinistra" then [ "crop=#{width}:#{height}:x='(in_w-out_w)*(1-#{p})':y=0" ]
      when "scorri-giu" then [ "crop=#{width}:#{height}:x=0:y='(in_h-out_h)*#{p}'" ]
      when "scorri-su" then [ "crop=#{width}:#{height}:x=0:y='(in_h-out_h)*(1-#{p})'" ]
      else []
      end
    end

    # Un'immagine (di solito un PNG trasparente grande quanto il video, con una scritta o un disegno)
    # sovrapposta alla scena, che entra al secondo «inizio» ed eventualmente sparisce al secondo «fine».
    def build_layer(layer, current, i, j, d, label)
      label = "#{label}, livello #{j + 1}"
      raise Error, "#{label}: dev'essere un oggetto JSON." unless layer.is_a?(Hash)

      path = readable(layer["immagine"], IMAGES, "#{label}, «immagine»")
      start = number(layer.fetch("inizio", 0), "#{label}, «inizio»", (0..d))
      entry = choice(layer.fetch("entrata", "dissolvenza"), ENTRIES, "#{label}, «entrata»")
      speed = number(layer.fetch("durata_entrata", 0.6), "#{label}, «durata_entrata»", (0.1..3))
      stop = layer["fine"] && number(layer["fine"], "#{label}, «fine»", (start..d))

      index = add_input([ "-loop", "1", "-framerate", FPS.to_s, "-t", num(d), *self.class.input_args(path) ])
      chain = [ "setpts=PTS-STARTPTS", "fps=#{FPS}", "scale=#{width}:#{height}:force_original_aspect_ratio=decrease", "format=rgba" ]
      chain << "fade=t=in:st=#{num(start)}:d=#{num(speed)}:alpha=1" if entry == "dissolvenza"
      chain << "fade=t=out:st=#{num(stop)}:d=0.4:alpha=1" if stop
      @filters << "[#{index}:v]#{chain.join(',')}[l#{i}_#{j}]"

      e = "(1-pow(1-clip((t-#{num(start)})/#{num(speed)},0,1),3))" # arriva veloce e rallenta
      x, y = "(W-w)/2", "(H-h)/2"
      case entry
      when "da-sinistra" then x = "(W-w)/2-(1-#{e})*((W+w)/2)"
      when "da-destra" then x = "(W-w)/2+(1-#{e})*((W+w)/2)"
      when "dall-alto" then y = "(H-h)/2-(1-#{e})*((H+h)/2)"
      when "dal-basso" then y = "(H-h)/2+(1-#{e})*((H+h)/2)"
      end
      out = "o#{i}_#{j}"
      @filters << "[#{current}][l#{i}_#{j}]overlay=x='#{x}':y='#{y}':eval=frame:eof_action=pass:enable='gte(t,#{num(start)})'[#{out}]"
      out
    end

    def transition(scene, i, label)
      return nil if i == @scenes.size - 1

      spec = scene.fetch("transizione", "fade")
      spec = { "tipo" => spec } if spec.is_a?(String)
      raise Error, "#{label}, «transizione»: un nome o un oggetto con «tipo» e «durata»." unless spec.is_a?(Hash)

      type = choice(spec.fetch("tipo", "fade"), TRANSITIONS, "#{label}, «transizione»")
      return nil if type == "taglio"

      { type:, duration: number(spec.fetch("durata", 0.7), "#{label}, durata della transizione", (0.2..2)) }
    end

    def join_scenes(streams)
      current = streams.first[:label]
      @total = streams.first[:duration]
      streams.each_cons(2).with_index(1) do |(previous, scene), i|
        out = "j#{i}"
        if (t = previous[:transition])
          if t[:duration] >= [ previous[:duration], scene[:duration] ].min
            raise Error, "Scena #{i}: la transizione (#{num_it(t[:duration])} s) dev'essere più corta delle due scene che unisce."
          end

          @filters << "[#{current}][#{scene[:label]}]xfade=transition=#{t[:type]}:duration=#{num(t[:duration])}:offset=#{num(@total - t[:duration])}[#{out}]"
          @total += scene[:duration] - t[:duration]
        else
          @filters << "[#{current}][#{scene[:label]}]concat=n=2:v=1:a=0,settb=1/#{FPS}[#{out}]"
          @total += scene[:duration]
        end
        current = out
      end
      current
    end

    def finish(video)
      fade_in = number(@recipe.fetch("dissolvenza_iniziale", 0), "«dissolvenza_iniziale»", (0..3))
      fade_out = number(@recipe.fetch("dissolvenza_finale", 0.8), "«dissolvenza_finale»", (0..3))
      chain = []
      chain << "fade=t=in:st=0:d=#{num(fade_in)}" if fade_in.positive?
      chain << "fade=t=out:st=#{num([ @total - fade_out, 0 ].max)}:d=#{num(fade_out)}" if fade_out.positive?
      chain << "format=yuv420p"
      @filters << "[#{video}]#{chain.join(',')}[v]"
    end

    def build_music(spec)
      spec = { "file" => spec } if spec.is_a?(String)
      raise Error, "«musica»: un percorso o un oggetto con «file», «volume» e «da»." unless spec.is_a?(Hash)

      path = readable(spec["file"], AUDIO, "«musica»")
      volume = number(spec.fetch("volume", 0.8), "«musica», «volume»", (0.05..1.5))
      from = number(spec.fetch("da", 0), "«musica», «da»", (0..3600))
      index = add_input([ "-stream_loop", "-1", "-ss", num(from), *self.class.input_args(path) ])
      fade = [ 2.0, @total / 2 ].min
      @filters << "[#{index}:a]atrim=duration=#{num(@total)},asetpts=PTS-STARTPTS,volume=#{num(volume)}," \
                  "afade=t=in:st=0:d=0.3,afade=t=out:st=#{num(@total - fade)}:d=#{num(fade)}[a]"
      true
    end

    # --- Valori ---------------------------------------------------------------------------------------

    # Un file che si può leggere: nel sito, nelle risorse dell'assistente, negli allegati dei post
    # o nella cartella di lavoro, con un'estensione ammessa e mai fra i segreti.
    def readable(value, kinds, label)
      raise Error, "#{label}: manca il percorso del file." if value.to_s.empty?

      path = self.class.real_path(value)
      roots = [ SITE_ROOT, File.join(APP_ROOT, "lib/assistant/risorse"), File.join(APP_ROOT, "storage"), outbox ]
                .select { |root| File.exist?(root) }.map { |root| File.realpath(root) }
      unless roots.any? { |root| path.start_with?("#{root}/") } && FORBIDDEN.none? { |pattern| path.match?(pattern) }
        raise Error, "#{label}: puoi usare solo file del sito, delle risorse, dei post o della cartella di lavoro (#{value})."
      end
      unless kinds.key?(File.extname(path).downcase)
        raise Error, "#{label}: formato non ammesso (#{kinds.keys.join(', ')}): #{value}"
      end

      path
    end

    def number(value, label, range)
      n = value.is_a?(Numeric) ? value.to_f : nil
      raise Error, "#{label}: un numero fra #{num_it(range.begin)} e #{num_it(range.end)}." unless n&.finite? && range.cover?(n)

      n
    end

    def choice(value, list, label)
      raise Error, "#{label}: uno fra #{list.join(', ')}." unless list.include?(value)

      value
    end

    def color(value, label)
      raise Error, "#{label}: un colore come #FFE8C2." unless value.to_s.match?(/\A#\h{6}\z/)

      "0x#{value.delete_prefix('#')}"
    end

    def even(value) = (value / 2.0).round * 2
  end
end
