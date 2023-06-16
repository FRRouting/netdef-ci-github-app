# GitHub Hook Server
Allows a GitHub application to communicate with a server and 
that server can trigger executions on a CI and control the 
creation of Check Suite and Run for each new creation and 
commit in a PR.

# Installation

### Packages
The first step before running the system is to install these programs:

- Ruby (+2.7 or +3.0)
- PostgreSQL (any version)
- Git
- Redis

### Gems
The project does not use any Ruby versioning services (RVM or Rbenv) and 
the gems must be available as Debian packages.
We have a Gemfile to install the gems, but any gem must be available as a package.

Production / Development
- puma
- ruby-json
- ruby-jwt
- ruby-netrc
- ruby-octokit
- ruby-otr-activerecord
- ruby-pg
- ruby-sidekiq
- ruby-sidekiq-cron
- ruby-sinatra

Test

In addition to the gems listed above, we need these to run the tests locally:

- rubocop
- ruby-database-cleaner
- ruby-factory-bot
- ruby-faker
- ruby-rack-test
- ruby-rubocop-performance
- ruby-rspec
- ruby-webmock

# Usage

### Production

GitHub Hook is initialized at production mode running the following command:
`RAILS_ENV=production RACK_ENV=production rackup config.ru -o 0.0.0.0 -p 4667`

### Development

Just run the command: `ruby app/github_app.rb`

# Testing

Rubocop can be executed with the following command: `rubocop -A`.

The '-A' parameter will automatically fix some code mistakes.

Rspec be executed with the following command: `rspec ./spec --pattern '**/*_spec.rb'`
