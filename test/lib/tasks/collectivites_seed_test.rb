require "test_helper"
require "rake"

# Tests de la rake task collectivites:seed (feature portail EPCI, C3).
class CollectivitesSeedTest < ActiveSupport::TestCase
  setup do
    # Charger toutes les tâches Rake une seule fois par processus.
    Rails.application.load_tasks unless Rake::Task.task_defined?("collectivites:seed")
    @task = Rake::Task["collectivites:seed"]
    @task.reenable  # rejouable dans le même processus
  end

  test "seed crée Grand Nancy avec les 20 codes INSEE depuis GrandNancy::COMMUNE_INSEE_CODES" do
    refute Collectivite.exists?(slug: "grand-nancy"), "État initial : pas de portail"

    silence_stream(:stdout) { @task.invoke }

    c = Collectivite.find_by!(slug: "grand-nancy")
    assert_equal "Métropole du Grand Nancy", c.name
    assert_equal 20, c.insee_codes.size,
      "Doit contenir les 20 communes de la Métropole (source : GrandNancy::COMMUNE_INSEE_CODES)"
    assert c.active
    assert_equal GrandNancy::COMMUNE_INSEE_CODES.sort, c.insee_codes.sort,
      "insee_codes doivent MATCHER GrandNancy::COMMUNE_INSEE_CODES (source unique de vérité)"
  end

  test "seed idempotent — deuxième invocation ne duplique pas" do
    silence_stream(:stdout) { @task.invoke }
    initial_id = Collectivite.find_by!(slug: "grand-nancy").id

    @task.reenable
    silence_stream(:stdout) { @task.invoke }

    assert_equal 1, Collectivite.where(slug: "grand-nancy").count
    assert_equal initial_id, Collectivite.find_by!(slug: "grand-nancy").id,
      "Le même enregistrement doit être conservé"
  end

  test "seed préserve les édits admin sur welcome_text et primary_color" do
    silence_stream(:stdout) { @task.invoke }
    c = Collectivite.find_by!(slug: "grand-nancy")
    c.update!(welcome_text: "Édité par l'admin", primary_color: "#ff0000")

    @task.reenable
    silence_stream(:stdout) { @task.invoke }
    c.reload

    assert_equal "Édité par l'admin", c.welcome_text,
      "Les édits admin ne doivent PAS être écrasés au ré-run"
    assert_equal "#ff0000", c.primary_color
  end

  test "seed resynchronise insee_codes si GrandNancy a évolué (source de vérité)" do
    silence_stream(:stdout) { @task.invoke }
    c = Collectivite.find_by!(slug: "grand-nancy")
    # Simule une divergence (ex : commune retirée manuellement en base).
    c.update_columns(insee_codes: %w[54395])

    @task.reenable
    silence_stream(:stdout) { @task.invoke }
    c.reload

    assert_equal 20, c.insee_codes.size,
      "Doit se re-synchroniser sur GrandNancy::COMMUNE_INSEE_CODES"
  end

  private

  def silence_stream(stream)
    orig = case stream
           when :stdout then $stdout
           when :stderr then $stderr
           end
    dummy = File.open(File::NULL, "w")
    case stream
    when :stdout then $stdout = dummy
    when :stderr then $stderr = dummy
    end
    yield
  ensure
    case stream
    when :stdout then $stdout = orig
    when :stderr then $stderr = orig
    end
    dummy&.close
  end
end
