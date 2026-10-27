# Chi pubblica davvero un post su una pagina social. Un publisher per piattaforma.
module SocialPublishers
  # Un problema da mostrare all'utente così com'è.
  class PublishError < StandardError; end

  # Cosa è stato creato sul social: l'id del post, il tipo e gli id delle foto caricate.
  Result = Data.define(:remote_id, :remote_kind, :remote_media_ids, :warnings) do
    def initialize(remote_id:, remote_kind:, remote_media_ids: [], warnings: [])
      super
    end
  end

  def self.for(page)
    case page.platform
    when "facebook" then Facebook.new(page)
    else raise PublishError, "La pubblicazione su #{page.platform_label} non è ancora disponibile."
    end
  end
end
