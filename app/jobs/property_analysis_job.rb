class PropertyAnalysisJob < ApplicationJob
  queue_as :analysis

  def perform(property_id)
    property = Property.find(property_id)

    property.update(status: :analyzing)
    GeocodingService.new(property).call

    property.documents.each do |doc|
      DocumentAnalysisService.new(doc).call if doc.file.attached?
    end

    PropertyDataExtractorService.new(property).call
    DvfEstimationService.new(property).call
    DeviceSimulationService.new(property).call
    PropertyAnalysisService.new(property).call
    LocalAidCalculator.new(property).call
    sync_analysis_fields(property)

    property.update(status: :analyzed)

  rescue => e
    Rails.logger.error("PropertyAnalysisJob ##{property_id} failed: #{e.message}")
    property&.update(status: :draft)
    raise
  end

  private

  def sync_analysis_fields(property)
    return unless property.analysis&.content.present?
    parsed = JSON.parse(property.analysis.content) rescue nil
    return unless parsed

    updates = {}
    if property.dpe_target.blank?
      dpe_cible = parsed.dig("energie", "dpe_cible")&.upcase
      updates[:dpe_target] = dpe_cible if dpe_cible.in?(%w[A B C D E F G])
    end
    if property.dpe_class.blank?
      dpe_estime = parsed.dig("energie", "dpe_estime")&.upcase
      updates[:dpe_class] = dpe_estime if dpe_estime.in?(%w[A B C D E F G])
    end
    property.update(updates) if updates.any?
  end
end
