require "test_helper"

class PublicationMetricTest < ActiveSupport::TestCase
  setup do
    @publication = publications(:open_day_facebook)
  end

  test "il giorno si ricava dall'ora della lettura, in ora italiana" do
    # 23.30 UTC del 25 novembre = 00.30 del 26 in Italia
    PublicationMetric.record!(@publication, views: 10, reach: 4, at: Time.utc(2026, 11, 25, 23, 30))
    metric = @publication.metrics.sole

    assert_equal Date.new(2026, 11, 26), metric.measured_on
    assert_equal Time.utc(2026, 11, 25, 23, 30), metric.measured_at
    assert_equal "1234_999", metric.remote_id
  end

  test "anche salvando a mano il giorno lo decide l'ora della lettura" do
    metric = @publication.metrics.create!(measured_at: Time.zone.local(2026, 11, 25, 9), measured_on: Date.new(2020, 1, 1),
                                          total_views: 1, total_reach: 1, remote_id: "1234_999")
    assert_equal Date.new(2026, 11, 25), metric.measured_on
  end

  test "un'altra lettura nello stesso giorno aggiorna la riga; un giorno nuovo ne crea un'altra" do
    PublicationMetric.record!(@publication, views: 10, reach: 4, at: Time.zone.local(2026, 11, 25, 9))
    PublicationMetric.record!(@publication, views: 15, reach: 6, at: Time.zone.local(2026, 11, 25, 18, 45))
    assert_equal 1, @publication.metrics.count
    today = @publication.metrics.sole
    assert_equal [ 15, 6, Time.zone.local(2026, 11, 25, 18, 45) ], [ today.total_views, today.total_reach, today.measured_at ]

    PublicationMetric.record!(@publication, views: 20, reach: 7, at: Time.zone.local(2026, 11, 26, 8))
    assert_equal 2, @publication.metrics.count
    assert_equal Date.new(2026, 11, 26), @publication.latest_metric.measured_on
  end

  test "le statistiche del giorno sono la differenza con l'ultimo giorno precedente letto" do
    PublicationMetric.record!(@publication, views: 180, reach: 70, at: Time.zone.local(2026, 11, 24, 10))
    PublicationMetric.record!(@publication, views: 230, reach: 80, at: Time.zone.local(2026, 11, 25, 10))
    # 26 non letto: il 27 comprende anche il 26
    PublicationMetric.record!(@publication, views: 300, reach: 95, at: Time.zone.local(2026, 11, 27, 10))

    by_day = @publication.metrics.index_by(&:measured_on)
    assert_equal [ 50, 10 ], [ by_day[Date.new(2026, 11, 25)].daily_views, by_day[Date.new(2026, 11, 25)].daily_reach ]
    assert_equal [ 70, 15 ], [ by_day[Date.new(2026, 11, 27)].daily_views, by_day[Date.new(2026, 11, 27)].daily_reach ]
  end

  test "senza lettura precedente: il totale se il post è uscito quel giorno, altrimenti non si sa" do
    PublicationMetric.record!(@publication, views: 900, reach: 300, at: Time.zone.local(2026, 11, 25, 10))
    assert_nil @publication.metrics.sole.daily_views

    @publication.post.update!(publish_at: Time.zone.local(2026, 11, 25, 8))
    assert_equal 900, @publication.metrics.sole.daily_views
  end

  test "se il post è stato ripubblicato la differenza non si fa" do
    PublicationMetric.record!(@publication, views: 400, reach: 200, at: Time.zone.local(2026, 11, 24, 10))
    @publication.update!(remote_id: "1234_777")
    PublicationMetric.record!(@publication, views: 30, reach: 12, at: Time.zone.local(2026, 11, 25, 10))

    assert_nil @publication.latest_metric.daily_views
  end

  test "togliendo il post dai social le statistiche restano; eliminando la pubblicazione spariscono" do
    PublicationMetric.record!(@publication, views: 10, reach: 4)
    @publication.clear_remote!
    assert_equal 1, PublicationMetric.count

    @publication.destroy!
    assert_equal 0, PublicationMetric.count
  end
end
