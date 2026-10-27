# Una pagina social gestita per la scuola (oggi solo Facebook).
# Per un nuovo social basta aggiungerlo a PLATFORMS e creare la pagina.
class SocialPage < ApplicationRecord
  PLATFORMS = {
    "facebook" => "Facebook",
    "instagram" => "Instagram"
  }.freeze

  has_many :publications, dependent: :restrict_with_error
  has_many :posts, through: :publications

  # Il token per pubblicare sulla pagina: cifrato nel database, non compare mai nei log.
  encrypts :access_token
  self.filter_attributes += [ :access_token ]

  def connected? = external_id.present? && access_token.present?

  validates :name, :url, presence: true
  validates :url, uniqueness: true
  validates :platform, inclusion: { in: PLATFORMS.keys }

  scope :by_name, -> { order(:platform, :name) }

  def self.ransackable_attributes(_auth_object = nil)
    %w[id name platform]
  end

  def self.ransackable_associations(_auth_object = nil)
    []
  end

  def platform_label = PLATFORMS.fetch(platform, platform)
end
