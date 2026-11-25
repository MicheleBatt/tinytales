require "net/http"
require "json"

module FacebookGraph
  # Chiamate minime alle Graph API di Meta, con un token di accesso.
  # La versione si cambia con FACEBOOK_GRAPH_VERSION; le versioni scadono circa due anni dopo l'uscita.
  class Client
    VERSION = ENV.fetch("FACEBOOK_GRAPH_VERSION", "v26.0")
    HOST = "graph.facebook.com"
    VIDEO_HOST = "graph-video.facebook.com"
    TIMEOUT = 120

    # Facebook accetta al massimo 50 richieste in una batch.
    BATCH_LIMIT = 50

    # Quanto dei limiti di chiamate di Meta è stato usato, secondo l'ultima risposta (nil se non lo dice).
    attr_reader :last_usage

    def initialize(access_token)
      @access_token = access_token
    end

    def get(path, params = {})
      request(Net::HTTP::Get, path, params)
    end

    # Più letture in una sola richiesta HTTP. Ogni lettura conta comunque come una chiamata per i limiti di Meta.
    # paths: indirizzi relativi con i parametri, come "1234_5/insights?metric=x".
    # Restituisce, nello stesso ordine, il corpo di ogni risposta (Hash) oppure un FacebookGraph::Error.
    def batch(paths)
      raise ArgumentError, "al massimo #{BATCH_LIMIT} richieste per batch" if paths.size > BATCH_LIMIT

      requests = paths.map { |path| { method: "GET", relative_url: path } }
      request(Net::HTTP::Post, "", { batch: requests, include_headers: false }).map do |item|
        next Error.new("Facebook non ha risposto a questa richiesta.") if item.nil?

        body = JSON.parse(item["body"].presence || "{}") rescue {}
        if (error = body["error"]) || item["code"] != 200
          error ||= {}
          next Error.new("Facebook: #{error['message'].presence || "errore HTTP #{item['code']}"}",
                         code: error["code"], subcode: error["error_subcode"])
        end
        body
      end
    end

    # files: { "source" => { io:, filename:, content_type: } } per i caricamenti multipart.
    def post(path, params = {}, files: {}, video: false)
      request(Net::HTTP::Post, path, params, files:, host: video ? VIDEO_HOST : HOST)
    end

    def delete(path)
      request(Net::HTTP::Delete, path)
    end

    # La richiesta HTTP pronta da spedire. Pubblico per poterla controllare nei test senza rete.
    # Net::HTTP vuole nomi dei campi come stringhe e valori come stringhe (oggetti e liste in JSON).
    def build_request(klass, path, params = {}, files: {}, host: HOST)
      uri = URI::HTTPS.build(host:, path: "/#{VERSION}/#{path.delete_prefix('/')}")
      fields = params.merge(@access_token ? { access_token: @access_token } : {})
                     .to_h { |key, value| [ key.to_s, value.is_a?(Hash) || value.is_a?(Array) ? value.to_json : value.to_s ] }

      if klass == Net::HTTP::Get || klass == Net::HTTP::Delete
        uri.query = URI.encode_www_form(fields)
        klass.new(uri)
      else
        req = klass.new(uri)
        if files.any?
          form = fields.to_a + files.map { |name, f| [ name.to_s, f[:io], { filename: f[:filename], content_type: f[:content_type] } ] }
          req.set_form(form, "multipart/form-data")
        else
          req.set_form_data(fields)
        end
        req
      end
    end

    private

    def request(klass, path, params = {}, files: {}, host: HOST)
      req = build_request(klass, path, params, files:, host:)
      uri = req.uri

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: TIMEOUT) do |http|
        http.request(req)
      end
      @last_usage = Usage.from_headers(response)
      parse(response)
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      raise Error, "Facebook non risponde (#{e.class.name.demodulize}): controlla la connessione e riprova."
    end

    def parse(response)
      body = JSON.parse(response.body.presence || "{}")
      if body.is_a?(Hash) && (error = body["error"])
        message = error["error_user_msg"].presence || error["message"].presence || "errore sconosciuto"
        raise Error.new("Facebook: #{message}", code: error["code"], subcode: error["error_subcode"])
      end
      raise Error, "Facebook ha risposto con l'errore HTTP #{response.code}." unless response.is_a?(Net::HTTPSuccess)

      body
    rescue JSON::ParserError
      raise Error, "Facebook ha dato una risposta non leggibile (HTTP #{response.code})."
    end
  end
end
