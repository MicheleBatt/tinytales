# Un grafico a linea dell'andamento di un numero nel tempo (per esempio le visualizzazioni di un post),
# disegnato come SVG sul server: lo stesso disegno va nelle pagine dell'app e nel report PDF.
#
# Leggibilità con pochi e con tanti giorni:
# - l'asse del tempo è proporzionale: i giorni senza lettura restano spazi vuoti, non vengono schiacciati;
# - le date sull'asse si diradano da sole: ogni giorno, ogni 2, 3, 7 o 14 giorni, poi ogni 1, 2, 3, 6 o 12 mesi,
#   scegliendo il passo più fitto che entra nella larghezza senza sovrapporsi;
# - l'asse dei valori parte da zero, con 3–5 tacche «tonde» (1, 2, 2,5, 5 × 10ⁿ);
# - la linea passa morbida da una lettura all'altra (curva monotona: non sale né scende oltre i valori letti,
#   quindi un totale che cresce non sembra mai calare fra due giorni);
# - i pallini su ogni lettura ci sono finché le letture sono al massimo MARKERS_UP_TO e distano almeno MARKER_GAP
#   l'una dall'altra; altrimenti resta solo la linea, con il pallino sull'ultima lettura;
# - sopra ogni pallino il suo valore: l'ultimo e il primo sempre, gli altri quando c'è posto senza accavallarsi.
# Al passaggio del mouse una linea guida e il suggerimento con data e valore di ogni lettura.
#
# width e height sono le misure del disegno: conviene sceglierle vicine a quelle con cui sarà mostrato,
# così le scritte restano della loro grandezza.
class TrendChart
  include ERB::Util

  STEPS = [ [ 1, :day ], [ 2, :day ], [ 3, :day ], [ 7, :day ], [ 14, :day ],
            [ 1, :month ], [ 2, :month ], [ 3, :month ], [ 6, :month ], [ 12, :month ] ].freeze
  MARKERS_UP_TO = 31
  MARKER_GAP = 14 # distanza minima fra due pallini, perché non si accavallino
  FONT = 11
  LABEL_GAP = 14 # spazio minimo fra due date sull'asse
  VALUE_GAP = 4 # spazio minimo fra due valori sopra i pallini

  GRID = "#EDEFF3"
  AXIS = "#C9CED8"
  TEXT = "#626A7C"
  INK = "#1D2230"
  SURFACE = "#FFFFFF"

  # points: [[Date, Integer], …] in ordine di data. label: che cosa si conta, al plurale («visualizzazioni»).
  def initialize(points, label:, width: 520, height: 180, color: "#2456A6")
    @points = points
    @label = label
    @width = width
    @height = height
    @color = color
  end

  def to_svg
    return "".html_safe if @points.empty?

    layout
    parts = [ style, grid, x_axis, area, line, markers, value_labels, hover ].join
    (%(<svg class="trend-chart" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{@width} #{@height}" ) +
      %(width="100%" role="img" aria-label="#{h(summary)}">#{parts}</svg>)).html_safe
  end

  # Le date scelte per l'asse orizzontale e il loro passo (per i test).
  def x_ticks
    layout
    @x_ticks
  end

  # Le tacche dell'asse verticale (per i test).
  def y_ticks
    layout
    @y_ticks
  end

  # Il numero scritto all'italiana: 1.234. Sull'asse, da 10.000 in su, in migliaia: 12k.
  def self.number(value, compact: false)
    return "#{value / 1000}k" if compact && value >= 10_000 && (value % 1000).zero?

    value.to_i.to_s.reverse.scan(/\d{1,3}/).join(".").reverse
  end

  private

  def layout
    return if @layout_done

    @layout_done = true
    @days = @points.map(&:first)
    @values = @points.map(&:last)
    @y_ticks = nice_ticks(@values.max)
    @y_max = @y_ticks.last

    y_label_width = @y_ticks.map { |tick| text_width(self.class.number(tick, compact: true)) }.max
    @left = y_label_width + 10
    # A destra il posto per il valore sopra l'ultimo pallino, centrato; in alto quello per il valore sul pallino più alto.
    @right = [ text_width(self.class.number(@values.last), bold: true) / 2 + 4, 16 ].max
    @top = 22
    @bottom = 24
    @plot_w = @width - @left - @right
    @plot_h = @height - @top - @bottom
    @baseline = @top + @plot_h

    @x_ticks, @x_unit = choose_x_ticks
  end

  # Larghezza stimata di una scritta (cifre e lettere minuscole), per lasciare il posto giusto.
  def text_width(text, bold: false) = (text.length * FONT * (bold ? 0.64 : 0.6)).ceil

  def x(day)
    return @left + @plot_w / 2.0 if @days.first == @days.last

    @left + (day - @days.first).to_f / (@days.last - @days.first) * @plot_w
  end

  def y(value) = @baseline - value.to_f / @y_max * @plot_h

  def nice_ticks(max)
    return [ 0, 1 ] if max.to_i <= 0

    raw = max / 4.0
    magnitude = 10**Math.log10(raw).floor
    multiples = magnitude >= 10 ? [ 1, 2, 2.5, 5, 10 ] : [ 1, 2, 5, 10 ] # 2,5 solo dove resta un numero intero (25, 250…)
    step = multiples.map { |m| m * magnitude }.find { |s| s >= raw }
    step = [ step.ceil, 1 ].max
    (0..((max.to_f / step).ceil * step)).step(step).to_a
  end

  def choose_x_ticks
    return [ [ @days.first ], :day ] if @days.first == @days.last

    STEPS.each do |n, unit|
      ticks = unit == :day ? (@days.first..@days.last).step(n).to_a : month_ticks(n)
      next if ticks.empty?
      return [ ticks, unit ] if fits?(ticks, unit)
    end
    [ month_ticks(12).presence || [ @days.first ], :month ]
  end

  def month_ticks(n)
    first = @days.first.beginning_of_month
    first = first.next_month if first < @days.first
    months = []
    while first <= @days.last
      months << first if ((first.month - 1) % n).zero?
      first = first.next_month
    end
    months
  end

  def fits?(ticks, unit)
    centers = ticks.map { |day| x(day) }
    widths = ticks.map { |day| text_width(tick_label(day, unit)) }
    centers.each_cons(2).with_index.all? { |(a, b), i| b - a >= (widths[i] + widths[i + 1]) / 2.0 + LABEL_GAP }
  end

  def tick_label(day, unit) = I18n.l(day, format: unit == :day ? "%-d %b" : "%b %Y")

  def fmt(value) = format("%.1f", value)

  def style
    "<style>.tc-hit .tc-guide{opacity:0}.tc-hit:hover .tc-guide{opacity:1}" \
      ".trend-chart text{font-variant-numeric:tabular-nums}</style>"
  end

  def grid
    @y_ticks.map do |tick|
      yy = fmt(y(tick))
      %(<line x1="#{@left}" x2="#{@left + @plot_w}" y1="#{yy}" y2="#{yy}" stroke="#{tick.zero? ? AXIS : GRID}" stroke-width="1"/>) +
        %(<text x="#{@left - 6}" y="#{fmt(y(tick) + 3.5)}" text-anchor="end" font-size="#{FONT}" fill="#{TEXT}">#{self.class.number(tick, compact: true)}</text>)
    end.join
  end

  # Le date sotto l'asse; la prima e l'ultima non escono dal disegno.
  def x_axis
    @x_ticks.map do |day|
      xx = x(day)
      label = tick_label(day, @x_unit)
      half = text_width(label) / 2.0
      anchor, tx = if xx - half < 0 then [ "start", 0 ]
      elsif xx + half > @width then [ "end", @width ]
      else [ "middle", xx ]
      end
      %(<text x="#{fmt(tx)}" y="#{@height - 6}" text-anchor="#{anchor}" font-size="#{FONT}" fill="#{TEXT}">#{h(label)}</text>)
    end.join
  end

  def coords = @points.map { |day, value| "#{fmt(x(day))},#{fmt(y(value))}" }

  def area
    return "" if @points.size < 2

    first_x = fmt(x(@days.first))
    last_x = fmt(x(@days.last))
    # Sfumatura dal colore della linea (in alto) al trasparente (sulla base); id unico, perché nella pagina ci sono più grafici.
    id = "tc-sfumatura-#{SecureRandom.hex(4)}"
    %(<defs><linearGradient id="#{id}" x1="0" y1="0" x2="0" y2="1">) +
      %(<stop offset="0" stop-color="#{@color}" stop-opacity="0.16"/><stop offset="1" stop-color="#{@color}" stop-opacity="0.01"/>) +
      %(</linearGradient></defs>) +
      %(<path d="M#{first_x},#{@baseline} L#{curve} L#{last_x},#{@baseline} Z" fill="url(##{id})"/>)
  end

  def line
    return "" if @points.size < 2

    %(<path class="tc-line" d="M#{curve}" fill="none" stroke="#{@color}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>)
  end

  # Il tracciato della linea, senza la «M» iniziale: dal primo punto, un arco di Bézier per ogni tratto.
  # Pendenze come la curva «monotoneX» di d3 (Steffen, 1990): dove la serie cambia verso la curva è piatta,
  # altrimenti la pendenza è limitata, così la linea non esce mai dall'intervallo fra due valori vicini.
  def curve
    xs = @points.map { |day, _| x(day) }
    ys = @points.map { |_, value| y(value) }
    return coords.join(" L") if xs.size < 3

    tangents = monotone_tangents(xs, ys)
    segments = (0...(xs.size - 1)).map do |i|
      third = (xs[i + 1] - xs[i]) / 3.0
      "C#{fmt(xs[i] + third)},#{fmt(ys[i] + third * tangents[i])} " \
        "#{fmt(xs[i + 1] - third)},#{fmt(ys[i + 1] - third * tangents[i + 1])} #{fmt(xs[i + 1])},#{fmt(ys[i + 1])}"
    end
    "#{fmt(xs.first)},#{fmt(ys.first)} #{segments.join(' ')}"
  end

  def monotone_tangents(xs, ys)
    slopes = xs.each_cons(2).zip(ys.each_cons(2)).map { |(x0, x1), (y0, y1)| (y1 - y0) / (x1 - x0) }
    inner = (1...(xs.size - 1)).map do |i|
      h0 = xs[i] - xs[i - 1]
      h1 = xs[i + 1] - xs[i]
      s0, s1 = slopes[i - 1], slopes[i]
      p = (s0 * h1 + s1 * h0) / (h0 + h1)
      (sign(s0) + sign(s1)) * [ s0.abs, s1.abs, 0.5 * p.abs ].min
    end
    first = end_tangent(slopes.first, inner.first)
    last = end_tangent(slopes.last, inner.last)
    [ first, *inner, last ]
  end

  # Agli estremi: la pendenza che fa arrivare la curva al tratto vicino senza gobbe.
  def end_tangent(slope, neighbour) = (3 * slope - neighbour) / 2.0

  def sign(value) = value <=> 0

  def dot(day, value, radius = 4)
    %(<circle cx="#{fmt(x(day))}" cy="#{fmt(y(value))}" r="#{radius}" fill="#{@color}" stroke="#{SURFACE}" stroke-width="2"/>)
  end

  def marked_points
    spaced = @days.each_cons(2).all? { |a, b| x(b) - x(a) >= MARKER_GAP }
    @points.size <= MARKERS_UP_TO && spaced ? @points : [ @points.last ]
  end

  def markers = marked_points.map { |day, value| dot(day, value) }.join

  # Il valore sopra ogni pallino, con un alone del colore di fondo perché resti leggibile anche dove passa la linea.
  # Si sceglie prima l'ultimo, poi il primo, poi gli altri da sinistra: chi si accavallerebbe a uno già scelto resta fuori
  # (il suo numero resta nel suggerimento al passaggio del mouse).
  def value_labels
    marked = marked_points
    order = [ marked.size - 1, 0, *(1...(marked.size - 1)) ].uniq
    boxes = []
    order.filter_map do |i|
      day, value = marked[i]
      label = self.class.number(value)
      last = i == marked.size - 1
      half = text_width(label, bold: last) / 2.0
      cx = x(day).clamp(@left - 3 + half, @width - half - 1) # a sinistra non entra fra i numeri dell'asse
      baseline = y(value) - 8
      box = [ cx - half - VALUE_GAP / 2.0, baseline - FONT, cx + half + VALUE_GAP / 2.0, baseline + 3 ]
      next if boxes.any? { |other| overlap?(box, other) }

      boxes << box
      %(<text x="#{fmt(cx)}" y="#{fmt(baseline)}" text-anchor="middle" font-size="#{FONT}" font-weight="#{last ? 600 : 500}" ) +
        %(fill="#{last ? INK : TEXT}" stroke="#{SURFACE}" stroke-width="3" stroke-linejoin="round" paint-order="stroke">#{label}</text>)
    end.join
  end

  def overlap?(a, b) = a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]

  # Una fascia verticale per lettura (fino a metà strada dalle vicine): al passaggio del mouse mostra la guida e il suggerimento.
  def hover
    xs = @days.map { |day| x(day) }
    @points.each_with_index.map do |(day, value), i|
      from = i.zero? ? @left : (xs[i - 1] + xs[i]) / 2.0
      to = i == xs.size - 1 ? @left + @plot_w : (xs[i] + xs[i + 1]) / 2.0
      from, to = @left, @left + @plot_w if xs.size == 1
      tip = "#{I18n.l(day, format: '%a %-d %b %Y')} · #{self.class.number(value)} #{@label}"
      %(<g class="tc-hit"><title>#{h(tip)}</title>) +
        %(<rect x="#{fmt(from)}" y="#{@top}" width="#{fmt([ to - from, 1 ].max)}" height="#{@plot_h}" fill="transparent"/>) +
        %(<line class="tc-guide" x1="#{fmt(xs[i])}" x2="#{fmt(xs[i])}" y1="#{@top}" y2="#{@baseline}" stroke="#{AXIS}" stroke-width="1"/>) +
        %(<circle class="tc-guide" cx="#{fmt(xs[i])}" cy="#{fmt(y(value))}" r="5" fill="#{@color}" stroke="#{SURFACE}" stroke-width="2"/></g>)
    end.join
  end

  def summary
    first_day, first_value = @points.first
    last_day, last_value = @points.last
    if @points.size == 1
      "#{@label.capitalize}: #{self.class.number(last_value)} alla lettura del #{I18n.l(last_day, format: '%-d %B %Y')}"
    else
      "#{@label.capitalize}: da #{self.class.number(first_value)} il #{I18n.l(first_day, format: '%-d %B %Y')} " \
        "a #{self.class.number(last_value)} il #{I18n.l(last_day, format: '%-d %B %Y')}, #{@points.size} letture"
    end
  end
end
