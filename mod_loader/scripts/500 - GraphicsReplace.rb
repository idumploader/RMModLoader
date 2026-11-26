#==============================================================================
# GraphicsReplace — overrides game graphics from an external directory and
# auto-scales selected parallax/background images to the current resolution.
#
# Passive — patches Cache.load_bitmap / Cache.normal_bitmap to look for a
# replacement file under REPLACE_DIR (<data_directory>) before falling back to
# the original. RESIZE_MAPPING lists paths that get stretched to a target size.
#
# No user commands, no config gate.
#==============================================================================

$imported ||= {}
if not $imported["IDL-GraphicsReplace"]
$imported["IDL-GraphicsReplace"] = "1.0"

module GraphicsReplace
  REPLACE_DIR = ModLoader.data_directory + "\\"
  # MapSize is optional when HRFix is disabled or on an older native loader.
  map_width = defined?(HRFix::MapSize) ? HRFix::MapSize.width : Graphics.width
  map_height = defined?(HRFix::MapSize) ? HRFix::MapSize.height : Graphics.height

  RESIZE_MAPPING = {
    "Graphics/Parallaxes/kurayami01" => [map_width, map_height],
    #"Graphics/Pictures/map" => [Graphics.width - (640 - 480), Graphics.height - (480 - 370)],
    "Graphics/Parallaxes/pipo-fog020" => [map_width, map_height],
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

  def self.normal_bitmap(path)
    return @cache[path] if include?(path)

    file_path = path
    file_path = GraphicsReplace::REPLACE_DIR + path if File.exist?(GraphicsReplace::REPLACE_DIR + path + ".png")
    source = Bitmap.new(file_path)
    original_size = [source.width, source.height]
    original_known = true
    if file_path != path && path.start_with?("Graphics/Pictures/")
      original = nil
      begin
        original = Bitmap.new(path)
        original_size = [original.width, original.height]
      rescue StandardError => error
        # Replacement-only resources have no reliable original dimensions.
        original_known = false
        p "GraphicsReplace: original picture size unavailable for #{path}: #{error.message}"
      ensure
        original.dispose if original && !original.disposed?
      end
    end
    @cache[path] = source

    resize_size = GraphicsReplace::RESIZE_MAPPING[path]
    if resize_size != nil
      bitmap = Bitmap.new(*resize_size)
      bitmap.stretch_blt(bitmap.rect, @cache[path], @cache[path].rect)
      @cache[path] = bitmap
      source.dispose
      p "#{path} resized to {#{resize_size.join(',')}}"
    end

    bitmap = @cache[path]
    bitmap.graphics_replace_set_sizes(original_size, original_known)
    bitmap
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
  attr_reader :graphics_replace_original_size,
              :graphics_replace_actual_size,
              :graphics_replace_original_known

  def graphics_replace_set_sizes(original_size, original_known = true)
    @graphics_replace_original_size = original_size.dup.freeze
    @graphics_replace_actual_size = [width, height].freeze
    @graphics_replace_original_known = original_known
  end

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
