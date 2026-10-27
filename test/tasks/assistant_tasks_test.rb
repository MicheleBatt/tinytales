require "test_helper"
require "rake"

class AssistantTasksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("assistant:import_files")
    @conversation = AssistantConversation.create!(token: SecureRandom.uuid, post: posts(:mensa))
    folder = @conversation.outbox
    @user = @conversation.messages.create!(role: "user", content: "ecco", attachments: [ { "name" => "appunti.txt", "kind" => "testo" } ])
    @first = @conversation.messages.create!(role: "assistant", content: "```proposta:file\n/vecchio/percorso/#{@conversation.token}/grafica.jpg\n```")
    @last = @conversation.messages.create!(role: "assistant", content: "Fatto.")
    folder.join("appunti.txt").write("note")
    folder.join("grafica.jpg").write("JPG")
    folder.join("altra.png").write("PNG")
    folder.join("_sfondo.png").write("tmp")
    folder.join("script.sh").write("convert …")
  end

  teardown { @conversation.clear_outbox! }

  def run_task(name)
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  end

  test "l'importazione porta i file nelle chat giuste e salta i file intermedi; rilanciata non duplica" do
    output = run_task("assistant:import_files")
    assert_match(/3 file importati, tralasciati: _sfondo.png, script.sh/, output)
    assert_equal %w[appunti.txt], @user.files.map { |f| f.filename.to_s }
    assert_equal %w[grafica.jpg], @first.files.map { |f| f.filename.to_s }, "sul messaggio che la propone"
    assert_equal %w[altra.png], @last.files.map { |f| f.filename.to_s }, "le altre sull'ultima risposta"

    assert_no_difference -> { ActiveStorage::Attachment.count } do
      run_task("assistant:import_files")
    end
  end

  test "una chat vecchia mandata avanti senza importazione non perde i file: si importano prima di svuotare" do
    known = @conversation.prepare_outbox!
    assert_equal %w[altra.png appunti.txt grafica.jpg], known.keys.sort
    assert_equal %w[grafica.jpg], @first.reload.files.map { |f| f.filename.to_s }
    assert_equal "JPG", @conversation.outbox.join("grafica.jpg").read, "e Claude la ritrova nella cartella"
  end

  test "la pulizia cancella solo le chat senza post più vecchie del limite" do
    vecchia = AssistantConversation.create!(token: SecureRandom.uuid, updated_at: 20.days.ago)
    recente = AssistantConversation.create!(token: SecureRandom.uuid, updated_at: 2.days.ago)
    output = perform_enqueued_jobs { run_task("assistant:cleanup") }

    assert_match(/più vecchie di 14 giorni: 1/, output)
    assert_not AssistantConversation.exists?(vecchia.id)
    assert AssistantConversation.exists?(recente.id)
    assert AssistantConversation.exists?(@conversation.id), "quelle legate a un post restano"
  end
end
