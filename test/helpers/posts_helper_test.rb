require "test_helper"

class PostsHelperTest < ActionView::TestCase
  test "nei messaggi le pagine sono indicate per piattaforma, con la preposizione giusta" do
    post = posts(:mensa) # solo Facebook
    assert_equal "sulla pagina Facebook", social_pages_phrase(post)
    assert_equal "dalla pagina Facebook", social_pages_phrase(post, from: true)

    post.social_pages << social_pages(:instagram)
    post.reload
    assert_equal "sulle pagine Facebook e Instagram", social_pages_phrase(post)
    assert_equal "dalle pagine Facebook e Instagram", social_pages_phrase(post, from: true)

    assert_equal "su nessuna pagina social", social_pages_phrase(Post.new(title: "Vuoto"))
  end
end
