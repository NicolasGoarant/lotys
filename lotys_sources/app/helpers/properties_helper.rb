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
end
