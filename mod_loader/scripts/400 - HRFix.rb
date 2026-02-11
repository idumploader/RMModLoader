if ModLoader.hrfix_enabled

#Graphics.resize_screen(1920, 1080)

module HRFix
	ORIG_PICTURE_IMG_WIDTH = 680.0
	ORIG_PICTURE_IMG_HEIGHT = 480.0
	ENABLE_PICTURE_RESIZING = true
	
	RESIZE_BLACKLIST = [
		"h01", "h02", "h03", "h04",
		"h05", "h06", "h07", "h08",
		"h09", "h10", "h11", "h12",
		"h13", "z02",
		
		"夢霊　アヒル", "夢霊　シンドバッド", "夢霊　ピーターパン",
		"夢霊　ピノッキオ", "夢霊　ヘングレ (1)", "夢霊　ヘングレ (2)",
		"夢霊　ロバ<", "夢霊　ロビン", "夢霊　星の王子様",
		"夢霊カタリナ", "夢霊パトラッシュ", "夢霊ハンス", "夢霊ブレーメン",
		"夢霊ブレーメン２", "夢霊ブレーメン３", "夢霊ブレーメン４",
		"ムード", "ムード２", "ムード３", "イナバ",
		"次女立ち絵", "次女立ち絵1", "次女立ち絵2", "次女立ち絵3",
		"あしながおじさん", "イーディス立ち絵", "イーディス立ち絵1",
		"イーディス立ち絵2", "ロリーナ立ち絵", "ロリーナ立ち絵1",
		"ロリーナ立ち絵2", "ロリーナ立ち絵3", "ロリーナ立ち絵4",
		"人形立ち絵", "鎧を履いた騎士",
		
		# DLC
		"剑光", 
	]
end

class Spriteset_Map
	alias hrfix_orig_create_tilemap create_tilemap
	alias hrfix_orig_update_tilemap update_tilemap
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def create_tilemap
		@tilemap = Tilemap.new(@viewport1)
		@tilemap.map_data = $game_map.data
		@tilemap.map_id = $game_map.map_id # custom field, used by hook to identify map id
		load_tileset
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def update_tilemap
		@tilemap.map_data = $game_map.data
		@tilemap.ox = $game_map.display_x * 32
		@tilemap.oy = $game_map.display_y * 32
		@tilemap.map_id = $game_map.map_id # custom field, used by hook to identify map id
		@tilemap.update
	end
end

class Game_Map
	alias hrfix_orig_scroll_down scroll_down
	alias hrfix_orig_scroll_left scroll_left
	alias hrfix_orig_scroll_right scroll_right
	alias hrfix_orig_scroll_up scroll_up
	
	alias hrfix_orig_set_display_pos set_display_pos
	
	def set_display_pos(x, y)
		hrfix_orig_set_display_pos(x, y)
		@display_y = [@display_y, 0].max
		@display_x = [@display_x, 0].max
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def scroll_down(distance)
		if loop_vertical?
			@display_y += distance
			@display_y %= @map.height
			@parallax_y += distance if @parallax_loop_y
		else
			last_y = @display_y
			@display_y = [[@display_y + distance, height - screen_tile_y].min, 0].max  # fixes scroll bug with bigger Graphics size
			@parallax_y += @display_y - last_y
		end
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def scroll_left(distance)
		if loop_horizontal?
			@display_x += @map.width - distance
			@display_x %= @map.width 
			@parallax_x -= distance if @parallax_loop_x
		else
			last_x = @display_x
			@display_x = [[@display_x - distance, 0].max, width].min
			@parallax_x += @display_x - last_x
		end
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def scroll_right(distance)
		if loop_horizontal?
			@display_x += distance
			@display_x %= @map.width
			@parallax_x += distance if @parallax_loop_x
		else
			last_x = @display_x
			@display_x = [[@display_x + distance, (width - screen_tile_x)].min, 0].max # fixes scroll bug with bigger Graphics size
			@parallax_x += @display_x - last_x
		end
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def scroll_up(distance)
		if loop_vertical?
			@display_y += @map.height - distance
			@display_y %= @map.height
			@parallax_y -= distance if @parallax_loop_y
		else
			last_y = @display_y
			@display_y = [[@display_y - distance, 0].max, height].min
			@parallax_y += @display_y - last_y
		end
	end
end

if HRFix::ENABLE_PICTURE_RESIZING

