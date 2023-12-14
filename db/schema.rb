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

ActiveRecord::Schema[7.0].define(version: 2023_12_14_094534) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "bamboo_stage_translations", force: :cascade do |t|
    t.string "bamboo_stage_name", null: false
    t.string "github_check_run_name", null: false
    t.boolean "start_in_progress", default: false
    t.boolean "can_retry", default: true
    t.integer "position"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "mandatory", default: true
  end

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
    t.boolean "re_run", default: false
    t.integer "retry", default: 0
    t.boolean "sync", default: false
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
    t.integer "retry", default: 0
    t.bigint "stage_id"
    t.index ["check_suite_id"], name: "index_ci_jobs_on_check_suite_id"
    t.index ["stage_id"], name: "index_ci_jobs_on_stage_id"
  end

  create_table "plans", force: :cascade do |t|
    t.string "bamboo_ci_plan_name", null: false
    t.string "github_repo_name", default: "0", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "check_suite_id"
    t.index ["check_suite_id"], name: "index_plans_on_check_suite_id"
  end

  create_table "pull_request_subscriptions", force: :cascade do |t|
    t.string "slack_user_id", null: false
    t.string "rule", null: false
    t.string "target", null: false
    t.string "notification"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "pull_request_id"
    t.index ["pull_request_id"], name: "index_pull_request_subscriptions_on_pull_request_id"
  end

  create_table "pull_requests", force: :cascade do |t|
    t.string "author", null: false
    t.integer "github_pr_id", null: false
    t.string "branch_name", null: false
    t.string "repository", null: false
    t.string "plan"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "stages", force: :cascade do |t|
    t.string "name", null: false
    t.integer "status", default: 0, null: false
    t.string "check_ref"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "check_suite_id"
    t.bigint "bamboo_stage_translations_id"
    t.index ["bamboo_stage_translations_id"], name: "index_stages_on_bamboo_stage_translations_id"
    t.index ["check_suite_id"], name: "index_stages_on_check_suite_id"
  end

  create_table "topotest_failures", force: :cascade do |t|
    t.string "test_suite", null: false
    t.string "test_case", null: false
    t.string "message", null: false
    t.integer "execution_time", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "ci_job_id"
    t.index ["ci_job_id"], name: "index_topotest_failures_on_ci_job_id"
  end

  add_foreign_key "check_suites", "pull_requests"
  add_foreign_key "ci_jobs", "check_suites"
  add_foreign_key "ci_jobs", "stages"
  add_foreign_key "plans", "check_suites"
  add_foreign_key "pull_request_subscriptions", "pull_requests"
  add_foreign_key "stages", "bamboo_stage_translations", column: "bamboo_stage_translations_id"
  add_foreign_key "stages", "check_suites"
  add_foreign_key "topotest_failures", "ci_jobs"
end
