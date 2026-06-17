#==============================================================================
# LocalizedStrings — localized string table loaded from .rvdata2 files.
#
# Strings live in <data_directory>/strings as "<name>_<lang>.rvdata2" and are
# cached in memory. Default language is "ru". The strings directory is created
# automatically on load.
#
# Public surface (module MLLocalizedStrings):
#   MLLocalizedStrings[key]                  — lookup (returns key if missing)
#   MLLocalizedStrings[key] = value          — set
#   MLLocalizedStrings.add_required(name, auto_load)
#   MLLocalizedStrings.load(lang)            — (re)load required files for lang
#   MLLocalizedStrings.save_to(name)         — persist current strings
#
# Dependencies: ModLoader.data_directory.
#==============================================================================

$imported ||= {}
if not $imported["IDL-LocalizedStrings"]
$imported["IDL-LocalizedStrings"] = "1.0"


module MLLocalizedStrings
	LOCALIZED_STRINGS_PATH = ModLoader.data_directory + "/strings"
	STRINGS_FILEPATH_F = LOCALIZED_STRINGS_PATH + "/%s_%s.rvdata2"

	DEFAULT_LANG = "ru"

	@required_strings = [ "base" ]
	@strings = {}
	@lang = DEFAULT_LANG
	
	def self.[](key)
		return @strings[key] if include?(key)
		return key
	end
	
	def self.[]=(key, name)
		@strings[key] = name
	end
	
	def self.include?(key)
		return @strings.include?(key)
	end
	
	def self.add_required(name, auto_load = true)
		@required_strings.push(name)
		@strings.update(load_data(sprintf(STRINGS_FILEPATH_F, name, @lang))) if auto_load
	end
	
	def self.load(lang)
		# File.open(make_filename(index), "wb") do |file|
			# @strings = Marshal.load(file)
		# end
		@lang = lang
		@strings = {}
		@required_strings.each do |name|
			@strings.update(load_data(sprintf(STRINGS_FILEPATH_F, name, @lang)))
		end
	end
	
	def self.save_to(name)
		save_data(@strings, sprintf(STRINGS_FILEPATH_F, name, @lang))
	end
end

if not Dir.exist?(MLLocalizedStrings::LOCALIZED_STRINGS_PATH)
	Dir.mkdir(MLLocalizedStrings::LOCALIZED_STRINGS_PATH)
end

MLLocalizedStrings.load(MLLocalizedStrings::DEFAULT_LANG)

end # not $imported["IDL-LocalizedStrings"]