class Game_Interpreter
	alias hrfix_orig_command_231 command_231
	alias hrfix_orig_command_232 command_232
	
	# Update picture scale_x, scale_y according to it's original size
	# params:
	#   bitmap_name Name of the bitmap in cache
	# returns: [[x, y], [scale_x, scale_y]]
	def hrfix_get_fixed_dimensions(bitmap_name, x, y)
		bitmap = Cache.picture(bitmap_name)
		
		scale_factor = [Graphics.width / 640.0, Graphics.height / 480.0].min
		new_scale_x = @params[6] * scale_factor * (HRFix::ORIG_PICTURE_IMG_WIDTH / bitmap.width)
		new_scale_y = @params[7] * scale_factor * (HRFix::ORIG_PICTURE_IMG_HEIGHT / bitmap.height)
		
		new_x = (Graphics.width - (bitmap.width * new_scale_x / 100)) / 2
		new_y = (Graphics.height - (bitmap.height * new_scale_y / 100)) / 2
		
		return [[new_x, new_y], [new_scale_x, new_scale_y]]
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	# ShowPicture
	# params:
	#	0: picture_id
	#	1: name
	#	2: origin
	#	3: pos_from_vars
	#	4: x_or_var_id
	#	5: y_or_var_id
	#	6: scale_x
	#	7: scale_y
	#	8: alpha
	#	9: blend_mode
	def command_231
		if @params[3] == 0    # 直接指定
			x = @params[4]
			y = @params[5]
		else                  # 変数で指定
			x = $game_variables[@params[4]]
			y = $game_variables[@params[5]]
		end
		
		if not HRFix::RESIZE_BLACKLIST.include?(@params[1])
			origin, dimensions = hrfix_get_fixed_dimensions(@params[1], x, y)
		else
			scale_x = Graphics.width / 640.0
			scale_y = Graphics.height / 480.0
			origin = [x * scale_x, y * scale_y]
			dimensions = [@params[6] * scale_x, @params[7] * scale_y]
		end
		
		screen.pictures[@params[0]].show(@params[1], @params[2], origin[0], origin[1],
			dimensions[0], dimensions[1], @params[8], @params[9])
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	# MovePicture
	def command_232
		if @params[3] == 0    # 直接指定
			x = @params[4]
			y = @params[5]
		else                  # 変数で指定
			x = $game_variables[@params[4]]
			y = $game_variables[@params[5]]
		end
		
		picture_name = screen.pictures[@params[0]].name
		if not HRFix::RESIZE_BLACKLIST.include?(picture_name)
			origin, dimensions = hrfix_get_fixed_dimensions(picture_name, x, y)
		else
			scale_x = Graphics.width / 640.0
			scale_y = Graphics.height / 480.0
			origin = [x * scale_x, y * scale_y]
			dimensions = [@params[6] * scale_x, @params[7] * scale_y]
		end
		
		screen.pictures[@params[0]].move(@params[2], origin[0], origin[1],
			dimensions[0], dimensions[1], @params[8], @params[9], @params[10])
		wait(@params[10]) if @params[11]
	end
end

class Spriteset_Map
	def update_pictures
		$game_map.screen.pictures.each do |pic|
			@picture_sprites[pic.number] ||= Sprite_Picture.new(@viewport2, pic)
			@picture_sprites[pic.number].update
		end
	end
end

# class Sprite_Picture < Sprite
	# def hrfix_get_fixed_dimensions(bitmap, x, y)
		# scale_factor = [Graphics.width / 640.0, Graphics.height / 480.0].min
		# new_scale_x = scale_factor * (HRFix::ORIG_PICTURE_IMG_WIDTH / bitmap.width)
		# new_scale_y = scale_factor * (HRFix::ORIG_PICTURE_IMG_HEIGHT / bitmap.height)
		
		# new_x = (Graphics.width - (bitmap.width * new_scale_x / 100)) / 2
		# new_y = (Graphics.height - (bitmap.height * new_scale_y / 100)) / 2
		
		# return [[new_x, new_y], [new_scale_x, new_scale_y]]
	# end

	# def update_bitmap
		# # self.bitmap = Bitmap.new(Graphics.width, Graphics.height)
		# # bitmap = Cache.picture(@picture.name)
		# # self.bitmap.stretch_blt(self.bitmap.rect, bitmap, bitmap.rect)
		# new_bitmap = Cache.picture(@picture.name)
		# if new_bitmap != @picture_bitmap
			# origin, dimensions = hrfix_get_fixed_dimensions(new_bitmap, @picture.x, @picture.y)
			
			# new_rect = Rect.new(origin[0], origin[1], new_bitmap.rect.width * dimensions[0], new_bitmap.rect.height * dimensions[1])
			# p new_rect
		
			# self.bitmap = Bitmap.new(Graphics.width, Graphics.height)
			# self.bitmap.stretch_blt(new_rect, new_bitmap, new_bitmap.rect)
			# # self.bitmap = new_bitmap
		# end
		# @picture_bitmap = new_bitmap
		
		# # if @back_sprite == nil
			# # self.viewport.color = Color.new(255, 0, 0, 1)
			# # @back_sprite = Sprite.new(self.viewport)
			# # @back_sprite.bitmap = Bitmap.new(Graphics.width, Graphics.height)
			# # @back_sprite.z = 100
		# # end
	# end
# end

end # HRFix::ENABLE_PICTURE_RESIZING

