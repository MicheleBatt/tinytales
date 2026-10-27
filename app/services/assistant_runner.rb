require "open3"

# Lancia Claude Code in modalità non interattiva per una conversazione dell'assistente
# e trasforma il suo output in eventi semplici per il browser:
#   { type: "delta", text: }      un pezzo di risposta
#   { type: "activity", text: }   cosa sta facendo (legge un file, crea un'immagine…)
#   { type: "done", error: }      fine della risposta
#
# Claude parte dalla cartella del sito, così carica memoria e convenzioni del progetto.
# Può leggere solo sito, app e memoria (non i segreti dell'app: chiavi e credenziali);
# può scrivere solo nella cartella di lavoro della chat;
# da Bash può usare solo ImageMagick (con regole che gli permettono di leggere le stesse cartelle
# e di scrivere solo nella cartella di lavoro) e i comandi di sola lettura `bin/assistant`.
class AssistantRunner
  CLAUDE = ENV.fetch("CLAUDE_BIN", File.expand_path("~/.local/bin/claude"))
  SITE_ROOT = Pathname(ENV.fetch("ASSISTANT_SITE_ROOT", "/home/michele/Progetti/scuola-infanzia-creola"))
  MEMORY_DIR = Pathname(File.expand_path("~/.claude/projects/-home-michele-Progetti-scuola-infanzia-creola/memory"))
  RESOURCES = Rails.root.join("lib/assistant/risorse")
  INSTRUCTIONS = Rails.root.join("lib/assistant/istruzioni.md")
  ASSISTANT_BIN = Rails.root.join("bin/assistant").to_s
  IMAGE_TOOLS = %w[convert magick montage composite identify].freeze
  # File dell'app che Claude non deve mai leggere: decifrano le credenziali (token di Facebook compreso).
  # Anche i log, che non gli servono e possono contenere dettagli delle richieste.
  SECRETS = %w[config/*.key config/credentials* config/credentials/** .env* log/**].freeze
  POLICY_ROOT = Rails.root.join("tmp/imagemagick")
  # Gli unici strumenti di Claude: niente web, sotto-agenti, notebook o skill.
  TOOLS = %w[Read Glob Grep Edit Write Bash].freeze
  # Le sole variabili d'ambiente che passano a Claude: quelle per funzionare e per avviare Ruby (bin/assistant).
  # Tutte le altre (chiavi, password, token di altri progetti) restano fuori.
  ENV_KEEP = %w[HOME USER LOGNAME PATH SHELL TERM LANG LANGUAGE TZ TMPDIR RAILS_ENV
                GEM_HOME GEM_PATH MY_RUBY_HOME RUBY_VERSION IRBRC].freeze
  ENV_KEEP_PREFIXES = %w[LC_ rvm_ ANTHROPIC_ CLAUDE_CONFIG_DIR].freeze
  TIMEOUT = 15.minutes

  def initialize(conversation, form_state: {})
    @conversation = conversation
    @form_state = form_state.to_h.with_indifferent_access
  end

  def command
    # Nelle regole di Claude Code un percorso assoluto si scrive con due barre iniziali: Edit(//home/...).
    allowed = readable_roots.map { |root| "Read(/#{root}/**)" } +
              [ "Glob", "Grep", "Edit(/#{@conversation.outbox}/**)" ] +
              IMAGE_TOOLS.map { |tool| "Bash(#{tool}:*)" } +
              [ "Bash(#{ASSISTANT_BIN}:*)" ]
    denied = SECRETS.flat_map { |pattern| [ "Read(/#{Rails.root}/#{pattern})", "Edit(/#{Rails.root}/#{pattern})" ] } +
             [ "Read(/#{SITE_ROOT}/.env*)" ] +
             outside_paths.flat_map { |path| [ "Read(/#{path})", "Read(/#{path}/**)" ] } +
             [ "Read(/#{MEMORY_DIR.parent}/*.jsonl)" ] # le trascrizioni delle sessioni, anche quelle nuove

    cmd = [ CLAUDE, "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "default", "--max-turns", "40",
            # Nessuna impostazione esterna (i permessi accumulati nelle impostazioni del sito e della home,
            # hook, plugin), nessun connettore MCP dell'account, solo gli strumenti elencati, niente skill.
            "--setting-sources", "", "--strict-mcp-config", "--tools", TOOLS.join(","), "--disable-slash-commands",
            "--append-system-prompt", system_prompt,
            "--add-dir", Rails.root.to_s, "--add-dir", @conversation.outbox.to_s ]
    cmd += [ "--add-dir", MEMORY_DIR.to_s ] if MEMORY_DIR.directory?
    cmd += [ "--resume", @conversation.claude_session_id ] if @conversation.claude_session_id.present?
    cmd + [ "--allowedTools", *allowed, "--disallowedTools", *denied ]
  end

  # L'ambiente di Claude: solo le variabili necessarie (senza quelle di Bundler dell'app e senza DATABASE,
  # che rompe alcuni comandi di Rails), più le regole di ImageMagick.
  def claude_env
    Bundler.unbundled_env
           .select { |key, _| ENV_KEEP.include?(key) || ENV_KEEP_PREFIXES.any? { |prefix| key.start_with?(prefix) } }
           .merge("MAGICK_CONFIGURE_PATH" => imagemagick_policy.to_s)
  end

  # Le cartelle che Claude può leggere: sito, app (tranne i segreti), memoria del progetto.
  def readable_roots
    [ SITE_ROOT, Rails.root, (MEMORY_DIR if MEMORY_DIR.directory?) ].compact.map(&:to_s)
  end

  # Tutto ciò che sta fuori dalle cartelle leggibili: i divieti valgono anche per Grep e Glob, che altrimenti
  # cercherebbero ovunque. Si risale da ogni cartella leggibile fino alla home e, a ogni livello, si vieta
  # quello che non porta a una cartella leggibile (altri progetti, file personali, ~/.ssh, trascrizioni di Claude…).
  def outside_paths
    roots = readable_roots.map { |root| Pathname(root) }
    home = Pathname(Dir.home)
    keep = roots.flat_map { |root| root.ascend.take_while { |dir| dir.to_s.start_with?(home.to_s) }.to_a }.uniq
    parents = keep - roots
    blocked = parents.flat_map do |dir|
      next [] unless dir.directory?

      dir.children.reject { |child| keep.include?(child) }
    end
    (blocked + %w[/tmp /media /mnt /root].map { |dir| Pathname(dir) }).map(&:to_s).sort
  rescue SystemCallError
    %w[/tmp /media /mnt /root]
  end

  # Regole per ImageMagick, che altrimenti potrebbe leggere qualsiasi file (anche come testo, con text:)
  # e scrivere ovunque: legge solo sito, risorse e file dei post, e scrive solo nella cartella di lavoro.
  # Il file sta fuori dalla cartella di lavoro, così Claude non può modificarlo.
  def imagemagick_policy
    dir = POLICY_ROOT.join(@conversation.outbox.basename.to_s).tap(&:mkpath)
    temporary = dir.join("tmp").tap(&:mkpath) # i file temporanei di ImageMagick, al posto di /tmp
    reads = [ SITE_ROOT, Rails.root.join("lib/assistant/risorse"), Rails.root.join("storage") ]
    rules = [ %(<policy domain="coder" rights="none" pattern="{TEXT,TXT,URL,HTTP,HTTPS,FTP,EPHEMERAL,MSL}" />),
              # PostScript, PDF e programmi esterni (Ghostscript, ffmpeg…): a Claude non servono.
              %(<policy domain="coder" rights="none" pattern="{PS,PS2,PS3,EPS,EPI,EPSF,EPSI,EPT,PDF,PDFA,AI,XPS,SHOW,WIN,X}" />),
              %(<policy domain="delegate" rights="none" pattern="*" />),
              %(<policy domain="path" rights="none" pattern="/*" />) ] +
            reads.map { |root| %(<policy domain="path" rights="read" pattern="#{root}/*" />) } +
            [ %(<policy domain="resource" name="temporary-path" value="#{temporary}" />),
              %(<policy domain="path" rights="read|write" pattern="#{temporary}/*" />),
              %(<policy domain="path" rights="read|write" pattern="#{@conversation.outbox}/*" />),
              %(<policy domain="path" rights="none" pattern="*.key" />),
              %(<policy domain="path" rights="none" pattern="*credentials*" />),
              %(<policy domain="path" rights="none" pattern="*/.env*" />),
              # ImageMagick confronta il percorso così com'è scritto: senza questa regola
              # «cartella-di-lavoro/../../public/x.png» passerebbe per la cartella di lavoro.
              %(<policy domain="path" rights="none" pattern="*..*" />) ]
    dir.join("policy.xml").write("<policymap>\n#{rules.map { |r| "  #{r}\n" }.join}</policymap>\n")
    dir
  end

  def system_prompt
    format(INSTRUCTIONS.read, app_root: Rails.root, site_root: SITE_ROOT, outbox: @conversation.outbox,
                              resources: RESOURCES, assistant_bin: ASSISTANT_BIN)
  end

  # Il messaggio come lo riceve Claude: prima lo stato del form, poi gli eventuali file allegati,
  # poi le parole della persona.
  def prompt(message, attachments = [])
    s = @form_state
    media = Array(s[:media]).presence&.join(", ") || "nessuno"
    new_files = Array(s[:new_files]).presence&.join(", ")
    <<~TXT
      [Stato attuale del form, anche se non ancora salvato]
      Post: #{@conversation.post_id ? "id #{@conversation.post_id}" : "nuovo, non ancora salvato"} · stato: #{s[:status].presence || "bozza"}
      Titolo: #{s[:title]}
      Data e ora di pubblicazione: #{s[:publish_at].presence || "non impostata"}
      Pagine social: #{Array(s[:pages]).join(", ").presence || "nessuna"}
      File già allegati, in ordine: #{media}#{"\nNuovi file scelti, da caricare: #{new_files}" if new_files}
      Note:
      #{s[:notes].presence || "(nessuna)"}
      Testo del post:
      <<<
      #{s[:body]}
      >>>
      #{attachments_section(attachments)}
      [Messaggio]
      #{message}
    TXT
  end

  def attachments_section(attachments)
    return "" if attachments.blank?

    lines = attachments.map do |a|
      "- #{@conversation.outbox.join(a['name'])} · #{a['kind']} · #{human_size(a['size'].to_i)}" \
        "#{" (originale: #{a['original']})" if a['original'] != a['name']}"
    end
    "\n[File allegati dalla persona a questo messaggio, nella cartella di lavoro]\n#{lines.join("\n")}\n"
  end

  def run(message, attachments: [])
    env = claude_env
    parser = EventParser.new

    Open3.popen3(env, *command, chdir: SITE_ROOT.to_s, pgroup: true, unsetenv_others: true) do |stdin, stdout, stderr, wait|
      @pid = wait.pid
      stdin.write(prompt(message, attachments))
      stdin.close
      watchdog = Thread.new { sleep self.class::TIMEOUT; stop }
      errors = Thread.new { stderr.read }

      stdout.each_line do |line|
        parser.parse(line).each do |event|
          remember_session(event[:session_id]) if event[:type] == "session"
          yield event unless event[:type] == "session"
        end
      end

      watchdog.kill
      status = wait.value
      unless parser.finished?
        detail = errors.value.to_s.strip.lines.last.to_s.strip
        yield({ type: "done", error: "Claude Code si è fermato prima di finire#{": #{detail}" if detail.present?} (codice #{status.exitstatus})." })
      end
    end
  rescue Errno::ENOENT
    yield({ type: "done", error: "Claude Code non trovato in #{CLAUDE}." })
  end

  # Ferma Claude e tutto ciò che ha avviato (per esempio un convert ancora in corso).
  def stop
    Process.kill("TERM", -@pid) if @pid
  rescue Errno::ESRCH
    nil
  end

  private

  def human_size(bytes)
    if bytes < 1024 then "#{bytes} byte"
    elsif bytes < 1024 * 1024 then "#{(bytes / 1024.0).round} KB"
    else "#{format('%.1f', bytes / 1024.0 / 1024).tr('.', ',')} MB"
    end
  end

  def remember_session(session_id)
    return if session_id.blank? || session_id == @conversation.claude_session_id

    @conversation.update_column(:claude_session_id, session_id)
  end

  # Traduce le righe JSON di `claude --output-format stream-json` in eventi per il browser.
  class EventParser
    def initialize
      @finished = false
      @text_blocks = 0
    end

    def finished? = @finished

    def parse(line)
      event = JSON.parse(line)
      case event["type"]
      when "system"
        event["subtype"] == "init" ? [ { type: "session", session_id: event["session_id"] } ] : []
      when "stream_event"
        stream_event(event["event"] || {})
      when "assistant"
        Array(event.dig("message", "content")).filter_map { |block| activity(block) if block["type"] == "tool_use" }
      when "result"
        @finished = true
        error = event["is_error"] ? (event["result"].presence || "Claude Code ha segnalato un errore.") : nil
        [ { type: "done", error: } ]
      else
        []
      end
    rescue JSON::ParserError
      []
    end

    private

    def stream_event(event)
      case event["type"]
      when "content_block_start"
        if event.dig("content_block", "type") == "text"
          @text_blocks += 1
          return [ { type: "delta", text: "\n\n" } ] if @text_blocks > 1
        end
        []
      when "content_block_delta"
        delta = event["delta"] || {}
        delta["type"] == "text_delta" ? [ { type: "delta", text: delta["text"].to_s } ] : []
      else
        []
      end
    end

    def activity(block)
      input = block["input"] || {}
      file = File.basename(input["file_path"].to_s)
      text =
        case block["name"]
        when "Read" then "Leggo #{file}"
        when "Write", "Edit" then "Scrivo #{file}"
        when "Glob", "Grep" then "Cerco nei file"
        when "Bash" then bash_activity(input["command"].to_s.squish)
        when "WebSearch", "WebFetch" then "Cerco sul web"
        else block["name"].to_s
        end
      { type: "activity", text: }
    end

    # I comandi più frequenti, detti a parole.
    def bash_activity(command)
      case command
      when /\A\S*bin\/assistant posts\z/ then "Guardo l'elenco dei post"
      when /\A\S*bin\/assistant post (\d+)\z/ then "Leggo il post #{$1}"
      when /\A(convert|magick|montage|composite)\b/
        output = command.scan(/\S+\.(?:jpe?g|png|webp|gif)\b/i).last
        output ? "Preparo l'immagine #{File.basename(output)}" : "Preparo un'immagine"
      when /\Aidentify\b/ then "Controllo un'immagine"
      else "Eseguo: #{command.truncate(90)}"
      end
    end
  end
end
