require "open3"
require "json"

# Analizza un file audio con ffprobe e ffmpeg, per dare a Claude qualcosa da «vedere» al posto dell'ascolto:
# - durata e informazioni salvate nel file (titolo, artista, genere…);
# - volume percepito nel tempo (a blocchi di qualche secondo): dice se il brano parte piano, cresce, sfuma;
# - una stima del tempo in battiti al minuto, dall'andamento dell'energia nei primi 60 secondi.
# Tutto locale: nessuna rete, solo il protocollo «file» e il formato scelto in base all'estensione.
class AudioAnalysis
  FORMATS = Assistant::Video::AUDIO
  SAMPLE_RATE = 11_025
  HOP = 256 # campioni per finestra di energia (circa 23 ms)
  TEMPO_SECONDS = 60
  TIMEOUT = 60
  MIN_CLARITY = 0.3 # correlazione minima perché un ritmo si consideri chiaro
  MIN_STRENGTH = 0.02 # forza minima degli attacchi rispetto al volume medio

  Result = Struct.new(:duration, :tags, :loudness, :loudness_range, :segments, :bpm, keyword_init: true) do
    # Il riassunto in testo per Claude.
    def to_prompt
      lines = []
      lines << "Durata: #{format('%d:%02d', duration.round / 60, duration.round % 60)}" if duration
      lines << "Informazioni nel file: #{tags.map { |k, v| "#{k} = #{v}" }.join('; ')}" if tags.any?
      lines << "Volume medio: #{loudness} LUFS; variazione di volume (LRA): #{loudness_range} LU" if loudness
      lines << "Tempo stimato: circa #{bpm} battiti al minuto (stima automatica, può essere il doppio o la metà)" if bpm
      if segments.any?
        lines << "Volume nel tempo (LUFS, più alto = più forte):"
        segments.each { |s| lines << "  #{s[:from]}–#{s[:to]}: #{s[:lufs]}" }
      end
      lines.join("\n")
    end
  end

  def initialize(path, extension)
    @path = path
    @format = FORMATS[extension.to_s.downcase] or raise ArgumentError, "formato audio non ammesso: #{extension}"
  end

  attr_reader :tempo_clarity, :onset_strength

  def call
    info = probe
    duration = info.dig("format", "duration").to_f
    loudness, range, segments = loudness_profile(duration)
    Result.new(duration: duration.positive? ? duration : nil, tags: tags(info), loudness:, loudness_range: range,
               segments:, bpm: tempo)
  end

  private

  def input = [ "-protocol_whitelist", "file", "-f", @format, "-i", "file:#{@path}" ]

  def probe
    out, status = run(ENV.fetch("FFPROBE_BIN", "ffprobe"), "-v", "error", "-protocol_whitelist", "file", "-f", @format,
                      "-show_entries", "format=duration:format_tags", "-of", "json", "file:#{@path}")
    status.success? ? JSON.parse(out) : {}
  rescue JSON::ParserError
    {}
  end

  # Solo le informazioni utili, accorciate: sono testo scritto da altri, non istruzioni.
  def tags(info)
    (info.dig("format", "tags") || {})
      .transform_keys(&:downcase)
      .slice("title", "artist", "album", "genre", "comment", "date", "description")
      .transform_values { |v| v.to_s.gsub(/\s+/, " ").strip[0, 200] }
      .reject { |_, v| v.empty? }
  end

  # Il filtro ebur128 scrive una riga ogni 0,1 s con il volume «short-term» (S, ultimi 3 secondi):
  # la riassumiamo a blocchi, al massimo una dozzina.
  def loudness_profile(duration)
    _, err, = Open3.capture3(ENV.fetch("FFMPEG_BIN", "ffmpeg"), "-hide_banner", "-nostats", "-nostdin", *input,
                             "-af", "ebur128=peak=none", "-f", "null", "-")
    points = err.scan(/t:\s*([\d.]+).*?S:\s*(-?[\d.]+)/).map { |t, s| [ t.to_f, s.to_f ] }.select { |_, s| s > -70 }
    integrated = err[/Integrated loudness:.*?I:\s*(-?[\d.]+)/m, 1]&.to_f
    range = err[/Loudness range:.*?LRA:\s*([\d.]+)/m, 1]&.to_f
    return [ integrated, range, [] ] if points.empty? || duration <= 0

    block = [ [ (duration / 12).ceil, 5 ].max, 30 ].min
    segments = points.group_by { |t, _| (t / block).floor }.sort.map do |i, list|
      { from: clock(i * block), to: clock([ (i + 1) * block, duration ].min), lufs: (list.sum { |_, s| s } / list.size).round(1) }
    end
    [ integrated, range, segments ]
  end

  # Stima del tempo: energia a finestre, aumenti di energia (attacchi delle note), autocorrelazione
  # fra 60 e 180 battiti al minuto. Senza un ritmo chiaro restituisce nil.
  def tempo
    raw, status = Open3.capture2(ENV.fetch("FFMPEG_BIN", "ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin",
                                 *input, "-t", TEMPO_SECONDS.to_s, "-ac", "1", "-ar", SAMPLE_RATE.to_s,
                                 "-f", "s16le", "-", binmode: true)
    return nil unless status.success?

    samples = raw.unpack("s<*")
    energy = samples.each_slice(HOP).map { |w| w.sum { |x| x * x }.fdiv(w.size) }
    onset = energy.each_cons(2).map { |a, b| [ b - a, 0 ].max }
    return nil if onset.size < 200

    # Lisciata su tre finestre, così un battito che cade fra due finestre conta per intero.
    onset = onset.each_cons(3).map { |a, b, c| (a + b + c) / 3.0 }
    mean = onset.sum / onset.size
    onset = onset.map { |v| v - mean }
    frames_per_second = SAMPLE_RATE.fdiv(HOP)
    lags = ((60 * frames_per_second / 180).floor..(60 * frames_per_second / 60).ceil)
    zero = onset.sum { |v| v * v }
    return nil unless zero.positive?

    # Le variazioni di energia devono essere forti rispetto al volume: una nota tenuta (o il rumore della
    # compressione MP3) ha variazioni minuscole ma regolari, che non sono un ritmo.
    @onset_strength = Math.sqrt(zero / onset.size) / (energy.sum / energy.size)
    return nil if @onset_strength < MIN_STRENGTH

    # Correlazione media per ogni ritardo, pesata verso i tempi più comuni (intorno a 120): evita di scambiare
    # un tempo con la sua metà, che ha una correlazione quasi uguale.
    scores = lags.to_h do |lag|
      bpm = 60 * frames_per_second / lag
      correlation = (0...(onset.size - lag)).sum { |i| onset[i] * onset[i + lag] } / (onset.size - lag) / (zero / onset.size)
      [ lag, [ correlation, correlation * Math.exp(-0.5 * (Math.log2(bpm / 120.0) / 0.9)**2) ] ]
    end
    best, (correlation, _) = scores.max_by { |_, (_, weighted)| weighted }
    @tempo_clarity = correlation
    return nil unless correlation > MIN_CLARITY # ritmo poco chiaro

    (60 * frames_per_second / best).round
  end

  def run(*cmd)
    Open3.capture2(*cmd)
  end

  def clock(seconds) = format("%d:%02d", seconds.to_i / 60, seconds.to_i % 60)
end
