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
      attachments = store_uploads(conversation, uploads)
      stream_reply(conversation, message.presence || "Ti allego questi file.", attachments)
    end
  rescue AssistantConversation::UploadError => error
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

  def stream_reply(conversation, message, attachments)
    conversation.messages.create!(role: "user", content: message, attachments:)

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
    conversation&.messages&.create!(role: "assistant", content: reply) if reply.present?
    response.stream.close
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
