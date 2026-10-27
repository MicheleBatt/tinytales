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

ActiveRecord::Schema[8.1].define(version: 2026_10_26_161214) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "assistant_conversations", force: :cascade do |t|
    t.string "claude_session_id"
    t.datetime "created_at", null: false
    t.bigint "post_id"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["post_id"], name: "index_assistant_conversations_on_post_id", unique: true
    t.index ["token"], name: "index_assistant_conversations_on_token", unique: true
  end

  create_table "assistant_messages", force: :cascade do |t|
    t.bigint "assistant_conversation_id", null: false
    t.jsonb "attachments", default: [], null: false
    t.text "content", default: "", null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["assistant_conversation_id"], name: "index_assistant_messages_on_assistant_conversation_id"
    t.check_constraint "role::text = ANY (ARRAY['user'::character varying, 'assistant'::character varying]::text[])", name: "assistant_messages_role_valid"
  end

  create_table "posts", force: :cascade do |t|
    t.text "body", default: "", null: false
    t.datetime "created_at", null: false
    t.bigint "media_order", default: [], null: false, array: true
    t.text "notes"
    t.datetime "publish_at"
    t.string "status", default: "draft", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["publish_at"], name: "index_posts_on_publish_at"
    t.index ["status"], name: "index_posts_on_status"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'scheduled'::character varying, 'published'::character varying]::text[])", name: "posts_status_valid"
  end

  create_table "publications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "post_id", null: false
    t.string "remote_id"
    t.string "remote_kind"
    t.string "remote_media_ids", default: [], null: false, array: true
    t.bigint "social_page_id", null: false
    t.text "sync_error"
    t.datetime "synced_at"
    t.bigint "synced_media_order", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.index ["post_id", "social_page_id"], name: "index_publications_on_post_id_and_social_page_id", unique: true
    t.index ["post_id"], name: "index_publications_on_post_id"
    t.index ["remote_id"], name: "index_publications_on_remote_id"
    t.index ["social_page_id"], name: "index_publications_on_social_page_id"
  end

  create_table "social_pages", force: :cascade do |t|
    t.text "access_token"
    t.datetime "created_at", null: false
    t.string "external_id"
    t.string "name", null: false
    t.string "platform", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["url"], name: "index_social_pages_on_url", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "assistant_conversations", "posts", on_delete: :cascade
  add_foreign_key "assistant_messages", "assistant_conversations", on_delete: :cascade
  add_foreign_key "publications", "posts", on_delete: :cascade
  add_foreign_key "publications", "social_pages"
end
