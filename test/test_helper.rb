ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Parallélise avec le nombre de CPU du poste.
    parallelize(workers: :number_of_processors)

    # Fixtures non utilisées pour le moment — les tests de services
    # construisent des objets en mémoire via Model.new pour rester
    # découplés de la DB. À activer quand on introduira des tests
    # qui touchent à Property#save, has_many, etc.
    # fixtures :all
  end
end
