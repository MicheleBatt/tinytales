class AssistantMessage < ApplicationRecord
  belongs_to :conversation, class_name: "AssistantConversation", foreign_key: :assistant_conversation_id, touch: true

  validates :role, inclusion: { in: %w[user assistant] }
end
