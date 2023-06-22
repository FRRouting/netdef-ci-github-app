#!/bin/bash

echo ">> Running migration"
rake db:migrate

echo ">> Running server"
RAILS_ENV=production RACK_ENV=production rackup -o 0.0.0.0 -p 4667 config.ru
