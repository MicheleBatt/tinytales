# Le chat con l'assistente (Claude Code) dalla pagina di un post.
# Una conversazione nasce anche prima che il post esista (pagina «Nuovo post»):
# la riconosce il token, e viene legata al post quando questo si salva.
class CreateAssistantConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_conversations do |t|
      t.references :post, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :token, null: false
      t.string :claude_session_id

      t.timestamps
    end
    add_index :assistant_conversations, :token, unique: true

    create_table :assistant_messages do |t|
      t.references :assistant_conversation, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false
      t.text :content, null: false, default: ""

      t.timestamps
    end
    add_check_constraint :assistant_messages, "role IN ('user', 'assistant')", name: "assistant_messages_role_valid"
  end
end
