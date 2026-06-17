#==============================================================================
# LocalizeLayer — redirects load_data to a per-mod override directory.
#
# Preinit script: aliases the global load_data so that, before reading any
# .rvdata2 from the game, it first looks for a replacement file under
# <data_directory>\ (REPLACE_DIR). Lets a mod ship localized/patched data files
# that transparently shadow the originals. Creates REPLACE_DIR if missing.
#
# Must run early (preinit) — before the game loads any data.
#==============================================================================

module LocalizeLayer
	REPLACE_DIR = ModLoader.data_directory + "\\"
end

alias localize_orig_load_data load_data

def load_data(filename)
	filename = LocalizeLayer::REPLACE_DIR + filename if File.exist?(LocalizeLayer::REPLACE_DIR + filename)
	localize_orig_load_data(filename)
end

if not Dir.exist?(LocalizeLayer::REPLACE_DIR)
	Dir.mkdir(LocalizeLayer::REPLACE_DIR)
end
