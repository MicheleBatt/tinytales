require "test_helper"

class PostsReportControllerTest < ActionDispatch::IntegrationTest
  setup do
    travel_to Time.zone.local(2026, 11, 16, 10, 0)
    @printed = []
    PostsReport.printer = lambda do |html_path, pdf_path|
      @printed << File.read(html_path)
      File.write(pdf_path, "%PDF-1.4 finto")
    end
    PostsReport.text_of = ->(_pdf) { [] }
  end

  teardown do
    PostsReport.printer = nil
    PostsReport.text_of = nil
  end

  test "l'homepage ha «Esporta PDF» a destra della musicoteca, con i filtri attivi" do
    get root_path
    buttons = css_select(".azioni-testa a.bottone").map { |a| a.text.strip }
    assert_equal buttons.index("♪ Musicoteca") + 1, buttons.index("⤓ Esporta PDF")
    assert_select "a.bottone-esporta[href=?][data-controller=report-export][data-action='report-export#download']", report_posts_path

    get posts_path, params: { q: { status_eq: "draft", title_or_body_or_notes_cont: "Natale", s: "publish_at asc", ignoto: "x" } }
    href = css_select("a.bottone-esporta").first["href"]
    assert_equal({ "status_eq" => "draft", "title_or_body_or_notes_cont" => "Natale", "s" => "publish_at asc" },
                 Rack::Utils.parse_nested_query(URI(href).query)["q"])
  end

  test "il report si scarica come PDF, con tutti i post" do
    get report_posts_path
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match(/attachment; filename="report-post-scuola-creola-2026-11-16.pdf"/, response.headers["Content-Disposition"])
    assert_equal "%PDF-1.4 finto", response.body
    %w[Open\ Day\ di\ novembre Promemoria\ Open\ Day La\ nostra\ mensa Festa\ di\ Natale].each { |title| assert_includes @printed.last, title }
    assert_includes @printed.last, "nessuno: tutti i post presenti"
  end

  test "il report segue i filtri dell'elenco e li riporta nel frontespizio" do
    get report_posts_path, params: { q: { status_eq: "draft", publish_at_lteq: "2026-11-12" } }
    assert_response :success
    html = @printed.last
    assert_includes html, "La nostra mensa"
    assert_not_includes html, "Festa di Natale", "senza data: escluso dal filtro «al»"
    assert_not_includes html, "Promemoria Open Day"
    assert_includes html, "stato: bozza · al giovedì 12 novembre 2026"
  end

  test "se il PDF non si può fare, arriva un errore leggibile" do
    PostsReport.printer = ->(_html, _pdf) { raise PostsReport::Error, "Chrome non è stato trovato." }
    get report_posts_path
    assert_response :internal_server_error
    assert_equal "Chrome non è stato trovato.", response.parsed_body["error"]
  end
end
