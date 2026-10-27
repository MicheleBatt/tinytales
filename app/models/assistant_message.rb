class AssistantMessage < ApplicationRecord
  belongs_to :conversation, class_name: "AssistantConversation", foreign_key: :assistant_conversation_id, touch: true

  # I file del messaggio: per la persona, gli allegati che ha mandato; per Claude, le immagini che ha creato.
  # Il file vero sta in Active Storage (storage/); durante una risposta Claude li ritrova nella cartella di lavoro.
  has_many_attached :files

  validates :role, inclusion: { in: %w[user assistant] }
end
