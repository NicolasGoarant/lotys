# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_04_18_160000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "aid_rules", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "aid_type"
    t.string "territory"
    t.text "description"
    t.jsonb "conditions", default: {}
    t.string "amount_type"
    t.decimal "amount_value", precision: 10, scale: 2
    t.decimal "amount_max", precision: 10, scale: 2
    t.decimal "amount_min", precision: 10, scale: 2
    t.string "amount_base"
    t.text "amount_notes"
    t.date "valid_from", null: false
    t.date "valid_until"
    t.boolean "active", default: true
    t.string "source_url"
    t.string "source_label"
    t.integer "priority", default: 0
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_aid_rules_on_slug", unique: true
    t.index ["territory", "aid_type", "active"], name: "index_aid_rules_on_territory_and_aid_type_and_active"
  end

  create_table "analyses", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "analysis_type"
    t.text "content"
    t.text "recommendations"
    t.jsonb "raw_response"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "score_energie"
    t.integer "score_patrimonial"
    t.jsonb "travaux_timeline"
    t.integer "estimated_value_after_works"
    t.integer "estimated_gain_after_works"
    t.index ["property_id"], name: "index_analyses_on_property_id"
  end

  create_table "device_simulations", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.boolean "eligible_eco_ptz"
    t.integer "eco_ptz_max_amount"
    t.boolean "eligible_maprimrenov"
    t.integer "maprimrenov_amount"
    t.boolean "eligible_cee"
    t.integer "cee_estimated_amount"
    t.integer "total_aid_estimate"
    t.text "notes"
    t.jsonb "simulation_data"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id"], name: "index_device_simulations_on_property_id"
  end

  create_table "documents", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.integer "document_type"
    t.string "name"
    t.text "ai_summary"
    t.boolean "processed"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id"], name: "index_documents_on_property_id"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "description"
    t.jsonb "serialized_properties"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_discard"
    t.text "callback_queue_name"
    t.integer "callback_priority"
    t.datetime "enqueued_at"
    t.datetime "discarded_at"
    t.datetime "finished_at"
    t.datetime "jobs_finished_at"
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id", null: false
    t.text "job_class"
    t.text "queue_name"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.text "error"
    t.integer "error_event", limit: 2
    t.text "error_backtrace", array: true
    t.uuid "process_id"
    t.interval "duration"
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "state"
    t.integer "lock_type", limit: 2
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "key"
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "queue_name"
    t.integer "priority"
    t.jsonb "serialized_params"
    t.datetime "scheduled_at"
    t.datetime "performed_at"
    t.datetime "finished_at"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "active_job_id"
    t.text "concurrency_key"
    t.text "cron_key"
    t.uuid "retried_good_job_id"
    t.datetime "cron_at"
    t.uuid "batch_id"
    t.uuid "batch_callback_id"
    t.boolean "is_discrete"
    t.integer "executions_count"
    t.text "job_class"
    t.integer "error_event", limit: 2
    t.text "labels", array: true
    t.uuid "locked_by_id"
    t.datetime "locked_at"
    t.integer "lock_type", limit: 2
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key", "created_at"], name: "index_good_jobs_on_concurrency_key_and_created_at"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at_only", where: "(finished_at IS NOT NULL)"
    t.index ["job_class"], name: "index_good_jobs_on_job_class"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_for_candidate_dequeue_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["priority", "scheduled_at", "id"], name: "index_good_jobs_on_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at", "id"], name: "index_good_jobs_on_queue_name_priority_scheduled_at_unfinished", where: "(finished_at IS NULL)"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "local_aid_results", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.bigint "local_aid_scheme_id", null: false
    t.boolean "eligible", default: false, null: false
    t.string "ineligibility_reason"
    t.jsonb "amounts", default: {}
    t.datetime "computed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["eligible"], name: "index_local_aid_results_on_eligible"
    t.index ["local_aid_scheme_id"], name: "index_local_aid_results_on_local_aid_scheme_id"
    t.index ["property_id", "local_aid_scheme_id"], name: "index_local_aid_results_on_property_id_and_local_aid_scheme_id", unique: true
    t.index ["property_id"], name: "index_local_aid_results_on_property_id"
  end

  create_table "local_aid_schemes", force: :cascade do |t|
    t.string "name", null: false
    t.string "territory", null: false
    t.string "aid_type", null: false
    t.jsonb "zipcodes", default: []
    t.jsonb "property_types"
    t.decimal "rate_tres_modeste", precision: 5, scale: 2
    t.decimal "rate_modeste", precision: 5, scale: 2
    t.decimal "rate_intermediaire", precision: 5, scale: 2
    t.decimal "rate_superieur", precision: 5, scale: 2
    t.integer "max_tres_modeste"
    t.integer "max_modeste"
    t.integer "max_intermediaire"
    t.integer "max_superieur"
    t.jsonb "forfait_data"
    t.text "conditions_text"
    t.text "warning_text"
    t.string "contact_name"
    t.string "contact_url"
    t.string "source_url"
    t.string "source_label"
    t.date "valid_from"
    t.date "valid_until"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_local_aid_schemes_on_active"
    t.index ["territory"], name: "index_local_aid_schemes_on_territory"
    t.index ["zipcodes"], name: "index_local_aid_schemes_on_zipcodes", using: :gin
  end

  create_table "offers", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.bigint "user_id", null: false
    t.integer "offer_type"
    t.integer "amount"
    t.text "description"
    t.integer "status"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id"], name: "index_offers_on_property_id"
    t.index ["user_id"], name: "index_offers_on_user_id"
  end

  create_table "properties", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "address"
    t.string "city"
    t.string "zipcode"
    t.integer "surface"
    t.string "property_type"
    t.integer "construction_year"
    t.string "dpe_class"
    t.integer "nb_rooms"
    t.integer "nb_lots"
    t.boolean "is_copropriete"
    t.text "description"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "vacant"
    t.string "source"
    t.string "vacancy_duration"
    t.string "vacancy_reason"
    t.string "income_bracket"
    t.string "dpe_target"
    t.string "construction_period"
    t.decimal "surface_ite"
    t.decimal "surface_iti"
    t.decimal "surface_sarking"
    t.decimal "surface_combles_perdus"
    t.decimal "surface_toiture_terrasse"
    t.decimal "surface_plancher_bas"
    t.float "lat"
    t.float "lng"
    t.jsonb "equipements_selection", default: {}, null: false
    t.index ["user_id"], name: "index_properties_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "role"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "valuations", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.integer "estimated_value"
    t.integer "min_value"
    t.integer "max_value"
    t.integer "bulk_sale_estimate"
    t.jsonb "comparable_sales"
    t.text "methodology"
    t.jsonb "dvf_raw"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id"], name: "index_valuations_on_property_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "analyses", "properties"
  add_foreign_key "device_simulations", "properties"
  add_foreign_key "documents", "properties"
  add_foreign_key "local_aid_results", "local_aid_schemes"
  add_foreign_key "local_aid_results", "properties"
  add_foreign_key "offers", "properties"
  add_foreign_key "offers", "users"
  add_foreign_key "properties", "users"
  add_foreign_key "valuations", "properties"
end
