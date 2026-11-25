module FacebookGraph
  # Quanto dei limiti di chiamate di Meta è stato usato, come lo dicono le intestazioni di una risposta.
  #
  # - X-Business-Use-Case-Usage (chiamate con il token di una pagina):
  #   {"<id>": [{"type": "pages", "call_count": 1, "total_cputime": 1, "total_time": 1,
  #              "estimated_time_to_regain_access": 0}]}
  # - X-App-Usage (chiamate con il token dell'app o di un utente): {"call_count": 1, "total_cputime": 1, "total_time": 1}
  #
  # percent è il valore più alto fra tutti, da 0 a 100; regain_minutes i minuti di attesa che Meta stima se si è oltre.
  Usage = Data.define(:percent, :regain_minutes) do
    def self.from_headers(response)
      entries = []
      if (buc = parse(response["x-business-use-case-usage"])).is_a?(Hash)
        entries.concat(buc.values.flatten.select { |entry| entry.is_a?(Hash) })
      end
      entries << parse(response["x-app-usage"]) if parse(response["x-app-usage"]).is_a?(Hash)
      return if entries.empty?

      new(percent: entries.flat_map { |entry| entry.values_at("call_count", "total_cputime", "total_time") }.map(&:to_i).max,
          regain_minutes: entries.map { |entry| entry["estimated_time_to_regain_access"].to_i }.max)
    end

    def self.parse(value)
      JSON.parse(value) if value.present?
    rescue JSON::ParserError
      nil
    end
  end
end
