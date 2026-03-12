class PropertyAnalysisService
  ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"

  def initialize(property)
    @property = property
  end

  def call
    summaries = @property.documents.processed.map do |doc|
      "**#{doc.document_type.humanize}** : #{doc.ai_summary}"
    end.join("\n\n")

    prompt = <<~PROMPT
      Tu es un conseiller patrimonial expert en immobilier résidentiel français.
      Voici le dossier d'un bien immobilier :
      - Adresse : #{@property.address}, #{@property.city} (#{@property.zipcode})
      - Surface : #{@property.surface || "inconnue"} m²
      - Année de construction : #{@property.construction_year || "inconnue"}
      - Classe DPE : #{@property.dpe_class || "non renseignée"}
      - Copropriété : #{@property.is_copropriete ? "Oui (#{@property.nb_lots} lots)" : "Non"}

      Analyses des documents fournis :
      #{summaries.presence || "Aucun document analysé."}

      Réponds UNIQUEMENT avec un objet JSON valide (pas de markdown, pas de texte avant ou après), structuré exactement ainsi :

      {
        "valeur": {
          "titre": "Valeur du bien aujourd'hui",
          "estimation_basse": 120000,
          "estimation_haute": 145000,
          "prix_acquisition": 149000,
          "analyse": "Texte d'analyse de 3-4 phrases sur la valeur actuelle, l'évolution du marché nancéien, et la plus-value latente.",
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
        }
      }

      Dans profil_extrait, indique les valeurs réelles extraites des documents (surface habitable Carrez en m², nombre de pièces, classe DPE lettre, type appartement/maison).
      Adapte TOUTES les valeurs au bien décrit. Ne génère pas de JSON générique.
    PROMPT

    response = call_claude(prompt)
    analysis = @property.analysis || @property.build_analysis

    # Tente de parser le JSON, sinon stocke en texte brut
    parsed = JSON.parse(response) rescue nil
    if parsed
      analysis.update!(content: response, status: 1)
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
