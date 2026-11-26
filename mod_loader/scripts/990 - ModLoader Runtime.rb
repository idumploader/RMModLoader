# Framework entrypoint; keeps native script ordering and F12 reload behavior.
framework_root = if defined?(ModLoader) && ModLoader.respond_to?(:data_directory)
  File.join(ModLoader.data_directory, 'framework')
else
  File.join(File.dirname(File.dirname(File.expand_path(__FILE__))), 'framework')
end
unless defined?(ModLoader::Framework)
  framework_loader = File.join(framework_root, 'loader.rb')
  eval(File.read(framework_loader), TOPLEVEL_BINDING, framework_loader)
end
ModLoader::Framework.load('core/bootstrap_runtime.rb')
