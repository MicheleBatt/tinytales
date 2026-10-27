require "test_helper"

class AssistantRunnerTest < ActiveSupport::TestCase
  setup do
    @conversation = AssistantConversation.create!(token: SecureRandom.uuid, post: posts(:mensa))
  end

  teardown { FileUtils.rm_rf(@conversation.outbox) }

  test "Claude parte dal sito e ha solo i permessi previsti" do
    cmd = AssistantRunner.new(@conversation).command
    allowed = cmd[(cmd.index("--allowedTools") + 1)...cmd.index("--disallowedTools")]

    assert_equal "-p", cmd[1]
    assert_not_includes allowed, "Read", "la lettura non è libera ovunque"
    assert_includes allowed, "Read(/#{AssistantRunner::SITE_ROOT}/**)"
    assert_includes allowed, "Read(/#{Rails.root}/**)"
    assert_includes allowed, "Edit(/#{@conversation.outbox}/**)"
    assert_includes allowed, "Bash(convert:*)"
    assert_includes allowed, "Bash(#{Rails.root.join('bin/assistant')}:*)"
    assert_not allowed.any? { |rule| rule.start_with?("Write") || rule == "Bash" || rule.include?("git") }
    assert_equal "default", cmd[cmd.index("--permission-mode") + 1]
    assert_not_includes cmd, "--resume"
  end

  test "Claude non eredita impostazioni, connettori, strumenti extra né variabili d'ambiente segrete" do
    runner = AssistantRunner.new(@conversation)
    cmd = runner.command
    assert_equal "", cmd[cmd.index("--setting-sources") + 1], "niente permessi dalle impostazioni del sito o della home"
    assert_includes cmd, "--strict-mcp-config"
    assert_includes cmd, "--disable-slash-commands"
    assert_equal "Read,Glob,Grep,Edit,Write,Bash", cmd[cmd.index("--tools") + 1]
    assert_not_includes cmd, "--dangerously-skip-permissions"

    ENV["SEGRETO_DI_PROVA_API_KEY"] = "x"
    env = runner.claude_env
    assert_not env.key?("SEGRETO_DI_PROVA_API_KEY")
    assert_not env.key?("DATABASE")
    assert env.key?("HOME") && env.key?("PATH")
    assert_equal AssistantRunner::POLICY_ROOT.join(@conversation.outbox.basename.to_s).to_s, env["MAGICK_CONFIGURE_PATH"]
  ensure
    ENV.delete("SEGRETO_DI_PROVA_API_KEY")
    FileUtils.rm_rf(AssistantRunner::POLICY_ROOT.join(@conversation.outbox.basename.to_s))
  end

  test "non legge i segreti dell'app né quello che sta fuori da sito, app e memoria" do
    runner = AssistantRunner.new(@conversation)
    cmd = runner.command
    denied = cmd[(cmd.index("--disallowedTools") + 1)..]

    assert_includes denied, "Read(/#{Rails.root}/config/*.key)"
    assert_includes denied, "Read(/#{Rails.root}/config/credentials*)"
    assert_includes denied, "Read(/#{Rails.root}/.env*)"
    assert_includes denied, "Read(//tmp/**)"
    assert_includes denied, "Read(/#{Rails.root}/log/**)"
    outside = runner.outside_paths
    inside = ->(dir, path) { "#{dir}/".start_with?("#{path}/") } # path è dir o una sua cartella superiore
    readable = [ AssistantRunner::SITE_ROOT, Rails.root ] + (AssistantRunner::MEMORY_DIR.directory? ? [ AssistantRunner::MEMORY_DIR ] : [])
    readable.each { |dir| assert_not outside.any? { |path| inside.(dir, path) }, "#{dir} deve restare leggibile" }
    assert_includes outside, File.join(Dir.home, ".ssh") if File.directory?(File.join(Dir.home, ".ssh"))
  end

  test "ImageMagick legge solo le cartelle previste, niente file come testo, e scrive solo nella cartella di lavoro" do
    dir = AssistantRunner.new(@conversation).imagemagick_policy
    policy = dir.join("policy.xml").read
    assert_includes policy, %(pattern="{TEXT,TXT,URL,HTTP,HTTPS,FTP,EPHEMERAL,MSL}")
    assert_includes policy, %(<policy domain="path" rights="none" pattern="/*" />)
    assert_includes policy, %(rights="read|write" pattern="#{@conversation.outbox}/*")
    assert policy.index(%(pattern="*.key")) > policy.index(%(rights="read" pattern="#{AssistantRunner::SITE_ROOT}/*")), "il divieto viene dopo, e vince"
    assert_includes policy, %(<policy domain="delegate" rights="none" pattern="*" />)
    assert_includes policy, "PS,PS2,PS3,EPS"
    assert_includes policy, %(name="temporary-path" value="#{dir.join('tmp')}")
    assert policy.index(%(pattern="*..*")) > policy.index(%(pattern="#{@conversation.outbox}/*")), "niente fughe con ../"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "riprende la sessione di Claude della conversazione" do
    @conversation.update!(claude_session_id: "abc-123")
    cmd = AssistantRunner.new(@conversation).command
    assert_equal "abc-123", cmd[cmd.index("--resume") + 1]
  end

  test "le istruzioni contengono la cartella di lavoro e il protocollo delle proposte" do
    prompt = AssistantRunner.new(@conversation).system_prompt
    assert_includes prompt, @conversation.outbox.to_s
    assert_includes prompt, "```proposta:testo"
    assert_includes prompt, Rails.root.join("bin/assistant").to_s
  end

  test "il messaggio arriva con lo stato del form" do
    prompt = AssistantRunner.new(@conversation, form_state: { "title" => "La nostra mensa", "body" => "Ciao",
                                                              "media" => [ "a.jpg" ], "new_files" => [ "b.jpg" ] }).prompt("Accorcia")
    assert_includes prompt, "Post: id #{posts(:mensa).id}"
    assert_includes prompt, "Titolo: La nostra mensa"
    assert_includes prompt, "<<<\nCiao\n>>>"
    assert_includes prompt, "File già allegati, in ordine: a.jpg"
    assert_includes prompt, "Nuovi file scelti, da caricare: b.jpg"
    assert prompt.end_with?("[Messaggio]\nAccorcia\n")
  end

  test "gli allegati arrivano a Claude con il percorso completo" do
    attachments = [ { "name" => "bozza.txt", "original" => "bozza.txt", "kind" => "testo", "size" => 2048 },
                    { "name" => "foto_1.jpg", "original" => "foto 1.jpg", "kind" => "immagine", "size" => 3_500_000 } ]
    prompt = AssistantRunner.new(@conversation).prompt("Usa la bozza", attachments)

    assert_includes prompt, "[File allegati dalla persona a questo messaggio, nella cartella di lavoro]"
    assert_includes prompt, "#{@conversation.outbox.join('bozza.txt')} · testo · 2 KB"
    assert_includes prompt, "#{@conversation.outbox.join('foto_1.jpg')} · immagine · 3,3 MB (originale: foto 1.jpg)"
    assert prompt.index("[File allegati") < prompt.index("[Messaggio]")
  end

  test "senza allegati il messaggio non ha la sezione dei file" do
    assert_not_includes AssistantRunner.new(@conversation).prompt("ciao"), "[File allegati"
  end

  test "il parser trasforma lo stream di Claude Code in eventi per il browser" do
    parser = AssistantRunner::EventParser.new
    lines = [
      { type: "system", subtype: "init", session_id: "s-1" },
      { type: "stream_event", event: { type: "content_block_start", content_block: { type: "text" } } },
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Ciao" } } },
      { type: "assistant", message: { content: [ { type: "tool_use", name: "Bash", input: { command: "convert a.jpg b.jpg" } } ] } },
      { type: "stream_event", event: { type: "content_block_start", content_block: { type: "text" } } },
      { type: "stream_event", event: { type: "content_block_delta", delta: { type: "text_delta", text: "Fatto" } } },
      { type: "result", subtype: "success", is_error: false, result: "Fatto" }
    ]
    events = lines.flat_map { |line| parser.parse(line.to_json) }

    assert_equal [ { type: "session", session_id: "s-1" },
                   { type: "delta", text: "Ciao" },
                   { type: "activity", text: "Preparo l'immagine b.jpg" },
                   { type: "delta", text: "\n\n" },
                   { type: "delta", text: "Fatto" },
                   { type: "done", error: nil } ], events
    assert parser.finished?
    assert_empty parser.parse("non è json")
  end

  test "i comandi frequenti vengono detti a parole" do
    parser = AssistantRunner::EventParser.new
    say = ->(command) { parser.parse({ type: "assistant", message: { content: [ { type: "tool_use", name: "Bash", input: { command: } } ] } }.to_json).first[:text] }
    assert_equal "Leggo il post 16", say.("#{AssistantRunner::ASSISTANT_BIN} post 16")
    assert_equal "Guardo l'elenco dei post", say.("#{AssistantRunner::ASSISTANT_BIN} posts")
    assert_equal "Controllo un'immagine", say.("identify /tmp/x.png")
    assert_equal "Eseguo: ls", say.("ls")
  end

  test "outbox_file accetta solo file della cartella di lavoro" do
    File.write(@conversation.outbox.join("ok.png"), "x")
    assert_equal @conversation.outbox.join("ok.png"), @conversation.outbox_file("ok.png")
    assert_equal @conversation.outbox.join("ok.png"), @conversation.outbox_file("/altro/percorso/ok.png")
    assert_nil @conversation.outbox_file("../../../config/master.key")
    assert_nil @conversation.outbox_file("manca.png")
  end
end
