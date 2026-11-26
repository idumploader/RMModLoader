$imported ||= {}
unless $imported["IDL-ModMenu"]
  $imported["IDL-ModMenu"] = "1.0"
  ['entries.rb', 'registry.rb', 'windows.rb', 'integration.rb'].each do |name|
    ModLoader::Framework.load('modmenu/' + name)
  end
end
