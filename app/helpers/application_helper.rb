module ApplicationHelper
end

  def render_markdown(text)
    return "" if text.blank?
    renderer = Redcarpet::Render::HTML.new(filter_html: true, hard_wrap: true)
    markdown = Redcarpet::Markdown.new(renderer, tables: true, fenced_code_blocks: true, no_intra_emphasis: true)
    markdown.render(text).html_safe
  end

  def sentences_to_lines(text)
    return "" if text.blank?
    text.gsub(/\. (?=[A-ZÀ-Ü])/, ".\n")
  end
