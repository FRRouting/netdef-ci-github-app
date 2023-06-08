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

- puma
- rubocop
- ruby-json
- ruby-jwt
- ruby-netrc
- ruby-octokit
- ruby-otr-activerecord
- ruby-pg
- ruby-sidekiq
- ruby-sidekiq-cron
- ruby-sinatra
- ruby-rubocop-performance

# Usage

# Testing
