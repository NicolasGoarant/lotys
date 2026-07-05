# Représente un EPCI (Métropole, Communauté d'agglomération, …) qui a
# activé un portail Lauze pour ses habitants. Feature "portail
# collectivité" (niveau 1 B2G).
#
# Un portail = une page publique à l'URL /collectivites/:slug qui affiche
# le branding de la collectivité (nom, logo, couleur primaire, mot
# d'accueil) et propose le parcours d'analyse pré-paramétré. Les biens
# créés depuis ce portail sont rattachés via Property#collectivite_id,
# à la condition que leur adresse confirmée tombe dans le ressort
# territorial (cf. covers_insee?). Sinon le rattachement est reseté à
# NULL (garde-fou en C6) — principe projet : pas de caution d'une
# collectivité sur un bien hors de son territoire.
class Collectivite < ApplicationRecord
  has_many :properties, dependent: :nullify

  # Logo affiché en tête du portail. Optionnel : le fallback initiales
  # sur fond primary_color est géré côté vue quand aucun logo n'est
  # attaché (permet de seeder et déployer une démo sans passer par
  # l'upload en console).
  has_one_attached :logo

  # ── Validations ─────────────────────────────────────────────────────
  validates :name, presence: true

  # Slug URL : kebab-case strict (a-z, 0-9, -). Unique pour identifier
  # de manière fiable un portail via GET /collectivites/:slug. Le format
  # évite les collisions et les injections URL.
  validates :slug,
            presence: true,
            uniqueness: true,
            format: {
              with: /\A[a-z0-9]+(-[a-z0-9]+)*\z/,
              message: "doit être en kebab-case (a-z, 0-9, tirets — pas d'espace ni de tiret en début/fin)"
            }

  # Couleur primaire de la charte visuelle du portail — hex #RRGGBB.
  # Les nuances (hover, badge) sont dérivées côté CSS via filter/opacity.
  validates :primary_color,
            presence: true,
            format: {
              with: /\A#[0-9a-fA-F]{6}\z/,
              message: "doit être une couleur hex #RRGGBB (ex : #0066a1)"
            }

  # insee_codes doit être un array de codes 5 chiffres. Un code invalide
  # rendrait covers_insee? inutile.
  validate :insee_codes_all_five_digits

  # ── Scopes ──────────────────────────────────────────────────────────
  scope :active,   -> { where(active: true) }
  scope :by_slug,  ->(slug) { where(slug: slug) }

  # ── Helpers ─────────────────────────────────────────────────────────

  # Ce bien tombe-t-il dans le ressort de la collectivité ?
  # `code` peut être un string ("54395") ou nil (bien pas encore
  # géocodé → false, on ne PRÉSUME pas d'un rattachement).
  def covers_insee?(code)
    code.present? && insee_codes.include?(code.to_s)
  end

  # Initiales à afficher quand aucun logo n'est attaché.
  # « Métropole du Grand Nancy » → « MGN » ; « ALEC » → « ALEC ».
  # Limitée à 4 caractères pour rester lisible dans le badge.
  def initiales
    words = name.to_s.gsub(/[^A-Za-zÀ-ÿ ]/, "").split(/\s+/)
    if words.size <= 1
      words.first.to_s.upcase[0, 4]
    else
      words.map { |w| w[0] }.join.upcase[0, 4]
    end
  end

  private

  def insee_codes_all_five_digits
    return if insee_codes.blank?

    invalid = Array(insee_codes).reject { |c| c.to_s.match?(/\A\d{5}\z/) }
    return if invalid.empty?

    errors.add(:insee_codes, "contient des codes invalides : #{invalid.inspect} (attendu : 5 chiffres)")
  end
end
