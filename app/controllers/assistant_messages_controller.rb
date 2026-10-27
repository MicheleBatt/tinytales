# La chat con l'assistente: riceve un messaggio (con eventuali file allegati) e restituisce
# la risposta di Claude Code un pezzo alla volta, una riga JSON per evento (application/x-ndjson).
class AssistantMessagesController < ApplicationController
  include ActionController::Live

  # Nei test si sostituisce con un finto, per non lanciare Claude Code.
  cattr_accessor :runner_class, default: AssistantRunner

  def create
    message = params[:message].to_s.strip
    uploads = Array(params[:files]).select { |file| file.respond_to?(:original_filename) }

    if message.blank? && uploads.empty?
      render json: { error: "Scrivi un messaggio o allega un file." }, status: :unprocessable_content
    elsif uploads.size > AssistantConversation::MAX_UPLOADS
      render json: { error: "Si possono allegare al massimo #{AssistantConversation::MAX_UPLOADS} file per messaggio." },
             status: :unprocessable_content
    else
      conversation = find_conversation
      known = conversation.prepare_outbox! # i file già salvati della chat, per Claude
      attachments = store_uploads(conversation, uploads)
      stream_reply(conversation, message.presence || "Ti allego questi file.", attachments, known)
    end
  rescue AssistantConversation::UploadError => error
    conversation&.clear_outbox!
    render json: { error: error.message }, status: :unprocessable_content
  end

  private

  # Tutti o nessuno: se un file non va bene, quelli già salvati vengono tolti.
  def store_uploads(conversation, uploads)
    stored = []
    uploads.each { |upload| stored << conversation.store_upload(upload) }
    stored
  rescue AssistantConversation::UploadError
    stored.each { |attachment| conversation.outbox.join(attachment["name"]).delete }
    raise
  end

  def stream_reply(conversation, message, attachments, known)
    user_message = conversation.messages.create!(role: "user", content: message, attachments:)
    # Gli allegati restano nella cartella di lavoro per Claude, e si salvano sul messaggio della persona.
    attachments.each do |attachment|
      path = conversation.outbox.join(attachment["name"])
      path.open { |io| user_message.files.attach(io:, filename: attachment["name"], content_type: Marcel::MimeType.for(path)) }
      known[attachment["name"]] = Digest::MD5.file(path).base64digest
    end

    response.headers["Content-Type"] = "application/x-ndjson"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["Last-Modified"] = Time.now.httpdate # evita che Rack::ETag trattenga lo stream

    reply = +""
    runner = runner_class.new(conversation, form_state: form_state)
    runner.run(message, attachments:) do |event|
      reply << event[:text] if event[:type] == "delta"
      response.stream.write("#{event.to_json}\n")
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    runner&.stop
    reply << "\n\n_(risposta interrotta)_" if reply.present?
  ensure
    save_reply(conversation, reply, known) if conversation
    response.stream.close
  end

  # La risposta di Claude, con le immagini nuove o modificate nella cartella di lavoro; poi la cartella si svuota.
  def save_reply(conversation, reply, known)
    message = conversation.messages.new(role: "assistant", content: reply.presence || "_(nessuna risposta)_")
    if reply.present? || conversation.outbox.children.any?
      message.save!
      conversation.collect_outbox!(message, known || {})
      message.destroy if reply.blank? && message.files.reload.none? # niente da conservare
    end
  ensure
    conversation.clear_outbox!
  end

  # La conversazione si riconosce dal token; per un post salvato si lega al post.
  def find_conversation
    post = Post.find_by(id: params[:post_id]) if params[:post_id].present?
    conversation = post&.assistant_conversation ||
                   AssistantConversation.find_or_create_by!(token: params.require(:token))
    conversation.update!(post:) if post && conversation.post_id.nil?
    conversation
  end

  def form_state
    JSON.parse(params[:form_state].presence || "{}")
  rescue JSON::ParserError
    {}
  end
end
