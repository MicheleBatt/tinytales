# Le immagini create dall'assistente nella cartella di lavoro della chat,
# da mostrare in anteprima e da aggiungere al form con «Applica».
class AssistantFilesController < ApplicationController
  ALLOWED = /\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v|webm|txt|md|csv|pdf)\z/i

  def show
    conversation = AssistantConversation.find_by(token: params[:token])
    path = conversation&.outbox_file(params[:name])
    return head(:not_found) unless path && path.basename.to_s.match?(ALLOWED)

    send_file path, disposition: :inline
  end
end
