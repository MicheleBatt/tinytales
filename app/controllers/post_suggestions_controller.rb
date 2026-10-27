# «Proponi post con Claude» dall'elenco dei post.
#   POST   /proposte          avvia Claude in background e trasmette, una riga JSON per evento:
#                             { type: "activity" | "status", text: }, { type: "proposal", proposal: },
#                             { type: "rejected", text: }, { type: "done", summary:, error: }
#   POST   /proposte/:token/approva   crea come bozze le proposte tenute
#   DELETE /proposte/:token            annulla tutto: cancella proposte e file
#   GET    /proposte/:token/file/:name un file di una proposta, per l'anteprima
class PostSuggestionsController < ApplicationController
  include ActionController::Live

  # Nei test si sostituisce con un finto, per non lanciare Claude Code.
  cattr_accessor :runner_class, default: SuggestionRunner

  before_action :set_batch, except: :create

  def create
    batch = PostSuggestionBatch.find(params[:token])
    if batch
      stream_proposals(batch)
    else
      render json: { error: "Sessione non valida." }, status: :unprocessable_content
    end
  end

  def approve
    posts = @batch.approve!(params[:ids])
    flash[:notice] = case posts.size
    when 0 then "Nessuna bozza creata."
    when 1 then "Creata 1 bozza proposta da Claude: «#{posts.first.title}»."
    else "Create #{posts.size} bozze proposte da Claude."
    end
    render json: { created: posts.size, redirect: posts_path }
  rescue ActiveRecord::RecordInvalid => error
    render json: { error: "Non sono riuscito a creare le bozze: #{error.record.errors.full_messages.to_sentence}." },
           status: :unprocessable_content
  end

  def destroy
    @batch.discard!
    head :no_content
  end

  def file
    path = @batch.file(params[:name])
    path ? send_file(path, disposition: :inline) : head(:not_found)
  end

  private

  def stream_proposals(batch)
    response.headers["Content-Type"] = "application/x-ndjson"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["Last-Modified"] = Time.now.httpdate # evita che Rack::ETag trattenga lo stream

    extractor = ProposalExtractor.new
    last_line = nil
    runner = runner_class.new(batch)
    runner.run(nil) do |event|
      case event[:type]
      when "delta"
        result = extractor.push(event[:text])
        result[:lines].each { |line| last_line = line; send_event(type: "status", text: line.truncate(160)) }
      when "done"
        import_proposals(batch) # ultimo controllo della cartella, per non perdere niente
        extractor.finish.each { |line| last_line = line }
        send_event(type: "done", summary: last_line, error: event[:error])
      else
        send_event(event)
      end
      import_proposals(batch) unless event[:type] == "done"
    end
  rescue ActionController::Live::ClientDisconnected, IOError
    runner&.stop
  rescue StandardError => error
    runner&.stop
    Rails.logger.error("Proposte di Claude: #{error.class}: #{error.message}")
    send_event(type: "done", summary: nil, error: "errore interno dell'app (#{error.class})")
  ensure
    response.stream.close
  end

  def set_batch
    @batch = PostSuggestionBatch.find(params[:token]) or head(:not_found)
  end

  # Le proposte che Claude ha salvato come file dall'ultimo controllo.
  def import_proposals(batch)
    batch.import_pending.each do |result|
      if result.is_a?(Hash)
        send_event(type: "proposal", proposal: preview(batch, result))
      else
        send_event(type: "rejected", text: "Proposta scartata: #{result}.")
      end
    end
  end

  # Quello che serve all'anteprima compatta nella finestra.
  def preview(batch, proposal)
    time = Time.zone.parse(proposal["publish_at"])
    proposal.slice("id", "title", "body", "notes", "reason").merge(
      "date" => helpers.l(time, format: :short),
      "when" => helpers.days_label(time),
      "files" => proposal["files"].map do |name|
        { "url" => post_suggestion_file_path(batch.token, name), "name" => name,
          "video" => name.match?(/\.(mp4|mov|m4v|webm)\z/i) }
      end
    )
  end

  def send_event(event)
    response.stream.write("#{event.to_json}\n")
  end
end
