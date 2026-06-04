# frozen_string_literal: true

# Requires all ruby files in specified app folders, in explicit order so that
# config/ (app class + DB) is always loaded before app/ layers.
def require_app(folders = %w[domain infrastructure presentation application], with_initializers: true)
  ordered = ['config'] + Array(folders).map { |f| "app/#{f}" }

  ordered.each do |folder|
    Dir.glob("./#{folder}/**/*.rb").each do |file|
      next if !with_initializers && file.include?('/initializers/')

      require File.expand_path(file)
    end
  end
end
