module ApplicationHelper
end

  def render_markdown(text)
    return "" if text.blank?
    renderer = Redcarpet::Render::HTML.new(filter_html: true, hard_wrap: true)
    markdown = Redcarpet::Markdown.new(renderer, tables: true, fenced_code_blocks: true, no_intra_emphasis: true)
    markdown.render(text).html_safe
  end
