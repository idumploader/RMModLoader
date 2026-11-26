# Shared component loader. Components retain their own $imported guards so a
# ModResetter reload can evaluate them again without Ruby require caching.
module ModLoader
  unless const_defined?(:Framework)
    module Framework
      ROOT = File.dirname(__FILE__)
      def self.load(relative_path)
        root = ModLoader.respond_to?(:data_directory) ?
          File.join(ModLoader.data_directory, 'framework') : ROOT
        path = File.expand_path(relative_path, root)
        eval(File.read(path, :encoding => 'UTF-8'), TOPLEVEL_BINDING, path)
      end
    end
  end
end
