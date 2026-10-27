require "test_helper"

class SuggestionRunnerTest < ActiveSupport::TestCase
  setup do
    @batch = PostSuggestionBatch.new(SecureRandom.uuid)
    @runner = SuggestionRunner.new(@batch, today: Date.new(2026, 10, 27))
  end

  teardown { @batch.discard! }

  test "stessi permessi della chat, con più turni e senza riprendere conversazioni" do
    cmd = @runner.command
    assert_equal "200", cmd[cmd.index("--max-turns") + 1]
    assert_not_includes cmd, "--resume"
    assert_includes cmd, "Edit(/#{@batch.outbox}/**)"
    assert_includes cmd, "Bash(#{AssistantRunner::ASSISTANT_BIN}:*)"
    assert_equal 40.minutes, SuggestionRunner::TIMEOUT
  end

  test "le istruzioni comprendono il formato delle proposte e le regole delle grafiche della chat" do
    prompt = @runner.system_prompt
    assert_includes prompt, "#{@batch.outbox}/proposta-01.json"
    assert_includes prompt, @batch.outbox.to_s
    assert_includes prompt, "## Grafiche: varietà e fantasia"
    assert_not_includes prompt, "## Come proporre modifiche al post"
  end

  test "la richiesta dice il periodo e elenca i post già presenti" do
    prompt = @runner.prompt
    assert_includes prompt, "Oggi è martedì 27 ottobre 2026"
    assert_includes prompt, "a mercoledì 27 gennaio 2027"
    assert_includes prompt, "Promemoria Open Day"
    assert_includes prompt, "senza data · Festa di Natale"
  end
end

class ProposalExtractorTest < ActiveSupport::TestCase
  test "ricava le frasi saltando i blocchi di codice, anche se arrivano spezzate a metà" do
    extractor = ProposalExtractor.new
    text = "Guardo il calendario.\nEcco:\n```json\n{\"titolo\": \"A\"}\n```\nFatto, una proposta."
    results = text.chars.each_slice(5).map { |piece| extractor.push(piece.join) }

    assert_equal 1, results.sum { |r| r[:blocks].size }
    assert_equal [ "Guardo il calendario.", "Ecco:" ], results.flat_map { |r| r[:lines] }
    assert_equal [ "Fatto, una proposta." ], extractor.finish
  end

  test "un blocco lasciato a metà non finisce nel riepilogo" do
    extractor = ProposalExtractor.new
    extractor.push("Inizio.\n```json\n{\"tit")
    assert_empty extractor.finish
  end
end
