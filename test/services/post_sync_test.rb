require "test_helper"

class PostSyncTest < ActiveSupport::TestCase
  NOW = Time.zone.parse("2026-11-01 10:00")

  def attach(post, *names, content_type: "image/jpeg")
    names.each do |name|
      post.media.attach(io: file_fixture("sample.jpg").open, filename: name, content_type:)
    end
    post.reload
  end

  test "un post con più foto: le carica non pubblicate e le allega al post, nell'ordine" do
    post = attach(posts(:mensa), "1_sala.jpg", "2_menu.jpg")
    PostSync.new(post, now: NOW).schedule!

    photos = @facebook.calls.select { |c| c.path == "1234/photos" }
    assert_equal [ { "source" => "1_sala.jpg" }, { "source" => "2_menu.jpg" } ], photos.map(&:files)
    assert photos.all? { |c| c.params[:published] == false && c.params[:temporary] == true }

    feed = @facebook.calls.find { |c| c.path == "1234/feed" }
    assert_equal({ media_fbid: "photo_1" }, feed.params[:"attached_media[0]"])
    assert_equal({ media_fbid: "photo_2" }, feed.params[:"attached_media[1]"])
    assert_equal post.body, feed.params[:message]

    publication = publications(:mensa_facebook).reload
    assert_equal %w[photo_1 photo_2], publication.remote_media_ids
    assert_equal post.ordered_media.map(&:blob_id), publication.synced_media_order
  end

  test "un post con un video lo carica sull'host dei video" do
    post = posts(:mensa)
    post.media.attach(io: file_fixture("sample.jpg").open, filename: "clip.mp4", content_type: "video/mp4", identify: false)
    PostSync.new(post.reload, now: NOW).schedule!

    call = @facebook.calls.find { |c| c.path == "1234/videos" }
    assert call.video
    assert_equal post.body, call.params[:description]
    assert_equal "video", publications(:mensa_facebook).reload.remote_kind
  end

  test "foto e video insieme non si possono pubblicare su Facebook" do
    post = attach(posts(:mensa), "foto.jpg")
    post.media.attach(io: file_fixture("sample.jpg").open, filename: "clip.mp4", content_type: "video/mp4", identify: false)

    error = assert_raises(PostSync::Error) { PostSync.new(post.reload, now: NOW).schedule! }
    assert_match "più foto oppure un solo video", error.message
    assert post.reload.draft?
    assert_empty @facebook.calls
  end

  test "se il post fallisce dopo aver caricato le foto, le foto vengono tolte" do
    post = attach(posts(:mensa), "foto.jpg")
    @facebook.fail_on(:post, %r{/feed\z})

    assert_raises(PostSync::Error) { PostSync.new(post, now: NOW).schedule! }
    assert_equal [ "photo_1" ], @facebook.paths(:delete)
    assert posts(:mensa).reload.draft?
  end

  test "non programma oltre i 30 giorni" do
    posts(:mensa).update_column(:publish_at, NOW + 31.days)
    error = assert_raises(PostSync::Error) { PostSync.new(posts(:mensa), now: NOW).schedule! }
    assert_match "30 giorni", error.message
  end

  test "un post senza pagine social non si pubblica" do
    posts(:mensa).publications.destroy_all
    error = assert_raises(PostSync::Error) { PostSync.new(posts(:mensa).reload, now: NOW).schedule! }
    assert_match "nessuna pagina social", error.message
  end

  test "la modifica di un post programmato lo ricrea e poi toglie il vecchio" do
    post = posts(:promemoria)
    post.update!(body: "Nuovo testo")
    warnings = PostSync.new(post, now: NOW).update!

    assert_empty warnings
    assert_equal [ [ :post, "1234/feed" ], [ :delete, "1234_888" ] ], @facebook.calls.map { |c| [ c.method, c.path ] }
    assert_not_equal "1234_888", publications(:promemoria_facebook).reload.remote_id
  end

  test "se il vecchio post programmato non si toglie, avvisa che uscirebbe due volte" do
    @facebook.fail_on(:delete, /1234_888/)
    warnings = PostSync.new(posts(:promemoria), now: NOW).update!
    assert_match "uscirà due volte", warnings.first
  end

  test "la modifica di un post pubblicato aggiorna il testo e avvisa se sono cambiati i file" do
    post = attach(posts(:open_day), "nuova.jpg")
    warnings = PostSync.new(post, now: NOW).update!

    assert_equal [ [ :post, "1234_999" ] ], @facebook.calls.map { |c| [ c.method, c.path ] }
    assert_match "non si possono cambiare", warnings.first
  end

  test "un errore durante la modifica resta segnato sulla pubblicazione" do
    @facebook.fail_on(:post, /1234_999/, "Permesso mancante")
    warnings = PostSync.new(posts(:open_day), now: NOW).update!

    assert_match "salvata qui ma non sul social", warnings.first
    assert_match "Permesso mancante", publications(:open_day_facebook).reload.sync_error
  end

  test "le bozze non vengono sincronizzate" do
    assert_empty PostSync.new(posts(:mensa), now: NOW).update!
    assert_empty @facebook.calls
  end

  test "un post già cancellato da Facebook si spubblica lo stesso" do
    @facebook.fail_on(:delete, /1234_999/, "Object does not exist", code: 100, subcode: 33)
    PostSync.new(posts(:open_day), now: NOW).unpublish!
    assert posts(:open_day).reload.draft?
  end
end
