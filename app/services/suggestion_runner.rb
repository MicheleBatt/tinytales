# Claude Code in background per «Proponi post con Claude»: stesso motore e stessi permessi della chat
# (legge sito, app e memoria; scrive solo nella cartella di lavoro; post in sola lettura con bin/assistant),
# ma con istruzioni proprie, più tempo a disposizione e senza riprendere conversazioni precedenti.
class SuggestionRunner < AssistantRunner
  INSTRUCTIONS = Rails.root.join("lib/assistant/proposte.md")
  TIMEOUT = 40.minutes

  def initialize(batch, today: Date.current)
    super(batch)
    @today = today
  end

  def command
    super.tap { |cmd| cmd[cmd.index("--max-turns") + 1] = "200" }
  end

  def system_prompt
    format(INSTRUCTIONS.read, app_root: Rails.root, site_root: SITE_ROOT, outbox: @conversation.outbox,
                              resources: RESOURCES, assistant_bin: ASSISTANT_BIN,
                              max_proposals: PostSuggestionBatch::MAX_PROPOSALS) + "\n\n" + graphics_rules
  end

  # Le regole sulle grafiche sono quelle della chat: le prendiamo da lì, così restano uguali.
  def graphics_rules
    text = format(AssistantRunner::INSTRUCTIONS.read, app_root: Rails.root, site_root: SITE_ROOT,
                  outbox: @conversation.outbox, resources: RESOURCES, assistant_bin: ASSISTANT_BIN)
    text[/^## Grafiche.*?(?=^## )/m].to_s
  end

  def prompt(_message = nil, _attachments = [])
    last = @today + PostSuggestionBatch::HORIZON
    <<~TXT
      [Richiesta]
      Oggi è #{I18n.l(@today, format: :long)}. Esamina il periodo da oggi a #{I18n.l(last, format: :long)}
      e proponi i nuovi post che ritieni opportuni, come descritto nelle istruzioni.

      [Post già presenti nell'app, per data]
      #{existing_posts}
    TXT
  end

  private

  def existing_posts
    Post.order(Arel.sql("publish_at NULLS FIRST"), :id).map do |post|
      date = post.publish_at ? I18n.l(post.publish_at, format: :long) : "senza data"
      "- id #{post.id} · #{PostsController.helpers.status_label(post.status)} · #{date} · #{post.title}"
    end.join("\n").presence || "(nessuno)"
  end

  def remember_session(_session_id) = nil
end
