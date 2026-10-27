# Legge il testo di Claude man mano che arriva e ne ricava le frasi, che diventano lo stato del lavoro
# e il riepilogo finale. Gli eventuali blocchi di codice (```…```) vengono saltati: le proposte
# Claude le consegna come file, non nel testo.
class ProposalExtractor
  BLOCK = /```[^\n]*\n.*?\n[ \t]*```/m

  def initialize
    @buffer = +""
    @narrative = +""
  end

  # Aggiunge un pezzo di testo; restituisce i blocchi saltati e le frasi completate.
  def push(text)
    @buffer << text
    blocks = []
    while (match = @buffer.match(BLOCK))
      @narrative << match.pre_match
      blocks << match[0]
      @buffer = match.post_match
    end

    # Fuori da un blocco aperto, il testo fino all'ultimo a capo è narrativa già completa.
    open = @buffer.index("```")
    newline = @buffer.rindex("\n")
    safe = if open then @buffer[0...open]
    elsif newline then @buffer[0..newline]
    else ""
    end
    @narrative << safe
    @buffer = @buffer[safe.length..]

    { blocks:, lines: take_lines }
  end

  # A fine lavoro: il testo rimasto, senza blocchi a metà.
  def finish
    @narrative << @buffer.sub(/```.*\z/m, "")
    @buffer = +""
    take_lines + [ @narrative.strip ].reject(&:empty?).tap { @narrative = +"" }
  end

  private

  def take_lines
    *complete, rest = @narrative.split("\n", -1)
    @narrative = +rest.to_s
    complete.map(&:strip).reject(&:empty?)
  end
end
