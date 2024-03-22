# frozen_string_literal: true

require_relative '../lib/github_ci_app'

group = Group.find_by(anonymous: true)
group = Group.create(name: 'Community', anonymous: true) if group.nil?

# Now we can backfill the users from the check suites
CheckSuite.all.group(:author).select(:author).each do |check_suite|
  user = User.find_by(github_username: check_suite.author)

  next unless user.nil?

  github = Github::Check.new(check_suite)
  github_user = github.fetch_username(check_suite.author)

  User.create(github_username: check_suite.author, github_id: github_user[:id], group: group)
end
