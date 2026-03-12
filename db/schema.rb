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

ActiveRecord::Schema[7.2].define(version: 2026_03_11_081036) do
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

  create_table "analyses", force: :cascade do |t|
    t.bigint "property_id", null: false
    t.string "analysis_type"
    t.text "content"
    t.text "recommendations"
    t.jsonb "raw_response"
    t.integer "status"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
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
  add_foreign_key "offers", "properties"
  add_foreign_key "offers", "users"
  add_foreign_key "properties", "users"
  add_foreign_key "valuations", "properties"
end
