# script/audit_tailwind.rb
#
# Audite les classes Tailwind utilisées dans les vues vs celles compilées
# dans app/assets/builds/tailwind.css.
#
# Objectif : détecter silencieusement les classes qu'un développeur a écrites
# mais qui ne sont pas compilées dans le CSS final (et tombent donc à zéro
# au rendu). C'est exactement le bug qu'on a rencontré sur Lauze avec
# space-y-10, gap-14, space-y-28.
#
# Usage :
#   bin/rails runner script/audit_tailwind.rb
#
# Le script ne casse jamais la CI : il retourne 0 dans tous les cas. Il sert
# à signaler, pas à bloquer. Pour une intégration plus stricte en CI, wrapper
# dans un script qui `exit 1` si la sortie contient "⚠️".

require "set"

# ─── Fichiers scannés ────────────────────────────────────────────────
# Tout ce qui peut contenir des classes Tailwind dans l'app Rails.
VIEW_GLOBS = [
  Rails.root.join("app/views/**/*.erb"),
  Rails.root.join("app/views/**/*.html"),
  Rails.root.join("app/helpers/**/*.rb"),
  Rails.root.join("app/components/**/*.{rb,erb}"),
  Rails.root.join("app/javascript/**/*.{js,jsx,ts,tsx}"),
  Rails.root.join("app/controllers/**/*.rb")
]

TAILWIND_BUILD = Rails.root.join("app/assets/builds/tailwind.css")
SAFELIST_FILE  = Rails.root.join("app/assets/tailwind/safelist.html")

# ─── Fichiers à ignorer ──────────────────────────────────────────────
# On ne veut pas que safelist.html gonfle artificiellement la liste des
# "classes utilisées" — par définition c'est une liste de classes à forcer.
IGNORE_PATHS = [SAFELIST_FILE.to_s].freeze

# ─── Extraction des classes dans les vues ───────────────────────────
# Regex volontairement simple : cible class="..." et class: "..." en ERB.
# Rate les classes dynamiques (interpolations) mais détecte 95% des cas.
CLASS_ATTR_RE  = /class\s*[:=]\s*["']([^"']+)["']/
# Classe Tailwind "plausible" : commence par une lettre, contient lettres/
# chiffres/tirets/deux-points/slash/crochets/points. Filtre les noms de
# classes applicatives trop farfelues.
TAILWIND_RE    = /\A-?(?:[a-z]+:)*-?[a-z][a-z0-9_\-\/:\[\]\.\%]*\z/i

def extract_classes_from_file(path)
  content = File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
  classes = Set.new
  content.scan(CLASS_ATTR_RE).each do |(class_attr)|
    class_attr.split(/\s+/).each do |cls|
      cls = cls.strip
      next if cls.empty?
      next unless cls.match?(TAILWIND_RE)
      classes << cls
    end
  end
  classes
rescue => e
  warn "⚠️  Lecture échouée sur #{path} : #{e.message}"
  Set.new
end

# ─── Extraction des classes compilées dans tailwind.css ─────────────
# Les classes CSS sont préfixées par un point et peuvent contenir des
# backslashes (échappement de ":" pour les variants, de "." pour les
# valeurs décimales, de "/" pour les modificateurs).
COMPILED_CLASS_RE = /\.((?:[\w\-]|\\[:.\/\[\]%])+)(?=[\s,:>{\[.])/

def extract_compiled_classes(css_path)
  css = File.read(css_path)
  classes = Set.new
  css.scan(COMPILED_CLASS_RE).each do |(name)|
    # Un-escape : "md\\:gap-4" -> "md:gap-4"
    unescaped = name.gsub(/\\(.)/, '\1')
    classes << unescaped
  end
  classes
end

# ─── Exécution ──────────────────────────────────────────────────────
puts "Audit Tailwind — #{Time.current.strftime("%Y-%m-%d %H:%M")}"
puts "─" * 70

unless File.exist?(TAILWIND_BUILD)
  puts "❌ Fichier CSS compilé introuvable : #{TAILWIND_BUILD}"
  puts "   Lance d'abord : bin/rails tailwindcss:build"
  exit 0
end

used = Set.new
files_scanned = 0
VIEW_GLOBS.each do |glob|
  Dir.glob(glob).each do |path|
    next if IGNORE_PATHS.include?(path)
    used.merge(extract_classes_from_file(path))
    files_scanned += 1
  end
end
puts "Fichiers scannés : #{files_scanned}"
puts "Classes distinctes écrites : #{used.size}"

compiled = extract_compiled_classes(TAILWIND_BUILD)
puts "Classes compilées dans tailwind.css : #{compiled.size}"
puts

# Diff : utilisées mais pas compilées
missing = used - compiled
# Filtre : on ignore les classes purement applicatives qui n'ont aucune
# chance d'être du Tailwind (pas de prefix connu et pas de tiret).
TAILWIND_PREFIXES = %w[
  bg- text- border- p- px- py- pt- pb- pl- pr- m- mx- my- mt- mb- ml- mr-
  w- h- min-w- min-h- max-w- max-h- gap- gap-x- gap-y- space-x- space-y-
  flex justify- items- self- content- font- leading- tracking-
  rounded ring- shadow- cursor- opacity- z- top- left- right- bottom- inset-
  grid grid-cols- grid-rows- col- row- order-
  divide- hover: focus: active: disabled: group-hover: sm: md: lg: xl: 2xl:
  relative absolute fixed sticky static block inline hidden
  transition duration- ease- transform rotate- scale- translate-
  overflow- object- align- vertical- whitespace- break-
  uppercase lowercase capitalize italic underline
  from- to- via- bg-gradient- backdrop- antialiased
  origin- outline- pointer-events-
]

def looks_tailwindish?(cls)
  TAILWIND_PREFIXES.any? { |p| cls.start_with?(p) }
end

missing_tailwindish = missing.select { |c| looks_tailwindish?(c) }.sort

if missing_tailwindish.empty?
  puts "✅ Aucune classe Tailwind utilisée n'est manquante du CSS compilé."
else
  puts "⚠️  #{missing_tailwindish.size} classe(s) utilisée(s) mais NON compilée(s) :"
  puts
  missing_tailwindish.each { |c| puts "   - #{c}" }
  puts
  puts "Ces classes tomberont à zéro au rendu. Deux options pour fixer :"
  puts "  1. Les ajouter à la safelist (édite script/gen_safelist.rb et relance)."
  puts "  2. Les utiliser quelque part dans une vue 'sentinel' pour que Tailwind"
  puts "     les scanne automatiquement au prochain build."
end

puts
puts "Pour info — safelist.html :"
if File.exist?(SAFELIST_FILE)
  safelist_classes = extract_classes_from_file(SAFELIST_FILE).size
  puts "  ✓ Présent (#{safelist_classes} classes)"
else
  puts "  ✗ Absent — lance 'ruby script/gen_safelist.rb' pour le générer."
end

exit 0
