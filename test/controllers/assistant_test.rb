require "test_helper"

class AssistantTest < ActionDispatch::IntegrationTest
  # Al posto di Claude Code: risponde con una proposta e registra cosa ha ricevuto.
  class FakeRunner
    cattr_accessor :last
    attr_reader :conversation, :form_state, :attachments

    def initialize(conversation, form_state: {})
      @conversation = conversation
      @form_state = form_state
      self.class.last = self
    end

    def run(message, attachments: [])
      @attachments = attachments
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
    assert_equal "Bozza del post", conversation.outbox.join("bozza_post.txt").read
    assert conversation.outbox.join("foto.jpg").file?
    assert_equal %w[bozza_post.txt foto.jpg], FakeRunner.last.attachments.map { |a| a["name"] }
    assert_equal %w[testo immagine], conversation.messages.first.attachments.map { |a| a["kind"] }
    assert_equal "bozza post.txt", conversation.messages.first.attachments.first["original"]

    get assistant_file_path(token: @token, name: "bozza_post.txt")
    assert_response :success
  end

  test "un allegato con lo stesso nome non sovrascrive quello di prima" do
    2.times do |i|
      file = Rack::Test::UploadedFile.new(StringIO.new("versione #{i}"), "text/plain", original_filename: "bozza.txt")
      post assistant_messages_path, params: { token: @token, message: "ecco", files: [ file ] }
    end
    outbox = AssistantConversation.find_by!(token: @token).outbox
    assert_equal "versione 0", outbox.join("bozza.txt").read
    assert_equal "versione 1", outbox.join("bozza-2.txt").read
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
