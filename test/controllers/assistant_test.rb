require "test_helper"

class AssistantTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  # Al posto di Claude Code: risponde con una proposta e registra cosa ha ricevuto.
  # Con FakeRunner.creates = { "nome.png" => "contenuto" } scrive anche dei file nella cartella di lavoro.
  class FakeRunner
    cattr_accessor :last
    cattr_accessor :creates, default: {}
    attr_reader :conversation, :form_state, :attachments, :seen

    def initialize(conversation, form_state: {})
      @conversation = conversation
      @form_state = form_state
      self.class.last = self
    end

    def run(message, attachments: [])
      @attachments = attachments
      @seen = @conversation.outbox.children.map { |path| [ path.basename.to_s, path.read ] }.sort.to_h
      creates.each { |name, content| @conversation.outbox.join(name).write(content) }
      yield({ type: "activity", text: "Leggo mensa.html" })
      yield({ type: "delta", text: "Ecco: " })
      yield({ type: "delta", text: "```proposta:titolo\n#{message.upcase}\n```" })
      yield({ type: "done", error: nil })
    end

    def stop; end
  end

  setup do
    @original_runner = AssistantMessagesController.runner_class
    AssistantMessagesController.runner_class = FakeRunner
    @token = SecureRandom.uuid
  end

  teardown do
    AssistantMessagesController.runner_class = @original_runner
    AssistantConversation.find_each { |c| FileUtils.rm_rf(c.outbox) }
  end

  test "le pagine di creazione e modifica hanno la chat, quella del post no" do
    get new_post_path
    assert_select ".con-assistente form.modulo"
    assert_select ".assistente[data-controller=assistant]"
    assert_select "input[type=hidden][name=assistant_token]"

    get edit_post_path(posts(:mensa))
    assert_select ".assistente[data-assistant-post-id-value='#{posts(:mensa).id}']"

    get post_path(posts(:mensa))
    assert_select ".assistente", 0
  end

  test "un messaggio arriva all'assistente con lo stato del form e la risposta torna in streaming" do
    post assistant_messages_path, params: { token: @token, post_id: posts(:mensa).id, message: "titolo nuovo",
                                            form_state: { title: "La nostra mensa" }.to_json }

    assert_response :success
    assert_equal "application/x-ndjson", response.media_type
    events = response.body.lines.map { |line| JSON.parse(line) }
    assert_equal %w[activity delta delta done], events.map { |e| e["type"] }

    assert_equal({ "title" => "La nostra mensa" }, FakeRunner.last.form_state)
    conversation = posts(:mensa).reload.assistant_conversation
    assert_equal [ "user", "assistant" ], conversation.messages.map(&:role)
    assert_equal "Ecco: ```proposta:titolo\nTITOLO NUOVO\n```", conversation.messages.last.content
  end

  test "la conversazione del post si ritrova riaprendo la modifica" do
    post assistant_messages_path, params: { token: @token, post_id: posts(:mensa).id, message: "ciao" }

    get edit_post_path(posts(:mensa))
    assert_select ".msg-user[data-raw='ciao']"
    assert_select ".assistente-intro[hidden]"
  end

  test "la chat di un post nuovo si lega al post quando lo si salva" do
    post assistant_messages_path, params: { token: @token, message: "scrivi il testo" }
    assert_nil AssistantConversation.find_by!(token: @token).post_id

    post posts_path, params: { assistant_token: @token,
                               post: { title: "Nuovo", publish_at: "2026-12-01T20:30", media: [ "" ] } }
    assert_equal Post.order(:id).last, AssistantConversation.find_by!(token: @token).post
  end

  test "un salvataggio fallito mantiene la chat del post nuovo" do
    post assistant_messages_path, params: { token: @token, message: "ciao" }
    post posts_path, params: { assistant_token: @token, post: { title: "", media: [ "" ] } }

    assert_response :unprocessable_content
    assert_select ".assistente[data-assistant-token-value='#{@token}']"
    assert_select ".msg-user[data-raw='ciao']"
  end

  test "gli spunti iniziali dipendono da quanto il post è già pronto" do
    get new_post_path
    assert_select ".spunto", text: /idee di post/
    assert_select ".spunto", text: /partendo dal titolo/, count: 0

    posts(:mensa).update_column(:body, "")
    get edit_post_path(posts(:mensa))
    assert_select ".spunto", text: /partendo dal titolo/

    posts(:mensa).update_column(:body, "Cosa si mangia?")
    get edit_post_path(posts(:mensa))
    assert_select ".spunto", text: /più breve/
    assert_select ".spunto", text: /idee di post/, count: 0
  end

  test "un messaggio vuoto non parte" do
    post assistant_messages_path, params: { token: @token, message: "   " }
    assert_response :unprocessable_content
  end

  test "i file allegati finiscono nella cartella di lavoro e arrivano a Claude" do
    bozza = Rack::Test::UploadedFile.new(StringIO.new("Bozza del post"), "text/plain", original_filename: "bozza post.txt")
    foto = Rack::Test::UploadedFile.new(file_fixture("sample.jpg"), "image/jpeg", original_filename: "foto.jpg")

    post assistant_messages_path, params: { token: @token, message: "Parti da questa bozza", files: [ bozza, foto ] }
    assert_response :success

    conversation = AssistantConversation.find_by!(token: @token)
    assert_equal "Bozza del post", FakeRunner.last.seen["bozza_post.txt"], "durante la risposta Claude li trova nella cartella"
    assert FakeRunner.last.seen.key?("foto.jpg")
    assert_equal %w[bozza_post.txt foto.jpg], FakeRunner.last.attachments.map { |a| a["name"] }
    user_message = conversation.messages.first
    assert_equal %w[testo immagine], user_message.attachments.map { |a| a["kind"] }
    assert_equal "bozza post.txt", user_message.attachments.first["original"]

    assert_equal %w[bozza_post.txt foto.jpg], user_message.files.map { |f| f.filename.to_s }.sort, "salvati in Active Storage"
    assert_equal "Bozza del post", user_message.files.find { |f| f.filename.to_s == "bozza_post.txt" }.download
    assert_empty Dir.glob(AssistantConversation::OUTBOX_ROOT.join(@token, "*")), "a fine risposta la cartella si svuota"

    get assistant_file_path(token: @token, name: "bozza_post.txt")
    assert_response :redirect
    assert_match %r{/rails/active_storage/}, response.location
  end

  test "le immagini create da Claude si salvano sul suo messaggio, senza i file intermedi, e tornano alla risposta dopo" do
    FakeRunner.creates = { "grafica.png" => "PNG-1", "_sfondo.png" => "intermedio", "disegno.sh" => "convert …" }
    post assistant_messages_path, params: { token: @token, message: "Fammi una grafica" }
    conversation = AssistantConversation.find_by!(token: @token)
    reply = conversation.messages.last
    assert_equal "assistant", reply.role
    assert_equal %w[grafica.png], reply.files.map { |f| f.filename.to_s }
    assert_empty Dir.glob(conversation.outbox.join("*"))

    get assistant_file_path(token: @token, name: "grafica.png")
    assert_response :redirect

    # Risposta successiva: Claude ritrova la grafica e la rifà con lo stesso nome; vale la nuova.
    FakeRunner.creates = { "grafica.png" => "PNG-2" }
    post assistant_messages_path, params: { token: @token, message: "Più luminosa" }
    assert_equal "PNG-1", FakeRunner.last.seen["grafica.png"]
    assert_equal "PNG-2", conversation.reload.file_attachment("grafica.png").download

    # Risposta senza cambiamenti: la grafica non viene salvata di nuovo.
    FakeRunner.creates = {}
    assert_no_difference -> { ActiveStorage::Attachment.where(record_type: "AssistantMessage").count } do
      post assistant_messages_path, params: { token: @token, message: "Va bene così" }
    end
    assert_equal "PNG-2", FakeRunner.last.seen["grafica.png"]
  ensure
    FakeRunner.creates = {}
  end

  test "cancellando la conversazione spariscono anche i suoi file" do
    FakeRunner.creates = { "grafica.png" => "PNG" }
    post assistant_messages_path, params: { token: @token, message: "Fammi una grafica" }
    conversation = AssistantConversation.find_by!(token: @token)
    blob = conversation.messages.last.files.first.blob

    perform_enqueued_jobs { conversation.destroy }
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not AssistantConversation::OUTBOX_ROOT.join(@token).exist?
  ensure
    FakeRunner.creates = {}
  end

  test "un allegato con lo stesso nome non sovrascrive quello di prima" do
    2.times do |i|
      file = Rack::Test::UploadedFile.new(StringIO.new("versione #{i}"), "text/plain", original_filename: "bozza.txt")
      post assistant_messages_path, params: { token: @token, message: "ecco", files: [ file ] }
    end
    conversation = AssistantConversation.find_by!(token: @token)
    assert_equal "versione 0", conversation.file_attachment("bozza.txt").download
    assert_equal "versione 1", conversation.file_attachment("bozza-2.txt").download
  end

  test "si può mandare solo un file, senza testo" do
    foto = Rack::Test::UploadedFile.new(file_fixture("sample.jpg"), "image/jpeg", original_filename: "foto.jpg")
    post assistant_messages_path, params: { token: @token, message: "", files: [ foto ] }

    assert_response :success
    assert_equal "Ti allego questi file.", AssistantConversation.find_by!(token: @token).messages.first.content
  end

  test "un tipo di file non accettato blocca il messaggio e non lascia niente" do
    foto = Rack::Test::UploadedFile.new(file_fixture("sample.jpg"), "image/jpeg", original_filename: "foto.jpg")
    word = Rack::Test::UploadedFile.new(StringIO.new("x"), "application/msword", original_filename: "lettera.docx")

    post assistant_messages_path, params: { token: @token, message: "ecco", files: [ foto, word ] }

    assert_response :unprocessable_content
    assert_match "lettera.docx", response.parsed_body["error"]
    assert_match "Word", response.parsed_body["error"]
    conversation = AssistantConversation.find_by(token: @token)
    assert_empty conversation.messages
    assert_empty Dir.children(conversation.outbox)
  end

  test "al massimo 10 file per messaggio" do
    files = 11.times.map { |i| Rack::Test::UploadedFile.new(StringIO.new("x"), "text/plain", original_filename: "f#{i}.txt") }
    post assistant_messages_path, params: { token: @token, message: "ecco", files: }
    assert_response :unprocessable_content
    assert_match "10 file", response.parsed_body["error"]
  end

  test "la cronologia mostra gli allegati dei messaggi" do
    conversation = AssistantConversation.create!(token: @token, post: posts(:mensa))
    conversation.messages.create!(role: "user", content: "ecco la foto",
                                  attachments: [ { "name" => "foto.jpg", "original" => "foto.jpg", "kind" => "immagine", "size" => 10 } ])
    get edit_post_path(posts(:mensa))
    assert_select ".msg-user[data-attachments*='foto.jpg']"
    assert_select "[data-assistant-target=attach]", "📎 Allega"
    assert_select "input[type=file][data-assistant-target=fileInput][accept*='.pdf']"
  end

  test "i file dell'assistente si scaricano solo dalla sua cartella" do
    conversation = AssistantConversation.create!(token: @token)
    FileUtils.cp(file_fixture("sample.jpg"), conversation.outbox.join("grafica.jpg"))
    File.write(conversation.outbox.join("script.sh"), "x")

    get assistant_file_path(token: @token, name: "grafica.jpg")
    assert_response :success
    assert_equal "image/jpeg", response.media_type

    get assistant_file_path(token: @token, name: "script.sh")
    assert_response :not_found

    get "/assistente/file/#{@token}/..%2F..%2F..%2Fconfig%2Fmaster.key"
    assert_response :not_found
  end

  test "un file di una conversazione che non esiste più risponde 404, senza errori" do
    get assistant_file_path(token: SecureRandom.uuid, name: "grafica.jpg")
    assert_response :not_found
  end

  test "i messaggi si mostrano in ordine di orario, anche se inseriti dopo" do
    conversation = AssistantConversation.create!(token: @token, post: posts(:mensa))
    conversation.messages.create!(role: "user", content: "secondo", created_at: 1.minute.ago)
    conversation.messages.create!(role: "user", content: "primo", created_at: 1.hour.ago)
    assert_equal %w[primo secondo], conversation.reload.messages.map(&:content)
  end
end
