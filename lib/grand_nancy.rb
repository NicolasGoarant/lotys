# Source de vérité unique pour la composition de la Métropole du Grand Nancy.
#
# Liste des 20 communes membres avec leur code INSEE, récupérée depuis l'API
# officielle Géo Etalab (data.gouv.fr) :
#   https://geo.api.gouv.fr/epcis/245400676/communes
#
# 245400676 est le SIREN de l'EPCI "Métropole du Grand Nancy".
#
# La composition peut évoluer par avenant (entrée/sortie de communes).
# Pour rafraîchir et comparer à l'API : `rake grand_nancy:refresh`.
#
# Dernier rafraîchissement vérifié contre l'API : 2026-06-06.
module GrandNancy
  COMMUNES = {
    "54025" => "Art-sur-Meurthe",
    "54165" => "Dommartemont",
    "54184" => "Essey-lès-Nancy",
    "54197" => "Fléville-devant-Nancy",
    "54257" => "Heillecourt",
    "54265" => "Houdemont",
    "54274" => "Jarville-la-Malgrange",
    "54300" => "Laneuveville-devant-Nancy",
    "54304" => "Laxou",
    "54328" => "Ludres",
    "54339" => "Malzéville",
    "54357" => "Maxéville",
    "54395" => "Nancy",
    "54439" => "Pulnoy",
    "54482" => "Saint-Max",
    "54495" => "Saulxures-lès-Nancy",
    "54498" => "Seichamps",
    "54526" => "Tomblaine",
    "54547" => "Vandœuvre-lès-Nancy",
    "54578" => "Villers-lès-Nancy"
  }.freeze

  COMMUNE_INSEE_CODES = COMMUNES.keys.freeze

  def self.include?(insee_code)
    COMMUNE_INSEE_CODES.include?(insee_code.to_s)
  end
end
