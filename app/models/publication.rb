# Il collegamento fra un post e una pagina social su cui esce,
# con l'id del post sul social e l'esito dell'ultima sincronizzazione.
class Publication < ApplicationRecord
  belongs_to :post
  belongs_to :social_page

  validates :social_page_id, uniqueness: { scope: :post_id }

  def on_social? = remote_id.present?

  def remote_url
    return unless on_social?

    case social_page.platform
    when "facebook" then "https://www.facebook.com/#{remote_id}"
    end
  end

  def record_result!(result, post, now: Time.current)
    update!(remote_id: result.remote_id, remote_kind: result.remote_kind,
            remote_media_ids: result.remote_media_ids,
            synced_media_order: post.ordered_media.map(&:blob_id),
            synced_at: now, sync_error: nil)
  end

  def clear_remote!
    update!(remote_id: nil, remote_kind: nil, remote_media_ids: [], synced_media_order: [], synced_at: nil, sync_error: nil)
  end
end
