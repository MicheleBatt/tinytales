module FacebookGraph
  # Un errore restituito da Facebook, con il messaggio che Facebook stesso dà.
  class Error < StandardError
    attr_reader :code, :subcode

    def initialize(message, code: nil, subcode: nil)
      super(message)
      @code = code
      @subcode = subcode
    end
  end
end
