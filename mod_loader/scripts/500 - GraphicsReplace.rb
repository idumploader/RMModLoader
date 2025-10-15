module GraphicsReplace
	REPLACE_DIR = "mod_loader/"
end

module Cache
	#alias replacer_orig_load_bitmap load_bitmap

	# WARNING: COPIED SOURCE FROM RPG MAKER
	def self.load_bitmap(folder_name, filename, hue = 0)
		folder_name = GraphicsReplace::REPLACE_DIR + folder_name if File.exist?(GraphicsReplace::REPLACE_DIR + folder_name + filename + ".png")
		#replacer_orig_load_bitmap(folder_name, filename, hue)
		
		@cache ||= {}
		if filename.empty?
			empty_bitmap
		elsif hue == 0
			normal_bitmap(folder_name + filename)
		else
			hue_changed_bitmap(folder_name + filename, hue)
		end
	end
end

#class << Graphics
#	alias replacer_orig_transition transition
#	
#	def transition(duration, filename, vague)
#		filename = GraphicsReplace::REPLACE_DIR + filename if File.exist?(GraphicsReplace::REPLACE_DIR + filename + ".png")
#		replacer_orig_transition(duration, filename, vague)
#	end
#
#end

class Scene_Map
	def perform_battle_transition
		filename = "Graphics/System/BattleStart"
		filename = GraphicsReplace::REPLACE_DIR + "Graphics/System/BattleStart.png" if File.exist?(GraphicsReplace::REPLACE_DIR + "Graphics/System/BattleStart.png")
		Graphics.transition(60, filename, 100)
		Graphics.freeze
	end
end

if not Dir.exist?(GraphicsReplace::REPLACE_DIR)
	Dir.mkdir(GraphicsReplace::REPLACE_DIR)
end