require "test_helper"
require "net/http"

# Controlla le richieste HTTP vere, così come partirebbero verso Facebook (senza spedirle).
class FacebookGraphClientTest < ActiveSupport::TestCase
  # Il corpo di una richiesta multipart, scritto come lo scriverebbe Net::HTTP.
  def multipart_body(request)
    socket = StringIO.new
    request.exec(Net::BufferedIO.new(socket), "1.1", request.path)
    socket.string.b
  end

  test "un caricamento di foto è una richiesta multipart con campi e file" do
    client = FacebookGraph::Client.new("tok")
    File.open(file_fixture("sample.jpg")) do |io|
      request = client.build_request(Net::HTTP::Post, "1234/photos", { published: false, temporary: true },
                                     files: { "source" => { io:, filename: "sala.jpg", content_type: "image/jpeg" } })
      body = multipart_body(request)

      assert_equal "/#{FacebookGraph::Client::VERSION}/1234/photos", request.path
      [ "multipart/form-data; boundary=", "name=\"published\"\r\n\r\nfalse", "name=\"temporary\"\r\n\r\ntrue",
        "name=\"access_token\"\r\n\r\ntok", "name=\"source\"; filename=\"sala.jpg\"" ].each do |piece|
        assert_includes body, piece.b
      end
      assert_includes body, file_fixture("sample.jpg").binread
    end
  end

  test "un post con foto allegate manda attached_media in JSON" do
    request = FacebookGraph::Client.new("tok").build_request(Net::HTTP::Post, "1234/feed",
      { message: "Ciao", published: false, scheduled_publish_time: 1_795_000_000, "attached_media[0]": { media_fbid: "99" } })
    form = URI.decode_www_form(request.body).to_h

    assert_equal "Ciao", form["message"]
    assert_equal "false", form["published"]
    assert_equal "1795000000", form["scheduled_publish_time"]
    assert_equal({ "media_fbid" => "99" }, JSON.parse(form["attached_media[0]"]))
  end

  # Una risposta HTTP finta, come la darebbe Net::HTTP.
  def fake_response(body, headers = {}, klass: Net::HTTPOK)
    response = klass.new("1.1", "200", "OK")
    headers.each { |name, value| response[name] = value }
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end

  # Sostituisce per un momento la connessione a Facebook con una risposta preparata.
  def with_response(response)
    sent = []
    original = Net::HTTP.method(:start)
    fake_http = Object.new.tap { |http| http.define_singleton_method(:request) { |req| sent << req; response } }
    Net::HTTP.define_singleton_method(:start) { |*_args, **_opts, &block| block.call(fake_http) }
    yield sent
  ensure
    Net::HTTP.singleton_class.send(:remove_method, :start)
    Net::HTTP.define_singleton_method(:start, original) unless Net::HTTP.respond_to?(:start)
  end

  test "la batch manda tutte le letture in una richiesta e restituisce le risposte nell'ordine" do
    body = [ { "code" => 200, "body" => { data: [ { name: "post_media_view", values: [ { value: 5 } ] } ] }.to_json },
             { "code" => 400, "body" => { error: { message: "troppe chiamate", code: 80001 } }.to_json },
             nil ].to_json
    usage = { "1234" => [ { type: "pages", call_count: 12, total_cputime: 40, total_time: 9, estimated_time_to_regain_access: 3 } ] }

    client = FacebookGraph::Client.new("tok")
    with_response(fake_response(body, { "X-Business-Use-Case-Usage" => usage.to_json })) do |sent|
      first, second, third = client.batch([ "1_1/insights?metric=a", "1_2/insights?metric=a", "1_3/insights?metric=a" ])

      form = URI.decode_www_form(sent.sole.body).to_h
      assert_equal "/#{FacebookGraph::Client::VERSION}/", sent.sole.path
      assert_equal [ { "method" => "GET", "relative_url" => "1_1/insights?metric=a" },
                     { "method" => "GET", "relative_url" => "1_2/insights?metric=a" },
                     { "method" => "GET", "relative_url" => "1_3/insights?metric=a" } ], JSON.parse(form["batch"])
      assert_equal "false", form["include_headers"]

      assert_equal 5, first.dig("data", 0, "values", 0, "value")
      assert_kind_of FacebookGraph::Error, second
      assert_equal [ 80001, "Facebook: troppe chiamate" ], [ second.code, second.message ]
      assert_kind_of FacebookGraph::Error, third
      assert_equal FacebookGraph::Usage.new(percent: 40, regain_minutes: 3), client.last_usage
    end
  end

  test "la batch non accetta più di 50 richieste" do
    assert_raises(ArgumentError) { FacebookGraph::Client.new("tok").batch(Array.new(51) { "x" }) }
  end

  test "l'uso dei limiti si legge anche da X-App-Usage, e manca se Facebook non lo dice" do
    with_response(fake_response({ id: "1" }.to_json, { "X-App-Usage" => { call_count: 77, total_time: 1, total_cputime: 2 }.to_json })) do
      client = FacebookGraph::Client.new("tok")
      client.get("1")
      assert_equal FacebookGraph::Usage.new(percent: 77, regain_minutes: 0), client.last_usage
    end
    with_response(fake_response({ id: "1" }.to_json)) do
      client = FacebookGraph::Client.new("tok")
      client.get("1")
      assert_nil client.last_usage
    end
  end

  test "letture e cancellazioni mettono i parametri nell'indirizzo" do
    request = FacebookGraph::Client.new("tok").build_request(Net::HTTP::Delete, "1234_5")
    assert_equal "access_token=tok", URI(request.uri).query
  end
end
