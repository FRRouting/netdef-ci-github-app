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

# Installing RVM (Ruby Version Manager)

This guide will walk you through the steps to install RVM (Ruby Version Manager) on your system.

## Prerequisites

Before you begin, ensure you have the following installed on your system:
- `curl`
- `gpg`

You can install these using your package manager. For example, on Debian-based systems, you can use:

```shell
sudo apt update
sudo apt install -y curl gpg
```

## Installation Steps

1. Install RVM
   To install RVM, run the following command:

```shell
\curl -sSL https://get.rvm.io | bash -s stable
```

2. Load RVM Scripts
   After the installation, you need to load the RVM scripts. Add the following line to your shell profile (~/.bashrc, ~/.zshrc, etc.):

```shell
source ~/.rvm/scripts/rvm
```
Then, reload your shell profile:
```shell
source ~/.bashrc  # or source ~/.zshrc
```

3. Verify the Installation
   To verify that RVM is installed correctly, run:

```shell
rvm --version
```

You should see the RVM version information.  

## Installing Ruby
Once RVM is installed, you can use it to install Ruby versions.
1. Install a Ruby Version
   To install a specific version of Ruby, use the following command:

```shell
rvm autolibs disable
rvm install 3.3.1
```

2. Use a Ruby Version
   To use a specific version of Ruby, run:

```shell
rvm use 3.3.1 --default
```
This sets the specified Ruby version as the default for your shell.

3. Verify the Ruby Installation
   To verify that Ruby is installed correctly, run:

```shell 
ruby --version
```   
You should see the version of Ruby that you installed.

## Managing Multiple Ruby Versions
RVM allows you to manage multiple Ruby versions. You can switch between them as needed.  
List Installed Ruby Versions
To list all installed Ruby versions, run:

```shell
rvm list
```

Switch Ruby Versions
To switch to a different Ruby version, use:

```shell 
rvm use <version>
```

Uninstalling RVM
If you need to uninstall RVM, you can do so with the following command:

```shell
rvm implode
```
