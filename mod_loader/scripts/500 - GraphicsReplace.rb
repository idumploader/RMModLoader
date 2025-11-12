module GraphicsReplace
	REPLACE_DIR = ModLoader.data_directory + "\\"
end

module Cache
	class << self
		alias replacer_orig_load_bitmap load_bitmap
	end

	def self.load_bitmap(folder_name, filename, hue = 0)
		folder_name = GraphicsReplace::REPLACE_DIR + folder_name if File.exist?(GraphicsReplace::REPLACE_DIR + folder_name + filename + ".png")
		Cache.replacer_orig_load_bitmap(folder_name, filename, hue)
	end
end

class Scene_Map
	def perform_battle_transition
		filename = "Graphics\\System\\BattleStart"
		filename = GraphicsReplace::REPLACE_DIR + "Graphics\\System\\BattleStart.png" if File.exist?(GraphicsReplace::REPLACE_DIR + "Graphics\\System\\BattleStart.png")
		Graphics.transition(60, filename, 100)
		Graphics.freeze
	end
end

if not Dir.exist?(GraphicsReplace::REPLACE_DIR)
	Dir.mkdir(GraphicsReplace::REPLACE_DIR)
end