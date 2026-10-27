# Comandi di sola lettura per l'assistente della chat: gli fanno vedere i post nel database
# senza dargli modo di modificarli.
namespace :assistant do
  desc "Elenco dei post (per l'assistente): id, stato, data, titolo"
  task posts: :environment do
    Post.newest_first.each do |post|
      date = post.publish_at ? I18n.l(post.publish_at, format: :short) : "senza data"
      puts [ post.id, post.status, date, post.title ].join(" | ")
    end
  end

  desc "Un post completo in JSON (per l'assistente): bin/rails assistant:post ID=12"
  task post: :environment do
    post = Post.includes(publications: :social_page).find(ENV.fetch("ID"))
    data = {
      id: post.id, title: post.title, status: post.status,
      publish_at: post.publish_at&.iso8601, body: post.body, notes: post.notes,
      social_pages: post.publications.map { |p| { name: p.social_page.name, platform: p.social_page.platform,
                                                   online: p.on_social?, url: p.remote_url, error: p.sync_error } },
      media: post.ordered_media.map { |m| { filename: m.filename.to_s, content_type: m.content_type,
                                             path: ActiveStorage::Blob.service.path_for(m.blob.key) } }
    }
    puts JSON.pretty_generate(data)
  rescue KeyError
    abort "Indica il post: bin/rails assistant:post ID=12"
  rescue ActiveRecord::RecordNotFound
    abort "Nessun post con id #{ENV['ID']}."
  end
end
