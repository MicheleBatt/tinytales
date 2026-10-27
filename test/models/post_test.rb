require "test_helper"

class PostTest < ActiveSupport::TestCase
  test "la data può mancare nelle bozze, non nei post programmati o pubblicati" do
    post = Post.new(title: "Bozza")
    assert post.valid?
    assert post.draft?

    post.status = :published
    assert_not post.valid?
    assert post.errors.added?(:publish_at, :blank)
    post.status = :scheduled
    assert_not post.valid?
  end

  test "una bozza senza data si pubblica subito, non si programma; la data diventa quella di uscita" do
    now = Time.zone.parse("2026-11-12 20:30")
    post = posts(:festa_di_natale)

    assert post.publishable?(now)
    assert_not post.schedulable?(now)
    assert_raises(Post::TransitionError) { post.schedule!(now) }

    post.publish!(now)
    assert post.reload.published?
    assert_equal now, post.publish_at
  end

  test "una bozza con la data passata, o arrivata, non si pubblica né si programma" do
    post = posts(:mensa) # giovedì 12 novembre 2026, 20.30
    [ Time.zone.parse("2026-11-12 20:30"), Time.zone.parse("2026-11-20 10:00") ].each do |now|
      assert post.date_expired?(now)
      assert_not post.publishable?(now)
      assert_not post.schedulable?(now)
      assert_raises(Post::TransitionError) { post.publish!(now) }
      assert_raises(Post::TransitionError) { post.schedule!(now) }
    end

    post.update!(publish_at: nil)
    assert post.publishable?
    assert_not post.date_expired?
  end

  test "una bozza con l'ora nel futuro si programma, non si pubblica" do
    now = Time.zone.parse("2026-11-12 20:29")
    post = posts(:mensa)

    assert post.schedulable?(now)
    assert_raises(Post::TransitionError) { post.publish!(now) }

    post.schedule!(now)
    assert post.reload.scheduled?
  end

  test "un post pubblicato si spubblica e torna bozza; gli altri no" do
    posts(:open_day).unpublish!
    assert posts(:open_day).reload.draft?

    assert_raises(Post::TransitionError) { posts(:promemoria).unpublish! }
    assert_raises(Post::TransitionError) { posts(:mensa).unpublish! }
  end

  test "solo le bozze si pubblicano o si programmano" do
    now = Time.zone.parse("2027-01-01 00:00")
    assert_raises(Post::TransitionError) { posts(:promemoria).publish!(now) }
    assert_raises(Post::TransitionError) { posts(:open_day).publish!(now) }
  end


  test "il titolo è obbligatorio" do
    assert_not Post.new.valid?
  end

  test "rifiuta uno stato sconosciuto" do
    post = Post.new(title: "X", status: "cestino")
    assert_not post.valid?
  end

  test "accetta immagini e video, rifiuta altri file" do
    post = posts(:mensa)
    post.media.attach(io: file_fixture("sample.jpg").open, filename: "sample.jpg", content_type: "image/jpeg")
    assert post.valid?

    post.media.attach(io: file_fixture("note.txt").open, filename: "note.txt", content_type: "text/plain")
    assert_not post.valid?
    assert_includes post.errors[:media].first, "note.txt"
  end

  test "ordered_media segue l'ordine salvato e mette in fondo i file non ancora ordinati" do
    post = posts(:mensa)
    %w[a.jpg b.jpg c.jpg].each do |name|
      post.media.attach(io: file_fixture("sample.jpg").open, filename: name, content_type: "image/jpeg")
    end
    a, b, c = post.media.sort_by(&:id)

    post.update_column(:media_order, [ c.blob_id, a.blob_id ])
    assert_equal [ c, a, b ], post.reload.ordered_media
    assert_equal c, post.cover
  end

  test "le pagine social arrivano dalle pubblicazioni" do
    assert_equal [ social_pages(:facebook) ], posts(:promemoria).social_pages.to_a
  end

  test "newest_first mette prima i post senza data e poi dal più recente" do
    expected = [ posts(:festa_di_natale), posts(:promemoria), posts(:mensa), posts(:open_day) ]
    assert_equal expected, Post.newest_first.to_a
  end

  test "overdue segnala i post non pubblicati con la data passata" do
    after = Time.zone.parse("2026-11-19 09:00")
    assert posts(:promemoria).overdue?(after)
    assert_not posts(:open_day).overdue?(after)
    assert_not posts(:festa_di_natale).overdue?(after)
  end

  test "ransack filtra per testo, stato e pagina social" do
    assert_equal [ posts(:mensa) ], Post.ransack(title_or_body_or_notes_cont: "mangia").result.to_a
    assert_equal [ posts(:promemoria) ], Post.ransack(status_eq: "scheduled").result.to_a
    assert_equal [ posts(:festa_di_natale) ], Post.ransack(social_pages_id_eq: social_pages(:instagram).id).result.to_a
    assert_equal [ posts(:festa_di_natale) ], Post.ransack(notes_present: "1").result.to_a
  end
end
