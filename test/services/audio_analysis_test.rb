require "test_helper"

class AudioAnalysisTest < ActiveSupport::TestCase
  setup { skip "ffmpeg non installato" unless system("which ffmpeg > /dev/null 2>&1") }

  def synth(expression, seconds)
    path = Rails.root.join("tmp", "analisi-#{SecureRandom.hex(4)}.mp3").to_s
    system("ffmpeg", "-v", "error", "-f", "lavfi", "-i", "aevalsrc='#{expression}':s=44100:d=#{seconds}",
           "-metadata", "title=Prova", "-y", path, exception: true)
    (@files ||= []) << path
    path
  end

  teardown { Array(@files).each { |f| File.delete(f) if File.exist?(f) } }

  test "durata, informazioni del file e volume nel tempo" do
    path = synth("sin(2*PI*440*t)*min(1\\,0.1+t/10)", 20)
    result = AudioAnalysis.new(path, ".mp3").call

    assert_in_delta 20, result.duration, 0.2
    assert_equal "Prova", result.tags["title"]
    assert result.segments.size >= 3
    assert result.segments.first[:lufs] < result.segments.last[:lufs], "il brano cresce"
    text = result.to_prompt
    assert_match "Durata: 0:20", text
    assert_match "Volume nel tempo", text
  end

  test "stima il tempo di un ritmo chiaro, e non ne inventa uno dove non c'è" do
    beat = AudioAnalysis.new(synth("sin(2*PI*440*t)*lt(mod(t\\,0.5)\\,0.06)", 20), ".mp3").call
    assert_in_delta 120, beat.bpm, 8

    held = AudioAnalysis.new(synth("0.5*sin(2*PI*440*t)", 15), ".mp3").call
    assert_nil held.bpm
  end

  test "solo formati audio ammessi" do
    assert_raises(ArgumentError) { AudioAnalysis.new("/x/y.txt", ".txt") }
  end
end
