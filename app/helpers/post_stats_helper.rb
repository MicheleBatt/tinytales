# Visualizzazioni, persone raggiunte e reazioni dei post: icone, numeri e grafici dell'andamento.
module PostStatsHelper
  STATS_LABELS = { views: "Visualizzazioni", reach: "Persone raggiunte", reactions: "Reazioni" }.freeze

  # I tipi di reazione di Facebook, con la loro emoji e il nome dell'interfaccia italiana, nell'ordine di Facebook.
  REACTION_TYPES = {
    "like" => [ "👍", "Mi piace" ], "love" => [ "❤️", "Love" ], "care" => [ "🥰", "Abbraccio" ], "haha" => [ "😆", "Ahah" ],
    "wow" => [ "😮", "Wow" ], "sad" => [ "😢", "Sigh" ], "angry" => [ "😡", "Grrr" ]
  }.freeze

  # Icone disegnate a tratto, del colore del testo: un occhio per le visualizzazioni, due persone per quelle raggiunte,
  # un pollice in su per le reazioni.
  STATS_ICONS = {
    views: '<path d="M1.5 8s2.5-4.5 6.5-4.5S14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="2"/>',
    reach: '<circle cx="6" cy="5.5" r="2.25"/><path d="M1.75 13c.4-2.4 2.1-3.75 4.25-3.75S9.85 10.6 10.25 13"/>' \
           '<path d="M10.5 3.6a2.1 2.1 0 1 1 0 3.9M11.6 9.4c1.5.35 2.45 1.6 2.7 3.6"/>',
    reactions: '<path d="M4.75 7.25v6.5H2v-6.5h2.75Z"/>' \
               '<path d="M4.75 7.25 7.6 2.2c1.05 0 1.85.85 1.65 1.9l-.4 2.15h3.55c.95 0 1.6.85 1.4 1.75l-1.05 4.45c-.2.75-.85 1.3-1.65 1.3H4.75"/>'
  }.freeze

  def stats_icon(kind)
    tag.svg(STATS_ICONS.fetch(kind).html_safe, class: "icona-statistica", viewBox: "0 0 16 16", width: 14, height: 14,
            fill: "none", stroke: "currentColor", "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round",
            "aria-hidden": true)
  end

  def stats_number(value) = TrendChart.number(value)

  # Il grafico dell'andamento di una misura (:views, :reach o :reactions) nei giorni di lettura.
  # I giorni in cui la misura manca (le reazioni prima del 26/11/2026) restano fuori.
  def stats_chart(points, kind, width:, height:)
    TrendChart.new(points.filter_map { |point| (value = point.public_send(kind)) && [ point.day, value ] },
                   label: STATS_LABELS.fetch(kind).downcase, width:, height:).to_svg
  end

  # Il dettaglio delle reazioni per tipo, dalle più numerose: [[emoji, nome, numero], …].
  def reactions_breakdown(by_type)
    order = REACTION_TYPES.keys
    by_type.to_h.select { |_, count| count.to_i.positive? }
           .sort_by { |type, count| [ -count, order.index(type) || order.size ] }
           .map { |type, count| [ *REACTION_TYPES.fetch(type, [ "•", type.capitalize ]), count ] }
  end

  # L'indirizzo che aggiorna da Facebook i numeri della pagina (contesto: elenco, pagina o popup).
  def stats_refresh_url(post_ids, contesto)
    statistiche_posts_path(ids: Array(post_ids).join(","), contesto:)
  end
end
