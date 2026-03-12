json.extract! document, :id, :property_id, :document_type, :name, :ai_summary, :processed, :created_at, :updated_at
json.url document_url(document, format: :json)
