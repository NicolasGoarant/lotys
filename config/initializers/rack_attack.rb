class Rack::Attack

  # Cache store
  Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

  # Bloquer les IPs qui font trop de requêtes
  throttle("req/ip", limit: 300, period: 5.minutes) do |req|
    req.ip
  end

  # Max 5 analyses par heure par IP
  throttle("analyses/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.path.include?("/analyze") && req.post?
  end

  # Max 3 créations de bien par heure par IP
  throttle("properties/ip", limit: 3, period: 1.hour) do |req|
    req.ip if req.path == "/properties" && req.post?
  end

  # Max 10 inscriptions par heure par IP
  throttle("registrations/ip", limit: 10, period: 1.hour) do |req|
    req.ip if req.path.include?("/users") && req.post?
  end

  # Réponse en cas de blocage
  self.throttled_responder = lambda do |env|
    [
      429,
      { "Content-Type" => "text/html; charset=utf-8" },
      ["<html><body style='font-family:sans-serif;text-align:center;padding:60px'>
        <h1 style='color:#059669'>Lauze</h1>
        <h2>Trop de requêtes</h2>
        <p>Vous avez dépassé la limite autorisée. Veuillez réessayer dans quelques minutes.</p>
        <a href='/'>← Retour</a>
      </body></html>"]
    ]
  end
end
