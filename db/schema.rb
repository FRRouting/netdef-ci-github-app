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

ActiveRecord::Schema[7.0].define(version: 2023_06_07_074545) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "check_suites", force: :cascade do |t|
    t.string "author", null: false
    t.string "commit_sha_ref", null: false
    t.string "base_sha_ref", null: false
    t.string "bamboo_ci_ref"
    t.string "merge_branch"
    t.string "work_branch"
    t.string "details"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "pull_request_id"
    t.index ["pull_request_id"], name: "index_check_suites_on_pull_request_id"
  end

  create_table "ci_jobs", force: :cascade do |t|
    t.string "name", null: false
    t.integer "status", default: 0, null: false
    t.string "job_ref"
    t.string "check_ref"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "check_suite_id"
    t.index ["check_suite_id"], name: "index_ci_jobs_on_check_suite_id"
  end

  create_table "plans", force: :cascade do |t|
    t.string "bamboo_ci_plan_name", null: false
    t.string "github_repo_name", default: "0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "check_suite_id"
    t.index ["check_suite_id"], name: "index_plans_on_check_suite_id"
  end

  create_table "pull_requests", force: :cascade do |t|
    t.string "author", null: false
    t.string "github_pr_id", null: false
    t.string "branch_name", null: false
    t.string "repository", null: false
    t.string "plan"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "check_suites", "pull_requests"
  add_foreign_key "ci_jobs", "check_suites"
  add_foreign_key "plans", "check_suites"
end
