# Chi legge davvero le statistiche dei post su una pagina social. Un lettore per piattaforma,
# come per la pubblicazione (SocialPublishers): ognuno traduce i nomi delle sue metriche in views e reach.
module SocialMetrics
  # I totali di una pubblicazione dal momento in cui è uscita.
  Reading = Data.define(:views, :reach)

  # L'esito di una lettura:
  # - readings: { publication_id => Reading } per le pubblicazioni lette;
  # - usage: quanto dei limiti di chiamate è stato usato (FacebookGraph::Usage o nil);
  # - rate_limited: il social ha risposto che le chiamate sono troppe;
  # - errors: i problemi incontrati, da scrivere nel log.
  Result = Data.define(:readings, :usage, :rate_limited, :errors)

  # nil se per quella piattaforma la lettura non c'è ancora.
  def self.for(page)
    case page.platform
    when "facebook" then Facebook.new(page)
    end
  end
end
