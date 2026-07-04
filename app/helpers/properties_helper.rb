module PropertiesHelper
  def status_badge_class(status)
    case status
    when "draft"      then "bg-gray-100 text-gray-600"
    when "analyzing"  then "bg-yellow-100 text-yellow-700"
    when "analyzed"   then "bg-blue-100 text-blue-700"
    when "published"  then "bg-emerald-100 text-emerald-700"
    else "bg-gray-100 text-gray-600"
    end
  end

  # Libellé humain d'address_source (C5 bandeau de confirmation).
  # "manuel" n'est pas listé : l'utilisateur qui a saisi lui-même ne
  # voit jamais le bandeau — address_confirmed_at est posé au create
  # (cf. PropertiesController#prepare_address_flow, C2).
  def t_address_source(source)
    case source.to_s
    when "dpe"             then "votre DPE"
    when "titre_propriete" then "votre titre de propriété"
    when "facture"         then "votre facture d'énergie (lieu de consommation)"
    else                        "vos documents"
    end
  end
end
