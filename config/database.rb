# frozen_string_literal: true

if ENV['DATABASE_URL']
  Tyla::Api.db = Sequel.connect(ENV['DATABASE_URL'])
else
  store_dir = File.expand_path('../db/store', __dir__)
  FileUtils.mkdir_p(store_dir)
  db_path = File.join(store_dir, "#{Tyla::Api.environment}.db")
  Tyla::Api.db = Sequel.sqlite(db_path)
end
