# Tiene allineati un post dell'app e le sue copie sulle pagine social.
#
# - publish! e schedule! creano il post su ogni pagina e solo dopo cambiano lo stato;
#   se una pagina rifiuta, quelle già fatte vengono annullate e il post resta bozza.
# - update! riporta sui social le modifiche di un post programmato o pubblicato.
# - unpublish! e destroy! tolgono il post dai social; il primo lo tiene come bozza, il secondo lo cancella.
#
# Ogni metodo restituisce gli avvisi da mostrare (array di stringhe) oppure solleva PostSync::Error.
class PostSync
  class Error < StandardError; end

  NOT_LINKED = "non risulta collegato a un post su Facebook (forse era stato pubblicato a mano)"

  attr_reader :post

  def initialize(post, now: Time.current)
    @post = post
    @now = now
  end

  def publish!
    ensure_transition!(post.publishable?(@now), "Si può pubblicare solo una bozza.")
    post.validate!
    create_everywhere(:publish)
    post.publish!(@now)
    []
  end

  def schedule!
    ensure_transition!(post.schedulable?(@now), "Per programmare il post scegli una data di pubblicazione nel futuro.")
    post.validate!
    create_everywhere(:schedule)
    post.schedule!(@now)
    []
  end

  # Gli errori non bloccano: la modifica è già salvata nell'app, e resta segnata da riprovare.
  def update!
    return [] if post.draft?

    publications.flat_map do |publication|
      next [ "#{publication.social_page.name}: #{NOT_LINKED}, quindi la modifica vale solo qui." ] unless publication.on_social?

      result = publisher_for(publication).update(publication, post, now: @now)
      publication.record_result!(result, post, now: @now)
      result.warnings.map { |w| "#{publication.social_page.name}: #{w}" }
    rescue SocialPublishers::PublishError => error
      publication.update!(sync_error: error.message)
      [ "#{publication.social_page.name}: la modifica è salvata qui ma non sul social. #{error.message}" ]
    end
  end

  def unpublish!
    ensure_transition!(post.published?, "Si può spubblicare solo un post pubblicato.")
    warnings = remove_everywhere
    post.unpublish!
    warnings
  end

  def destroy!
    warnings = remove_everywhere
    post.destroy!
    warnings
  end

  private

  def publications
    post.publications.includes(:social_page).order(:id)
  end

  def publisher_for(publication)
    SocialPublishers.for(publication.social_page)
  end

  def ensure_transition!(allowed, message)
    raise Error, message unless allowed
  end

  def create_everywhere(action)
    list = publications.to_a
    raise Error, "Il post non ha nessuna pagina social: sceglila con «Modifica»." if list.empty?

    done = []
    list.each do |publication|
      result = publisher_for(publication).public_send(action, post, now: @now)
      publication.record_result!(result, post, now: @now)
      done << publication
    rescue SocialPublishers::PublishError => error
      publication.update!(sync_error: error.message)
      undo(done)
      raise Error, "#{publication.social_page.name}: #{error.message}"
    end
  end

  def undo(publications)
    publications.each do |publication|
      publisher_for(publication).remove(publication)
      publication.clear_remote!
    rescue SocialPublishers::PublishError
      # Resta segnato con il suo id: si potrà togliere a mano.
    end
  end

  # Se una pagina non riesce a togliere il post, ci si ferma: meglio un post ancora visibile
  # che un post sparito dall'app ma rimasto online.
  def remove_everywhere
    publications.filter_map do |publication|
      unless publication.on_social?
        next "#{publication.social_page.name}: #{NOT_LINKED}. Se è ancora online, toglilo da Facebook a mano."
      end

      publisher_for(publication).remove(publication)
      publication.clear_remote!
      nil
    rescue SocialPublishers::PublishError => error
      publication.update!(sync_error: error.message)
      raise Error, "#{publication.social_page.name}: non è stato possibile togliere il post. #{error.message}"
    end
  end
end
