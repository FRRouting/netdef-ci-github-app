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
- Redis (https://redis.io/)

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

# Database Configuration

This document provides instructions on how to configure the database for the GitHub Hook Server project.

## Prerequisites

Ensure you have the following installed on your system:
- PostgreSQL (any version)

## Configuration Steps

1. **Install PostgreSQL**:
   Follow the instructions for your operating system to install PostgreSQL. You can find the installation guide on the [official PostgreSQL website](https://www.postgresql.org/download/).

2. **Create a Database**:
   After installing PostgreSQL, create a new database for the project. You can do this using the `psql` command-line tool or any PostgreSQL client.

   ```bash
   RAKE_ENV=development psql -c "CREATE DATABASE github_hook_server_development;"
   ```
3. **Configure Database Connection**:
    Update the `config/database.yml` file with the database connection details. You can use the following configuration as a template:
    
    ```yaml
    development:
      adapter: postgresql
      encoding: unicode
      database: github_hook_server_development
      pool: 5
      username: postgres
      password: password
      host: localhost
      port: 5432
    ```
    
    Replace the `username`, `password`, `host`, and `port` values with your PostgreSQL connection details.

4. **Run Database Migrations**:
After configuring the database, run the database migrations to set up the necessary tables and schema.  
 ```bash
  bundle exec rake db:migrate
 ```

5. **Verify the Configuration**:
   Start the application and verify that it can connect to the database without any errors.
```bash
RAILS_ENV=development rackup -o 0.0.0.0 -p 9292 config.ru
```

# Usage

### Production

GitHub Hook is initialized at production mode running the following command:
`RAILS_ENV=production RACK_ENV=production rackup config.ru -o 0.0.0.0 -p 4667`

It is important that you have registered an application with GitHub for this tool to work correctly.

### Development

Just run the command: `rackup -o 0.0.0.0 -p 9292 config.ru`

# Testing

Rubocop can be executed with the following command: `rubocop -A`.

The '-A' parameter will automatically fix some code mistakes.

Rspec be executed with the following command: `rspec ./spec --pattern '**/*_spec.rb'`
