# I file di una chat con Claude (le sue immagini e gli allegati della persona), da mostrare in anteprima
# e da aggiungere al form con «Applica». Si trovano per nome dentro la conversazione:
# durante una risposta stanno ancora nella cartella di lavoro, dopo sono in Active Storage.
class AssistantFilesController < ApplicationController
  ALLOWED = /\.(jpe?g|png|gif|webp|heic|heif|mp4|mov|m4v|webm|txt|md|csv|pdf)\z/i

  def show
    conversation = AssistantConversation.find_by(token: params[:token])
    return head(:not_found) unless conversation && params[:name].to_s.match?(ALLOWED)

    if (path = conversation.outbox_file(params[:name]))
      send_file path, disposition: :inline
    elsif (attachment = conversation.file_attachment(params[:name]))
      redirect_to rails_blob_path(attachment, disposition: "inline"), allow_other_host: false
    else
      head :not_found
    end
  end
end
