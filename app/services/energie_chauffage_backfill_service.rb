# Backfill energie_chauffage sur les Property antérieurs à la migration
# qui ont une description grepable mais energie_chauffage="inconnue" en
# colonne (la migration `add_energie_chauffage_to_properties` a posé
# "inconnue" par défaut sans rejouer l'extraction).
#
# Réutilise HeatingEnergyNormalizer tel quel — source de vérité unique de
# la table libellé→énergie, jamais redéfinie ici. Respecte la hiérarchie
# Property::ENERGIE_SOURCE_HIERARCHIE : seul :extrait_description peut
# remplir un :inconnue. :extrait_dpe, :confirme_utilisateur, ou même un
# :extrait_description déjà posé ne sont JAMAIS écrasés (upgrade_energie_source?).
#
# Idempotent : un deuxième passage ne change rien (les biens basculés ont
# désormais source :extrait_description, et upgrade_energie_source?(:extrait_description,
# :extrait_description) = false).
#
# Invocation : `bin/rake lauze:backfill_energie_chauffage` (cf. lib/tasks/).
# Test : test/services/energie_chauffage_backfill_service_test.rb.
class EnergieChauffageBackfillService
  def self.call(scope = nil)
    new(scope).call
  end

  def initialize(scope = nil)
    @scope = scope || Property.all
  end

  def call
    rapport = {
      scannes:                       0,
      basculs:                       [],
      inchanges_source_plus_fiable:  [],
      restent_inconnues:             []
    }

    @scope.find_each do |p|
      rapport[:scannes] += 1
      classifier(p, rapport)
    end

    rapport
  end

  private

  def classifier(property, rapport)
    # Pas d'écrasement d'une source plus fiable que :extrait_description.
    unless Property.upgrade_energie_source?(property.energie_chauffage_source, "extrait_description")
      rapport[:inchanges_source_plus_fiable] << {
        id:              property.id,
        source_actuelle: property.energie_chauffage_source
      }
      return
    end

    libelle = extraire_libelle_chauffage(property.description.to_s)
    energie = HeatingEnergyNormalizer.call(libelle)

    if energie == :inconnue
      rapport[:restent_inconnues] << property.id
      return
    end

    property.update!(
      energie_chauffage:        energie.to_s,
      energie_chauffage_source: "extrait_description"
    )
    rapport[:basculs] << {
      id:             property.id,
      energie:        energie.to_s,
      source_avant:   property.energie_chauffage_source_was || "inconnue",
      libelle_matche: libelle
    }
  end

  # Format structuré posé historiquement par PropertyDataExtractorService :
  #   "Chauffage : Chaudière gaz ancienne | Isolation murs : … | Prix : …"
  # Quand ce préfixe est présent, on isole le segment pour ne pas que des
  # mots-clés d'un autre poste (« gaz » dans « Cuisinière au gaz » d'une
  # description libre, par exemple) parasitent le matching.
  # Sinon on retombe sur la description entière — HeatingEnergyNormalizer
  # accepte tout libellé et applique ses regex (cf. cas ID 64 « Appartement
  # hérité… Chauffage au fioul collectif »).
  def extraire_libelle_chauffage(desc)
    if (m = desc.match(/Chauffage\s*:\s*([^|]+)/i))
      m[1].strip
    else
      desc
    end
  end
end
