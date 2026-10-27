# Al posto delle Graph API nei test: registra le chiamate e risponde come Facebook.
class FakeFacebookClient
  Call = Data.define(:method, :path, :params, :files, :video)

  attr_reader :calls

  def initialize
    @calls = []
    @counter = 0
    @failures = []
  end

  # Fa fallire le chiamate che corrispondono: fail_on(:post, %r{/feed\z}, "Errore finto").
  def fail_on(method, path_pattern, message = "Errore di prova", code: 1, subcode: nil)
    @failures << [ method, path_pattern, FacebookGraph::Error.new("Facebook: #{message}", code:, subcode:) ]
  end

  def get(path, params = {})
    record(:get, path, params)
    {}
  end

  def post(path, params = {}, files: {}, video: false)
    record(:post, path, params, files.transform_values { |f| f[:filename] }, video)
    case path
    when %r{/photos\z} then { "id" => "photo_#{next_id}" }
    when %r{/feed\z} then { "id" => "1234_#{next_id}" }
    when %r{/videos\z} then { "id" => "video_#{next_id}" }
    else { "success" => true }
    end
  end

  def delete(path)
    record(:delete, path)
    { "success" => true }
  end

  def paths(method = nil)
    calls.select { |c| method.nil? || c.method == method }.map(&:path)
  end

  private

  def record(method, path, params = {}, files = {}, video = false)
    @calls << Call.new(method:, path:, params:, files:, video:)
    failure = @failures.find { |m, pattern, _| m == method && path.match?(pattern) }
    raise failure.last if failure
  end

  def next_id = (@counter += 1)
end
