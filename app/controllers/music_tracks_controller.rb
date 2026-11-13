# La musicoteca: i brani che Claude può usare come sottofondo dei video montati nella chat.
class MusicTracksController < ApplicationController
  SEARCH_FIELDS = %i[title_or_author_or_instruments_or_suitable_for_or_notes_or_source_tags_cont
                     with_mood tempo_eq voice state s].freeze
  SORTS = { "title asc" => "Titolo A → Z", "title desc" => "Titolo Z → A", "created_at desc" => "Aggiunti di recente",
            "duration asc" => "Più brevi prima", "duration desc" => "Più lunghi prima" }.freeze
  PER_PAGE = 20

  before_action :set_track, only: %i[edit update destroy]

  def index
    @q = MusicTrack.ransack(search_params)
    @q.sorts = [ "title asc" ] if @q.sorts.empty?
    tracks = @q.result.order(:id)

    @total = tracks.count
    @pages = [ (@total.to_f / PER_PAGE).ceil, 1 ].max
    @page = params[:page].to_i.clamp(1, @pages)
    @tracks = tracks.with_attached_audio.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    @library_empty = !MusicTrack.exists?
  end

  def new
    @track = MusicTrack.new
  end

  def create
    @track = MusicTrack.new(track_params)
    if @track.save
      redirect_to music_tracks_path, notice: "Brano «#{@track.title}» aggiunto alla musicoteca.", status: :see_other
    else
      discard_audio_change
      render :new, status: :unprocessable_content
    end
  end

  def edit
  end

  def update
    if @track.update(track_params)
      redirect_to music_tracks_path, notice: "Brano «#{@track.title}» aggiornato.", status: :see_other
    else
      discard_audio_change
      render :edit, status: :unprocessable_content
    end
  end

  # Claude propone la scheda dal file (appena scelto, oppure quello già salvato), dal link e dai tag.
  # Risponde con i campi da mettere nel form: non salva niente.
  def autofill
    upload = params[:audio].presence
    track = MusicTrack.find_by(id: params[:track_id]) if params[:track_id].present?

    if upload.respond_to?(:tempfile)
      extension = File.extname(upload.original_filename.to_s).downcase
      return autofill_error("Il file dev'essere MP3, M4A, WAV o OGG.") unless MusicTrack::FORMATS.key?(extension)
      return autofill_error("Il file è troppo grande: il massimo è 30 MB.") if upload.size > MusicTrack::MAX_SIZE

      render json: { fields: autofill_fields(upload.tempfile.path, extension, upload.original_filename) }
    elsif track&.audio&.attached?
      fields = track.audio.blob.open do |file|
        autofill_fields(file.path, track.audio_extension, track.audio.filename.to_s)
      end
      render json: { fields: }
    else
      autofill_error("Scegli prima il file del brano: Claude lo usa per compilare la scheda.")
    end
  rescue MusicAutofill::Error => e
    autofill_error(e.message, status: :bad_gateway)
  end

  def destroy
    @track.destroy!
    redirect_to music_tracks_path, notice: "Brano «#{@track.title}» eliminato dalla musicoteca.", status: :see_other
  end

  private

  def set_track
    @track = MusicTrack.find(params[:id])
  end

  # Solo i filtri previsti, e un ordine fra quelli dell'elenco.
  def search_params
    query = params.fetch(:q, {}).permit(*SEARCH_FIELDS).to_h
    query.delete("s") unless SORTS.key?(query["s"])
    query
  end

  def autofill_fields(path, extension, filename)
    MusicAutofill.new(path:, extension:, filename:, source_url: params[:source_url], source_tags: params[:source_tags]).call
  end

  def autofill_error(message, status: :unprocessable_content)
    render json: { error: message }, status:
  end

  # Senza un file nuovo, il campo vuoto non deve togliere quello che c'è già.
  def track_params
    params.expect(music_track: [ :title, :author, :source_url, :license, :tempo, :instruments, :vocals,
                                 :suitable_for, :notes, :enabled, :audio, :source_tags, moods: [] ])
          .tap { |permitted| permitted.delete(:audio) if permitted[:audio].blank? }
  end

  # Un file scelto in un form non valido non resta: va scelto di nuovo (come per i post).
  def discard_audio_change
    @audio_discarded = @track.attachment_changes.delete("audio").present?
    @track.association(:audio_attachment).reset
    @track.duration = @track.duration_was
  end
end
