require "test_helper"

class TrendChartTest < ActiveSupport::TestCase
  def days(count, from: Date.new(2026, 11, 1), step: 1)
    Array.new(count) { |i| [ from + (i * step), (i + 1) * 37 ] }
  end

  def svg(chart) = Nokogiri::XML(chart.to_svg.to_s).remove_namespaces!

  test "con pochi giorni c'è una data per ogni giorno" do
    chart = TrendChart.new(days(4), label: "visualizzazioni")
    assert_equal days(4).map(&:first), chart.x_ticks
  end

  test "con tanti giorni le date si diradano e non si sovrappongono" do
    chart = TrendChart.new(days(60), label: "visualizzazioni", width: 330)
    ticks = chart.x_ticks
    assert_operator ticks.size, :<=, 6
    assert_operator ticks.size, :>=, 2
    assert_operator (ticks[1] - ticks[0]).to_i, :>=, 7

    year = TrendChart.new(days(365), label: "visualizzazioni", width: 580)
    assert year.x_ticks.all? { |day| day.day == 1 }, "su un anno le date sono inizi di mese"
    assert_operator year.x_ticks.size, :<=, 8
  end

  test "l'asse dei tempi è proporzionale: i giorni senza lettura restano spazi" do
    points = [ [ Date.new(2026, 11, 1), 10 ], [ Date.new(2026, 11, 2), 20 ], [ Date.new(2026, 11, 11), 30 ] ]
    xs = svg(TrendChart.new(points, label: "visualizzazioni")).at_css("polyline")["points"].split.map { |p| p.split(",").first.to_f }
    assert_in_delta 9.0, (xs[2] - xs[1]) / (xs[1] - xs[0]), 0.01
  end

  test "l'asse dei valori parte da zero con tacche tonde" do
    assert_equal [ 0, 250, 500, 750, 1000 ], TrendChart.new([ [ Date.current, 916 ] ], label: "x").y_ticks
    assert_equal [ 0, 1, 2, 3 ], TrendChart.new([ [ Date.current, 3 ] ], label: "x").y_ticks
    assert_equal [ 0, 1 ], TrendChart.new([ [ Date.current, 0 ] ], label: "x").y_ticks
  end

  test "pallini su ogni lettura finché sono poche, poi solo sull'ultima; il valore finale è scritto" do
    few = svg(TrendChart.new(days(10), label: "visualizzazioni"))
    assert_equal 10, few.css("circle:not(.tc-guide)").size
    many = svg(TrendChart.new(days(40), label: "visualizzazioni"))
    assert_equal 1, many.css("circle:not(.tc-guide)").size
    assert_includes many.css("text").map(&:text), TrendChart.number(40 * 37)
  end

  test "in un grafico stretto i pallini troppo vicini spariscono, resta l'ultimo" do
    narrow = svg(TrendChart.new(days(20), label: "visualizzazioni", width: 330))
    assert_equal 1, narrow.css("circle:not(.tc-guide)").size
    wide = svg(TrendChart.new(days(20), label: "visualizzazioni", width: 660))
    assert_equal 20, wide.css("circle:not(.tc-guide)").size
  end

  test "ogni lettura ha il suo suggerimento con data e valore" do
    doc = svg(TrendChart.new([ [ Date.new(2026, 11, 25), 1234 ] ], label: "visualizzazioni"))
    assert_equal [ "mer 25 nov 2026 · 1.234 visualizzazioni" ], doc.css(".tc-hit title").map(&:text)
    assert_match(/1\.234 alla lettura del 25 novembre 2026/, doc.at_css("svg")["aria-label"])
    assert_nil doc.at_css("polyline"), "con una sola lettura non c'è linea"
  end

  test "numeri all'italiana" do
    assert_equal "916", TrendChart.number(916)
    assert_equal "12.345", TrendChart.number(12_345)
    assert_equal "20k", TrendChart.number(20_000, compact: true)
    assert_equal "12.500", TrendChart.number(12_500, compact: true)
  end

  test "senza letture non disegna niente" do
    assert_equal "", TrendChart.new([], label: "x").to_svg
  end
end
