# I file allegati dalla persona a un messaggio della chat (nome, tipo, dimensione),
# salvati nella cartella di lavoro della conversazione.
class AddAttachmentsToAssistantMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_messages, :attachments, :jsonb, null: false, default: []
  end
end
