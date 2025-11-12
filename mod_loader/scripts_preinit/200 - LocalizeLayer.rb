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
