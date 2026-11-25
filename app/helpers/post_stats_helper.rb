# Visualizzazioni e persone raggiunte dei post: icone, numeri e grafici dell'andamento.
module PostStatsHelper
  STATS_LABELS = { views: "Visualizzazioni", reach: "Persone raggiunte" }.freeze

  # Icone disegnate a tratto, del colore del testo: un occhio per le visualizzazioni, due persone per quelle raggiunte.
  STATS_ICONS = {
    views: '<path d="M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/>',
    reach: '<circle cx="6" cy="5.5" r="2.25"/><path d="M1.75 13c.4-2.4 2.1-3.75 4.25-3.75S9.85 10.6 10.25 13"/>' \
           '<path d="M10.5 3.6a2.1 2.1 0 1 1 0 3.9M11.6 9.4c1.5.35 2.45 1.6 2.7 3.6"/>'
  }.freeze

  def stats_icon(kind)
    tag.svg(STATS_ICONS.fetch(kind).html_safe, class: "icona-statistica", viewBox: "0 0 16 16", width: 14, height: 14,
            fill: "none", stroke: "currentColor", "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round",
            "aria-hidden": true)
  end

  def stats_number(value) = TrendChart.number(value)

  # Il grafico dell'andamento di una delle due misure (:views o :reach) nei giorni di lettura.
  def stats_chart(points, kind, width:, height:)
    TrendChart.new(points.map { |point| [ point.day, point.public_send(kind) ] },
                   label: STATS_LABELS.fetch(kind).downcase, width:, height:).to_svg
  end

  # L'indirizzo che aggiorna da Facebook i numeri della pagina (contesto: elenco, pagina o popup).
  def stats_refresh_url(post_ids, contesto)
    statistiche_posts_path(ids: Array(post_ids).join(","), contesto:)
  end
end
