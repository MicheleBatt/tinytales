class PostsController < ApplicationController
  SEARCH_FIELDS = %i[title_or_body_or_notes_cont status_eq social_pages_id_eq
                     publish_at_gteq publish_at_lteq notes_present s].freeze

  before_action :promote_due_scheduled, only: %i[index show preview]
  before_action :set_post, only: %i[show preview edit update destroy publish schedule unpublish resync]
  before_action :set_social_pages, only: %i[index new create edit update]
  before_action :set_assistant, only: %i[new create edit update]

  def index
    @q = Post.ransack(search_params)
    @q.sorts = [ "publish_at desc", "id desc" ] if @q.sorts.empty?
    @posts = @q.result(distinct: true).includes(:social_pages, media_attachments: :blob)

    @view = chosen_view
    prepare_calendar if @view == "calendario"
    @counts = Post.group(:status).count
    @next_post = Post.scheduled.where(publish_at: Time.current..).order(:publish_at).first
  end

  def show
  end

  # L'anteprima del post nel popup della vista a calendario (solo il contenuto, senza layout).
  def preview
    render partial: "anteprima", locals: { post: @post, return_to: back_path }
  end

  def new
    # Un post nuovo esce di solito sulla pagina Facebook: la proponiamo già selezionata.
    @post = Post.new(social_pages: @social_pages.where(platform: "facebook"))
  end

  # Ogni post nasce bozza: lo stato si cambia solo con i pulsanti della pagina del post.
  def create
    @post = Post.new(post_params.merge(status: :draft))

    if @post.save
      AssistantConversation.where(token: params[:assistant_token].to_s, post_id: nil).update_all(post_id: @post.id)
      redirect_to @post, notice: "Post creato.", status: :see_other
    else
      discard_media_changes
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  # I file del post arrivano come elenco completo: gli id firmati di quelli da tenere,
  # seguiti dai nuovi caricamenti. Quelli non più elencati vengono tolti.
  # Se il post è già sui social, la modifica viene riportata anche lì.
  def update
    if @post.update(post_params)
      warnings = PostSync.new(@post).update!
      notice = @post.draft? ? "Modifiche salvate." : "Modifiche salvate anche sui social."
      notice = "Modifiche salvate." if warnings.any?
      redirect_to @post, notice:, flash: { warnings: }, status: :see_other
    else
      discard_media_changes
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    warnings = PostSync.new(@post).destroy!
    redirect_to back_path || posts_path, notice: "Post «#{@post.title}» eliminato, anche dai social.", flash: { warnings: }, status: :see_other
  rescue PostSync::Error => error
    redirect_to back_path || @post, alert: "Il post non è stato eliminato. #{error.message}", status: :see_other
  end

  def publish
    sync(notice: "Post pubblicato sui social.") { |s| s.publish! }
  end

  def schedule
    sync(notice: "Post programmato sui social per #{I18n.l(@post.publish_at, format: :long)}.") { |s| s.schedule! }
  end

  def unpublish
    sync(notice: "Post tolto dai social: nell'app è di nuovo una bozza.") { |s| s.unpublish! }
  end

  # Riprova a riportare sui social l'ultima versione del post, dopo un errore.
  def resync
    warnings = PostSync.new(@post).update!
    if warnings.empty?
      redirect_to @post, notice: "Post sincronizzato con i social.", status: :see_other
    else
      redirect_to @post, flash: { warnings: }, status: :see_other
    end
  end

  private

  VIEWS = %w[lista griglia calendario].freeze

  # Lista (predefinita), griglia o calendario. La scelta arriva con ?vista= (icone) e resta in un cookie;
  # tra lista e griglia si passa anche senza ricaricare, e allora il cookie lo scrive il browser.
  def chosen_view
    if VIEWS.include?(params[:vista])
      cookies[:vista_post] = { value: params[:vista], expires: 1.year, same_site: :lax }
      params[:vista]
    else
      VIEWS.include?(cookies[:vista_post]) ? cookies[:vista_post] : "lista"
    end
  end

  # Il mese da mostrare (?mese=AAAA-MM, altrimenti quello corrente), a settimane da lunedì a domenica,
  # con i post già filtrati raggruppati per giorno. Quelli senza data a parte.
  def prepare_calendar
    @month = (Date.strptime(params[:mese].to_s, "%Y-%m") rescue nil) || Date.current.beginning_of_month
    first_day = @month.beginning_of_week(:monday)
    last_day = @month.end_of_month.end_of_week(:monday)
    @calendar_days = (first_day..last_day).to_a
    @calendar_posts = @posts.reorder(:publish_at, :id)
                            .where(publish_at: first_day.in_time_zone.beginning_of_day..last_day.in_time_zone.end_of_day)
                            .group_by { |post| post.publish_at.to_date }
    @undated_posts = @posts.reorder(:id).where(publish_at: nil)
    @month_count = @calendar_posts.select { |day, _| day.month == @month.month }.values.sum(&:size)
  end

  def sync(notice:)
    warnings = yield PostSync.new(@post)
    redirect_to back_path || @post, notice:, flash: { warnings: }, status: :see_other
  rescue PostSync::Error => error
    redirect_to back_path || @post, alert: error.message, status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to back_path || @post, alert: "Il post non è completo: #{error.record.errors.full_messages.to_sentence}.", status: :see_other
  end

  # Dove tornare dopo un'azione lanciata dal popup del calendario: solo l'elenco dei post di questa app.
  def back_path
    path = params[:return_to].to_s
    path if path.match?(%r{\A/(posts)?(\?[^\s]*)?\z})
  end

  def promote_due_scheduled
    Post.promote_due_scheduled!
  end

  # Se il salvataggio non va a buon fine, i file appena scelti non sono stati caricati:
  # la pagina torna a mostrare quelli salvati, e i nuovi vanno riselezionati.
  def discard_media_changes
    @media_discarded = @post.attachment_changes.delete("media").present?
    @post.media_attachments.reset
  end

  def set_post
    @post = Post.includes(:social_pages, publications: :social_page, media_attachments: :blob).find(params[:id])
  end

  def set_social_pages
    @social_pages = SocialPage.by_name
  end

  # La chat dell'assistente: quella del post, oppure una nuova riconosciuta dal suo token.
  def set_assistant
    conversation = @post&.assistant_conversation ||
                   AssistantConversation.find_by(token: params[:assistant_token].to_s, post_id: nil)
    @assistant_token = conversation&.token || SecureRandom.uuid
    @assistant_messages = conversation ? conversation.messages.to_a : []
  end

  # Le pagine social di un post già uscito o programmato non si cambiano dal form:
  # toglierne una vorrebbe dire cancellare prima il post da lì.
  def post_params
    permitted = params.expect(post: [ :title, :body, :publish_at, :notes, social_page_ids: [], media: [] ])
    @post&.persisted? && !@post.draft? ? permitted.except(:social_page_ids) : permitted
  end

  # Il filtro "fino al" arriva come giorno: va incluso tutto quel giorno.
  def search_params
    query = params.fetch(:q, {}).permit(*SEARCH_FIELDS).to_h
    if query["publish_at_lteq"].present?
      day = Date.iso8601(query["publish_at_lteq"]) rescue nil
      day ? query["publish_at_lteq"] = day.in_time_zone.end_of_day : query.delete("publish_at_lteq")
    end
    query.delete("notes_present") unless query["notes_present"] == "1"
    query
  end
end
