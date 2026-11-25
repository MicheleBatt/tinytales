require "test_helper"

class PostMetricsTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.local(2026, 11, 25, 16, 0)
    @page = social_pages(:facebook)
    @open_day = publications(:open_day_facebook)
  end

  def all_publications = Publication.includes(:post, :social_page).to_a

  test "salva visualizzazioni e persone dei soli post pubblicati sui social, con una batch" do
    @facebook.insights("1234_999", views: 916, reach: 320)

    assert_equal 1, PostMetrics.refresh(all_publications)

    metric = @open_day.metrics.sole
    assert_equal [ 916, 320, Date.new(2026, 11, 25), Time.current, "1234_999" ],
                 [ metric.total_views, metric.total_reach, metric.measured_on, metric.measured_at, metric.remote_id ]
    # promemoria è solo programmato, mensa e festa sono bozze: nessuna lettura per loro
    assert_equal [ [ "1234_999/insights?metric=post_media_view,post_total_media_view_unique&period=lifetime" ] ], @facebook.batches
  end

  test "un post letto meno di un minuto fa non si rilegge" do
    @facebook.insights("1234_999", views: 10, reach: 4)
    PostMetrics.refresh(all_publications)

    travel 59.seconds
    assert_equal 0, PostMetrics.refresh(all_publications)
    assert_equal 1, @facebook.batches.size

    travel 2.seconds
    @facebook.insights("1234_999", views: 12, reach: 5)
    assert_equal 1, PostMetrics.refresh(all_publications)
    assert_equal [ 12, 5 ], [ @open_day.metrics.sole.total_views, @open_day.metrics.sole.total_reach ]
  end

  test "di un video si legge il post che lo contiene, chiedendolo a Facebook una volta sola" do
    @open_day.update!(remote_id: "555", remote_kind: "video")
    @facebook.respond_to_get("555", { "post_id" => "777", "id" => "555" })
    @facebook.insights("1234_777", views: 242, reach: 170)

    PostMetrics.refresh(all_publications)
    assert_equal "1234_777", @open_day.reload.remote_post_id
    assert_equal [ 242, "555" ], [ @open_day.metrics.sole.total_views, @open_day.metrics.sole.remote_id ]

    travel 2.minutes
    PostMetrics.refresh(all_publications)
    assert_equal 1, @facebook.paths(:get).count("555")
  end

  test "un video ripubblicato perde l'id del post che lo conteneva" do
    @open_day.update!(remote_id: "555", remote_kind: "video", remote_post_id: "1234_777")
    @open_day.record_result!(SocialPublishers::Result.new(remote_id: "556", remote_kind: "video"), @open_day.post)
    assert_nil @open_day.remote_post_id
  end

  test "vicino ai limiti di Meta la pagina non viene interrogata per un po'" do
    @facebook.insights("1234_999", views: 10, reach: 4)
    @facebook.last_usage = FacebookGraph::Usage.new(percent: 80, regain_minutes: 0)

    assert_equal 1, PostMetrics.refresh(all_publications)
    assert_equal Time.current + 15.minutes, @page.reload.metrics_paused_until

    travel 14.minutes
    assert_equal 0, PostMetrics.refresh(all_publications)
    assert_equal 1, @facebook.batches.size

    travel 2.minutes
    @facebook.last_usage = nil
    assert_equal 1, PostMetrics.refresh(all_publications)
  end

  test "se Facebook risponde «troppe chiamate» si aspetta almeno mezz'ora, o quanto dice Meta" do
    @facebook.insights("1234_999", error: FacebookGraph::Error.new("Facebook: troppe chiamate", code: 80001))
    @facebook.last_usage = FacebookGraph::Usage.new(percent: 100, regain_minutes: 45)

    assert_equal 0, PostMetrics.refresh(all_publications)
    assert_equal Time.current + 45.minutes, @page.reload.metrics_paused_until
    assert_empty PublicationMetric.all
  end

  test "un errore di Facebook non blocca niente: zero letture e nessuna pausa" do
    @facebook.fail_on(:batch, //, "Errore di prova")
    assert_equal 0, PostMetrics.refresh(all_publications)
    assert_nil @page.reload.metrics_paused_until
  end

  test "oltre 50 post servono più batch" do
    post = posts(:open_day)
    publications = Array.new(51) do |i|
      Publication.new(id: 10_000 + i, post:, social_page: @page, remote_id: "1234_#{i}", remote_kind: "feed")
    end
    publications.each { |p| @facebook.insights(p.remote_id, views: 1, reach: 1) }

    result = SocialMetrics::Facebook.new(@page).read(publications)
    assert_equal [ 1, 50 ], @facebook.batches.map(&:size).sort # partono insieme: l'ordine è casuale
    assert_equal 51, result.readings.size
  end
end
