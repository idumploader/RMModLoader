Graphics.resize_screen(1920, 1000)

module HRFix
	ORIG_PICTURE_IMG_WIDTH = 680.0
	ORIG_PICTURE_IMG_HEIGHT = 480.0
	ENABLE_PICTURE_RESIZING = true
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
	def command_231
		if @params[3] == 0    # 直接指定
			x = @params[4]
			y = @params[5]
		else                  # 変数で指定
			x = $game_variables[@params[4]]
			y = $game_variables[@params[5]]
		end
		
		origin, dimensions = hrfix_get_fixed_dimensions(@params[1], x, y)
		
		screen.pictures[@params[0]].show(@params[1], @params[2], origin[0], origin[1],
			dimensions[0], dimensions[1], @params[8], @params[9])
	end
	
	# WARNING: COPIED SOURCE FROM RPG MAKER
	def command_232
		if @params[3] == 0    # 直接指定
			x = @params[4]
			y = @params[5]
		else                  # 変数で指定
			x = $game_variables[@params[4]]
			y = $game_variables[@params[5]]
		end
		
		origin, dimensions = hrfix_get_fixed_dimensions(screen.pictures[@params[0]].name, x, y)
		
		screen.pictures[@params[0]].move(@params[2], origin[0], origin[1],
			dimensions[0], dimensions[1], @params[8], @params[9], @params[10])
		wait(@params[10]) if @params[11]
	end
end

end # HRFix::ENABLE_PICTURE_RESIZING

class Window_Base
	alias hrfix_orig_draw_item_name draw_item_name
	
	def draw_item_name(item, x, y, enabled = true, width = 0)
		width = self.width * 0.75 if width.zero? # fixes item name cropping
		hrfix_orig_draw_item_name(item, x, y, enabled, width)
	end
end

class Game_Troop

	# WARNING: Copied from RPG Maker
	def setup(troop_id)
		clear
		@troop_id = troop_id
		@enemies = []
		troop.members.each do |member|
			next unless $data_enemies[member.enemy_id]
			enemy = Game_Enemy.new(@enemies.size, member.enemy_id)
			enemy.hide if member.hidden
			enemy.screen_x = (member.x / 640.0) * Graphics.width # Fixes monster position
			enemy.screen_y = (member.y / 480.0) * Graphics.height # Fixes monster position
			@enemies.push(enemy)
		end
		init_screen_tone
		make_unique_names
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
