require "test_helper"

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

  test "letture e cancellazioni mettono i parametri nell'indirizzo" do
    request = FacebookGraph::Client.new("tok").build_request(Net::HTTP::Delete, "1234_5")
    assert_equal "access_token=tok", URI(request.uri).query
  end
end
