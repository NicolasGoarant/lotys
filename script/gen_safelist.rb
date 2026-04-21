# script/gen_safelist.rb
#
# Génère app/assets/tailwind/safelist.html.
#
# Objectif : forcer Tailwind v4 JIT à compiler un ensemble de classes
# d'espacement (gap, space-*, m*, p*, max-w-*) qui pourraient sinon
# "tomber" silencieusement du CSS compilé si elles n'apparaissent
# nulle part dans le code au moment du build.
#
# Usage :
#   ruby script/gen_safelist.rb
#
# Pour ajouter/retirer des classes, édite les constantes VALUES,
# SPACING_PREFIXES, BREAKPOINTS ou MAX_W_NAMED ci-dessous et relance.
#
# Trade-off : chaque classe safelistée pèse environ 50-150 bytes dans
# le CSS final. Avec la config actuelle (~2900 classes), on ajoute
# ~300 KB de CSS non compressé (~40 KB gzippé). C'est acceptable pour
# une app Heroku et infiniment préférable au risque de bugs visuels
# silencieux.

# Valeurs d'espacement. Couvre 99% des cas design.
VALUES = %w[0 0.5 1 1.5 2 2.5 3 3.5 4 5 6 7 8 9 10 11 12 14 16 20 24 28 32 36 40]

# Prefixes d'espacement (margin, padding, gap, space-between)
SPACING_PREFIXES = %w[
  m mx my mt mb ml mr
  p px py pt pb pl pr
  gap gap-x gap-y
  space-x space-y
]

# Breakpoints responsive à prendre en charge
BREAKPOINTS = %w[sm md lg xl 2xl]

# Valeurs nommées pour max-width (conteneurs)
MAX_W_NAMED = %w[xs sm md lg xl 2xl 3xl 4xl 5xl 6xl 7xl none full]

classes = []

SPACING_PREFIXES.each do |prefix|
  VALUES.each do |val|
    classes << "#{prefix}-#{val}"
    BREAKPOINTS.each { |bp| classes << "#{bp}:#{prefix}-#{val}" }
  end
end

MAX_W_NAMED.each do |name|
  classes << "max-w-#{name}"
  BREAKPOINTS.each { |bp| classes << "#{bp}:max-w-#{name}" }
end

classes.uniq!

# Chemin de sortie relatif au root du projet Rails
output_path = File.expand_path("../app/assets/tailwind/safelist.html", __dir__)

html = <<~HTML
  <!--
    Ce fichier n'est PAS rendu dans les layouts. Son seul but est d'être
    scanné par Tailwind pour forcer la compilation des classes listées
    dedans, afin d'éviter que des classes d'espacement utilisées dans les
    vues (gap-14, space-y-10, etc.) ne disparaissent silencieusement du
    CSS compilé parce qu'elles n'apparaissent nulle part ailleurs dans le
    code au moment du build.

    Pour lancer un audit des classes utilisées mais non compilées :
      bin/rails runner script/audit_tailwind.rb

    Pour régénérer ce fichier après avoir ajusté la safelist :
      ruby script/gen_safelist.rb

    Classes safelistées : #{classes.size}
    Généré automatiquement — ne pas éditer à la main.
  -->
HTML

classes.each_slice(50) do |group|
  html += %(<div class="#{group.join(' ')}"></div>\n)
end

File.write(output_path, html)
puts "✅ #{classes.size} classes écrites dans #{output_path}"
puts "   Taille : #{File.size(output_path)} bytes"
puts
puts "N'oublie pas de rebuilder le CSS après cette génération :"
puts "   bin/rails tailwindcss:build"
puts "Ou en dev, relance bin/dev qui lancera tailwindcss:watch."
