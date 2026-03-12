json.extract! offer, :id, :property_id, :user_id, :offer_type, :amount, :description, :status, :expires_at, :created_at, :updated_at
json.url offer_url(offer, format: :json)
