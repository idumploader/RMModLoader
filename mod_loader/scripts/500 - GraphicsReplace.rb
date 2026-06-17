$imported ||= {}
if not $imported["IDL-GraphicsReplace"]
$imported["IDL-GraphicsReplace"] = "1.0"

module GraphicsReplace
	REPLACE_DIR = ModLoader.data_directory + "\\"
	
	RESIZE_MAPPING = {
		"Graphics/Parallaxes/kurayami01" => [Graphics.width, Graphics.height],
		#"Graphics/Pictures/map" => [Graphics.width - (640 - 480), Graphics.height - (480 - 370)],
		"Graphics/Parallaxes/pipo-fog020" => [Graphics.width, Graphics.height],
		"Graphics/System/noise_base" => [Graphics.width * 1.2, Graphics.height],
		"Graphics/System/noise_line" => [1, Graphics.height + 100],
		
		"Graphics/System/ijigen" => [Graphics.width, Graphics.height],
		"Graphics/System/mont-st-michel-1022830_1280" => [Graphics.width, Graphics.height],
		"Graphics/System/normandy-1827275_1280" => [Graphics.width, Graphics.height],
		"Graphics/System/publicdomainq-0021126ule" => [Graphics.width, Graphics.height],
		"Graphics/System/月面" => [Graphics.width, Graphics.height],
		"Graphics/System/月湖" => [Graphics.width, Graphics.height]
	}
end

module Cache
	class << self
		alias replacer_orig_load_bitmap load_bitmap
	end

	def self.normal_bitmap(orig_path)
		path = orig_path
		path = GraphicsReplace::REPLACE_DIR + path if File.exist?(GraphicsReplace::REPLACE_DIR + path + ".png")
		return @cache[path] if include?(path)
		
		#p path
		@cache[path] = Bitmap.new(path)

		resize_size = GraphicsReplace::RESIZE_MAPPING[orig_path]
		if resize_size != nil
			bitmap = Bitmap.new(*resize_size)
			bitmap.stretch_blt(bitmap.rect, @cache[path], @cache[path].rect)
			@cache[path] = bitmap
			p "#{path} resized to {#{resize_size.join(',')}}"
		end
		
		@cache[path]
	end
end

class Scene_Map
	def perform_battle_transition
		filename = "Graphics\\System\\BattleStart1"
		filename = GraphicsReplace::REPLACE_DIR + filename if File.exist?(GraphicsReplace::REPLACE_DIR + filename)
		Graphics.transition(60, filename, 100)
		Graphics.freeze
	end
end

class Bitmap
	alias replacer_orig_initialize initialize

	# def initialize(*args)
		# if args[0].is_a? String and not args[1]
			# if GraphicsReplace::RESIZE_MAPPING.key?(args[0])
				# resize_size = GraphicsReplace::RESIZE_MAPPING[args[0]]
				# *args = GraphicsReplace::REPLACE_DIR + args[0] if File.exist?(GraphicsReplace::REPLACE_DIR + args[0] + ".png")
				# bitmap = Bitmap.new(args[0], true)
				# # p resize_size.join(',')
				# replacer_orig_initialize(*resize_size)
				# self.stretch_blt(self.rect, bitmap, bitmap.rect)
				# p "#{args[0]} resized to #{resize_size.join(',')}"
				# return
			# end
			# *args = GraphicsReplace::REPLACE_DIR + args[0] if File.exist?(GraphicsReplace::REPLACE_DIR + args[0] + ".png")
		# end
		# p args.join(', ')
		# replacer_orig_initialize(*args)
	# end
end

if not Dir.exist?(GraphicsReplace::REPLACE_DIR)
	Dir.mkdir(GraphicsReplace::REPLACE_DIR)
end

end # not $imported["IDL-GraphicsReplace"]