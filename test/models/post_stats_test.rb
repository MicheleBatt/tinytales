require "test_helper"

class PostStatsTest < ActiveSupport::TestCase
  setup do
    @post = posts(:open_day)
    @facebook = publications(:open_day_facebook)
    @instagram = Publication.create!(post: @post, social_page: social_pages(:instagram), remote_id: "ig_1", remote_kind: "feed")
  end

  def read(publication, views, reach, day, hour = 10)
    PublicationMetric.record!(publication, views:, reach:, at: Time.zone.local(2026, 11, day, hour))
  end

  test "i totali sono la somma delle ultime letture di ogni social" do
    read(@facebook, 100, 40, 20)
    read(@facebook, 150, 50, 21, 18)
    read(@instagram, 30, 10, 20)

    totals = PostStats.latest([ @post.id, posts(:mensa).id ])
    assert_equal [ @post.id ], totals.keys
    assert_equal [ 180, 60, Time.zone.local(2026, 11, 21, 18) ], totals[@post.id].to_h.values_at(:views, :reach, :measured_at)
  end

  test "l'andamento ha un punto per giorno di lettura; un social non letto quel giorno vale la sua lettura precedente" do
    read(@facebook, 100, 40, 20)
    read(@instagram, 30, 10, 20)
    read(@facebook, 150, 50, 22)
    read(@instagram, 45, 12, 23)

    points = PostStats.series([ @post.id ])[@post.id]
    assert_equal [ Date.new(2026, 11, 20), Date.new(2026, 11, 22), Date.new(2026, 11, 23) ], points.map(&:day)
    assert_equal [ 130, 180, 195 ], points.map(&:views)
    assert_equal [ 50, 60, 62 ], points.map(&:reach)
    assert_equal PostStats.latest([ @post.id ])[@post.id].to_h.values_at(:views, :reach),
                 PostStats.totals_of(points.last).to_h.values_at(:views, :reach)
  end

  test "l'aumento dall'ultimo giorno letto prima; niente con una lettura sola o se il totale scende" do
    read(@facebook, 100, 40, 20)
    assert_nil PostStats.change(PostStats.series([ @post.id ])[@post.id], :views)

    read(@facebook, 160, 52, 23)
    points = PostStats.series([ @post.id ])[@post.id]
    assert_equal [ 60, Date.new(2026, 11, 20) ], PostStats.change(points, :views)
    assert_equal [ 12, Date.new(2026, 11, 20) ], PostStats.change(points, :reach)

    read(@facebook, 5, 3, 24) # ripubblicato: i totali ripartono
    assert_nil PostStats.change(PostStats.series([ @post.id ])[@post.id], :views)
  end

  test "le reazioni si sommano sui social, tipo per tipo; le letture senza reazioni non contano" do
    PublicationMetric.record!(@facebook, views: 100, reach: 40, at: Time.zone.local(2026, 11, 25, 10)) # prima delle reazioni
    PublicationMetric.record!(@facebook, views: 150, reach: 50, reactions: 21, reactions_by_type: { "like" => 19, "love" => 2 },
                                         at: Time.zone.local(2026, 11, 26, 10))
    PublicationMetric.record!(@instagram, views: 30, reach: 10, reactions: 4, reactions_by_type: { "like" => 3, "haha" => 1 },
                                          at: Time.zone.local(2026, 11, 26, 10))

    totals = PostStats.latest([ @post.id ])[@post.id]
    assert_equal [ 25, { "like" => 22, "love" => 2, "haha" => 1 } ], [ totals.reactions, totals.reactions_by_type ]

    points = PostStats.series([ @post.id ])[@post.id]
    assert_equal [ nil, 25 ], points.map(&:reactions)
    assert_nil PostStats.change(points, :reactions), "il giorno prima le reazioni non c'erano"
    assert_equal [ 80, Date.new(2026, 11, 25) ], PostStats.change(points, :views)
  end

  test "le condivisioni si sommano sui social; se il totale scende (post ripubblicato) niente aumento" do
    PublicationMetric.record!(@facebook, views: 100, reach: 40, shares: 13, at: Time.zone.local(2026, 11, 25, 10))
    PublicationMetric.record!(@instagram, views: 30, reach: 10, shares: 2, at: Time.zone.local(2026, 11, 25, 10))
    PublicationMetric.record!(@facebook, views: 120, reach: 45, shares: 11, at: Time.zone.local(2026, 11, 26, 10))

    points = PostStats.series([ @post.id ])[@post.id]
    assert_equal [ 15, 13 ], points.map(&:shares)
    assert_nil PostStats.change(points, :shares)
    assert_equal 13, PostStats.latest([ @post.id ])[@post.id].shares
    assert_equal 0, @facebook.metrics.find_by(measured_on: Date.new(2026, 11, 26)).daily_shares
  end

  test "si mostrano solo per i post pubblicati" do
    assert PostStats.shown?(@post)
    assert_not PostStats.shown?(posts(:mensa))
    assert_nil PostStats.totals_of(nil)
  end
end
