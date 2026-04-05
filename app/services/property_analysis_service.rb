class PropertyAnalysisService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"

  def initialize(property)
    @property = property
  end

  def call
    summaries = @property.documents.processed.map do |doc|
      "**#{doc.document_type.humanize}** : #{doc.ai_summary}"
    end.join("\n\n")

    # Données DVF si disponibles
    dvf_context = if @property.valuation&.dvf_raw.present?
      dvf = @property.valuation.dvf_raw
      "Données DVF réelles (ventes passées dans le secteur) : prix moyen #{dvf['avg_price_sqm']} €/m² sur #{dvf['sample_size']} transactions comparables."
    else
      "Données DVF non disponibles pour ce secteur."
    end

    prompt = <<~PROMPT
      Tu es un conseiller patrimonial expert en immobilier résidentiel français.
      Tu produis des estimations de valeur rigoureuses, ancrées dans les données de marché réelles.

      Voici le dossier d'un bien immobilier :
      - Adresse : #{@property.address}, #{@property.city} (#{@property.zipcode})
      - Surface : #{@property.surface || "inconnue"} m²
      - Année de construction : #{@property.construction_year || "inconnue"}
      - Classe DPE : #{@property.dpe_class || "non renseignée"}
      - Copropriété : #{@property.is_copropriete ? "Oui (#{@property.nb_lots} lots)" : "Non"}
      - #{dvf_context}

      Analyses des documents fournis :
      #{summaries.presence || "Aucun document analysé."}

      Réponds UNIQUEMENT avec un objet JSON valide (pas de markdown, pas de texte avant ou après), structuré exactement ainsi :

      {
        "valeur": {
          "titre": "Valeur du bien aujourd'hui",
          "estimation_basse": 120000,
          "estimation_haute": 145000,
          "prix_acquisition": 149000,
          "analyse": "Texte d'analyse de 3-4 phrases. IMPORTANT : (1) base ton estimation sur le prix au m² réel du secteur AVANT toute décote, puis applique la décote DPE ; (2) n'utilise PAS le prix d'acquisition pour valider ton estimation — ce sont deux choses distinctes ; (3) ne juge pas si le prix d'achat était justifié.",
          "points_cles": ["point 1", "point 2", "point 3"]
        },
        "energie": {
          "titre": "Rénovation énergétique",
          "dpe_estime": "F",
          "dpe_cible": "C",
          "urgence": "haute",
          "analyse": "Texte de 3-4 phrases sur l'état thermique du bien et l'urgence réglementaire.",
          "travaux": [
            {"poste": "Isolation des combles", "priorite": 1, "cout_min": 8000, "cout_max": 15000, "gain_dpe": "+2 classes"},
            {"poste": "Isolation des murs", "priorite": 2, "cout_min": 10000, "cout_max": 25000, "gain_dpe": "+1 classe"},
            {"poste": "Remplacement chauffage", "priorite": 3, "cout_min": 8000, "cout_max": 15000, "gain_dpe": "+1 classe"}
          ],
          "budget_total_min": 26000,
          "budget_total_max": 55000,
          "aides": ["MaPrimeRénov'", "Éco-PTZ", "CEE"]
        },
        "idees": {
          "titre": "Y avez-vous pensé ?",
          "scenarios": [
            {
              "emoji": "☀️",
              "titre": "Panneaux photovoltaïques",
              "description": "Description courte et concrète adaptée à ce bien spécifique.",
              "gain_estime": "300-600€/an",
              "faisabilite": "moyenne"
            },
            {
              "emoji": "🚗",
              "titre": "Borne de recharge électrique",
              "description": "Description courte et concrète.",
              "gain_estime": "+3-5% valeur revente",
              "faisabilite": "haute"
            },
            {
              "emoji": "🏠",
              "titre": "Location meublée (LMNP)",
              "description": "Description courte et concrète.",
              "gain_estime": "+20-30% revenus locatifs",
              "faisabilite": "haute"
            },
            {
              "emoji": "🏗️",
              "titre": "Surélévation / extension",
              "description": "Description courte et concrète adaptée à ce bien.",
              "gain_estime": "+X% surface habitable",
              "faisabilite": "basse"
            },
            {
              "emoji": "🌱",
              "titre": "Jardin partagé ou potager",
              "description": "Description courte et concrète.",
              "gain_estime": "+attractivité locative",
              "faisabilite": "haute"
            },
            {
              "emoji": "📦",
              "titre": "Box de stockage ou cave",
              "description": "Description courte et concrète.",
              "gain_estime": "+50-100€/mois",
              "faisabilite": "moyenne"
            }
          ]
        },
        "profil_extrait": {
          "surface": null,
          "nb_rooms": null,
          "dpe_class": null,
          "property_type": null
        },
        "recommandation": {
          "titre": "Notre recommandation",
          "action_prioritaire": "Texte d'une phrase sur l'action la plus urgente.",
          "horizon_court": "Ce qu'il faut faire dans les 3 prochains mois.",
          "horizon_moyen": "Ce qu'il faut viser à 1-2 ans."
        },
        "scoring": {
          "score_energie": 42,
          "score_patrimonial": 71,
          "analyse": "Explication courte des scores attribués."
        },
        "timeline_travaux": [
          {
            "annee": 2025,
            "actions": ["Audit énergétique", "Isolation des combles"]
          },
          {
            "annee": 2026,
            "actions": ["Remplacement du chauffage"]
          }
        ],
        "projection_valeur": {
          "valeur_actuelle": 210000,
          "valeur_apres_travaux": 265000,
          "gain_valeur": 55000,
          "analyse": "Texte court sur la création de valeur après rénovation."
        }
      }

      Dans profil_extrait, indique les valeurs réelles extraites des documents (surface habitable Carrez en m², nombre de pièces, classe DPE lettre, type appartement/maison).
      Adapte TOUTES les valeurs au bien décrit. Ne génère pas de JSON générique.
      Les scores doivent être réalistes, sur 100, et cohérents avec l'état du bien.
      La timeline travaux doit être ordonnée, crédible, et simple à exécuter.
      La projection de valeur doit être cohérente avec la valeur actuelle et les travaux proposés.

      RÈGLES IMPÉRATIVES POUR L'ESTIMATION DE VALEUR :

      1. MÉTHODE DE CALCUL :
         - Commence par le prix au m² brut du secteur (marché réel, pas les valeurs "bons états")
         - Pour Nancy intra-muros et proches communes : base-toi sur 1 600–2 200 €/m² selon quartier
         - Applique ensuite une seule décote DPE, pas d'autres pénalités cumulées

      2. DÉCOTES DPE RÉALISTES (source : études notariales 2023-2024) :
         - DPE A/B : 0% (prime verte possible +3-5%)
         - DPE C/D : 0% (référence)
         - DPE E : -5 à -8%
         - DPE F maison individuelle hors copro : -8 à -12%
         - DPE F appartement en copro : -12 à -18%
         - DPE G maison individuelle hors copro : -12 à -18%
         - DPE G appartement en copro : -18 à -25%

      3. NE PAS FAIRE :
         - Ne pas commenter si le prix d'acquisition était "au-dessus des fondamentaux" ou "surévalué"
         - Ne pas cumuler décote DPE + pénalité ancienneté + pénalité surface
         - Ne pas appliquer une décote supérieure à 20% sauf cas exceptionnel justifié
         - Ne pas utiliser le prix d'acquisition comme référence pour valider l'estimation

      4. PRÉSENTER SYSTÉMATIQUEMENT :
         - Valeur état actuel (fourchette basse/haute)
         - Valeur potentielle après travaux de rénovation
         - Les deux sont utiles au propriétaire pour décider
    PROMPT

    response = call_claude(prompt)
    analysis = @property.analysis || @property.build_analysis

    parsed = JSON.parse(response) rescue nil

    if parsed
      analysis.update!(
        content: response,
        status: 1,
        score_energie: parsed.dig("scoring", "score_energie"),
        score_patrimonial: parsed.dig("scoring", "score_patrimonial"),
        travaux_timeline: parsed["timeline_travaux"],
        estimated_value_after_works: parsed.dig("projection_valeur", "valeur_apres_travaux"),
        estimated_gain_after_works: parsed.dig("projection_valeur", "gain_valeur")
      )
    else
      analysis.update!(content: response, status: 1)
    end
  end

  private

  def call_claude(prompt)
    response = HTTParty.post(
      ANTHROPIC_API_URL,
      headers: {
        "Content-Type" => "application/json",
        "x-api-key" => ENV["ANTHROPIC_API_KEY"],
        "anthropic-version" => "2023-06-01"
      },
      body: {
        model: "claude-sonnet-4-6",
        max_tokens: 4096,
        messages: [{ role: "user", content: prompt }]
      }.to_json,
      timeout: 300
    )
    JSON.parse(response.body).dig("content", 0, "text")&.gsub(/\A```json\n?|```\z/, "")&.strip
  end
end