class Window_Base
	alias hrfix_orig_draw_item_name draw_item_name
	
	def draw_item_name(item, x, y, enabled = true, width = 0)
		width = self.width * 0.75 if width.zero? # fixes item name cropping
		hrfix_orig_draw_item_name(item, x, y, enabled, width)
	end
end

class Game_Troop
	alias hrfix_orig_setup setup
	
	def setup(troop_id)
		hrfix_orig_setup(troop_id)
		@enemies.each do |enemy|
			enemy.screen_x *= Graphics.width / 640.0 # Fixes monster position
			enemy.screen_y *= Graphics.height / 480.0 # Fixes monster position
		end
	end
end

class Spriteset_Battle

	# WARNING: Copied from RPG Maker
	def create_blurry_background_bitmap
		source = SceneManager.background_bitmap
		bitmap = Bitmap.new(Graphics.width, Graphics.height)
		bitmap.stretch_blt(bitmap.rect, source, source.rect)
		bitmap.radial_blur(120, 16)
		bitmap
	end
	
end

# class Window_Message
	# def window_width
		# [Graphics.width, 640].min
	# end
	
	# def update_placement
		# @position = $game_message.position
		# self.y = @position * (Graphics.height - height) / 2
		# @gold_window.y = y > 0 ? 0 : Graphics.height - @gold_window.height
		
		# self.x = (Graphics.width - window_width) / 2
	# end
# end

# class Window_FaceName
	
	# def hrfix_update_placement
	    # @name_sprite.x = self.x + self.width / 2
		# @name_sprite.y = self.y + self.height / 2
	# end
# end

# class Window_Base

	# alias hrfix_orig_show_name_window show_name_window
	
	# def show_name_window(face_name, face_index, x, size = 96)
		# hrfix_orig_show_name_window(face_name, face_index, x, size)
		# # @name_windows[name].x += [0, 640 - Graphics.width].max / 2
		# @name_windows.each do |key, window|
			# window.x += [0, Graphics.width - 640].max / 2
			# p window.x
			# window.hrfix_update_placement
		# end
	# end
	
# end

class Game_Character
	
	attr_accessor :x
	attr_accessor :y
	attr_accessor :real_x
	attr_accessor :real_y
	
end

# class Spriteset_Map
	# attr_reader :tilemap
	
	# alias hrfix_orig_create_characters create_characters
	# alias hrfix_orig_create_viewports create_viewports
	# alias hrfix_orig_create_parallax create_parallax
	# alias hrfix_orig_update_viewports update_viewports
	
	# def create_viewports
		# hrfix_orig_create_viewports
		# @tm_viewport = Viewport.new
		# @viewport1.z = 1
	# end
	
	# def create_tilemap
		# @tilemap = Tilemap.new(@tm_viewport)
		# @tilemap.map_data = $game_map.data
		# load_tileset
	# end
	
	# def create_parallax
		# @parallax = Plane.new(@tm_viewport)
		# @parallax.z = -100
	# end
	
	# def create_characters
		# hrfix_orig_create_characters
		
		# off_x = [$game_map.screen_tile_x - $game_map.width, 0].max * 16
		# off_y = [$game_map.screen_tile_y - $game_map.height, 0].max * 16
		# # @character_sprites.each do |sprite|
		# #	sprite.character.real_x += off_x
		# #	sprite.character.real_y += off_y
		# # end
		
		# @viewport1.x = off_x
		# @viewport1.y = off_y
	# end
	
	# def update_characters
		# refresh_characters if @map_id != $game_map.map_id
		
		# off_x = [$game_map.screen_tile_x - $game_map.width, 0].max * 16
		# off_y = [$game_map.screen_tile_y - $game_map.height, 0].max * 16
		# @character_sprites.each do |sprite|
			# sprite.update
			# # sprite.x += off_x
			# # sprite.y += off_y
		# end
	# end
	
	# def update_viewports
		# hrfix_orig_update_viewports
		# @tm_viewport.update
	# end
# end

if not ["2.4", "2.5"].include?(ModLoader.version)

p "HRFix: ModLoader.version >= 2.6. Enabled hrfix_tileset_offset_enabled"

class Scene_Map

	alias hrfix_orig_start start
	alias hrfix_orig_terminate terminate
	
	def start
		ModLoader.hrfix_tileset_offset_enabled = true
		hrfix_orig_start
	end
	
	def terminate
		ModLoader.hrfix_tileset_offset_enabled = false
		hrfix_orig_terminate
	end

end

class Scene_Title
	alias hrfix_orig_start start
	
	def start
		ModLoader.hrfix_tileset_offset_enabled = false
		hrfix_orig_start
	end
end

end # not ["2.4", "2.5"].include?(ModLoader.version)

class Game_Event
	alias hrfix_orig_near_the_screen? :near_the_screen?

	def near_the_screen?(dx = $game_map.screen_tile_x / 2 + 1, dy = $game_map.screen_tile_y / 2 + 1)
		hrfix_orig_near_the_screen(dx, dy)
	end
end

end # ModLoader.hrfix_enabled