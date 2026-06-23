#==============================================================================
# ModMenuDefaults — entries the loader itself contributes to the shared menu
# (ModMenu, 10), independent of any single mod, in the default "General" tab.
#
# Currently: a Language selector for ModLoader::I18n (11), so every I18n-using
# mod is translatable from one place instead of each shipping its own switch.
# Only shown when at least one translation file exists (else there is nothing to
# switch to). Loads after both 10 and 11; skipped if either is absent.
#==============================================================================

$imported ||= {}
if not $imported["IDL-ModMenuDefaults"]
$imported["IDL-ModMenuDefaults"] = "1.0"

if defined?(ModLoader::ModMenu) and defined?(ModLoader::I18n)

module ModLoader
module ModMenu
  langs = ([I18n::DEFAULT_LANG] + I18n.available).uniq
  if langs.size > 1
    header("Language", :category => DEFAULT_CATEGORY)
    choice("Language", :category => DEFAULT_CATEGORY,
           :values => langs,
           :labels => langs.map { |l| l.to_s.upcase },
           :get => proc { I18n.language },
           :set => proc { |l| I18n.language = l })
  end
end
end

end # if defined?(ModMenu) and defined?(I18n)

end # not $imported["IDL-ModMenuDefaults"]
