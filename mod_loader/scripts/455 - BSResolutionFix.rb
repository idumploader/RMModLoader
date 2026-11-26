# Game-specific high-resolution UI corrections. Loaded after HRFix/BSFixes.
# Ruby 1.9 / RGSS3 compatible; no save data or cached asset mutations.
$imported ||= {}
unless $imported['BS-ResolutionFix']
$imported['BS-ResolutionFix'] = true
if ModLoader.hrfix_enabled
module BSResolutionFix
  def self.scale
    [[Graphics.width / 640.0, Graphics.height / 480.0].min, 1.0].max
  end
  def self.pixels(value)
    (value * scale).round
  end

  # Keep layout dimensions and text metrics in the same coordinate system.
  module WindowMetrics
    def create_contents
      super
      reset_font_settings
    end
    def line_height; BSResolutionFix.pixels(super); end
    def standard_padding; BSResolutionFix.pixels(super); end
    def reset_font_settings(*args)
      super(*args)
      contents.font.size = [BSResolutionFix.pixels(contents.font.size), 96].min
    end
    def draw_icon(icon_index, x, y, enabled = true)
      bitmap = Cache.system('Iconset')
      source = Rect.new(icon_index % 16 * 24, icon_index / 16 * 24, 24, 24)
      size = BSResolutionFix.pixels(24)
      contents.stretch_blt(Rect.new(x, y, size, size), bitmap, source, enabled ? 255 : translucent_alpha)
    end
    def draw_item_name(item, x, y, enabled = true, width = 172)
      return unless item
      icon = item.icon_index
      if defined?(BattleCommand_Custom) && is_a?(Window_SkillList) && item.id == 1 &&
          BattleCommand_Custom::ACTOR_ICON_ATTACK_WEAPON && @actor && @actor.weapons[0]
        icon = @actor.weapons[0].icon_index
      end
      draw_icon(icon, x, y, enabled)
      color = normal_color
      if defined?(ItemLevelDrawer) && item.note =~ /<品质 (\d+)>/i
        index = [$1.to_i - 1, 0].max
        data = ItemLevelDrawer::ColorSet[index]
        color = data.is_a?(Color) ? data : Color.new(*data) if data
      end
      change_color(color, enabled)
      offset = BSResolutionFix.pixels(24)
      draw_text(x + offset, y, [width - offset, 0].max, line_height, item.name)
    end
    def process_draw_icon(icon_index, pos)
      draw_icon(icon_index, pos[:x], pos[:y] + BSResolutionFix.pixels(2))
      pos[:x] += BSResolutionFix.pixels(24)
    end
    def draw_gauge(x, y, width, rate, color1, color2)
      height = BSResolutionFix.pixels(6)
      bottom = y + line_height - BSResolutionFix.pixels(2)
      contents.fill_rect(x, bottom - height, width, height, gauge_back_color)
      fill = (width * [[rate, 0].max, 1].min).to_i
      contents.gradient_fill_rect(x, bottom - height, fill, height, color1, color2) if fill > 0
    end
    def draw_actor_icons(actor, x, y, width = 96)
      size = BSResolutionFix.pixels(24)
      (actor.state_icons + actor.buff_icons).first(width / size).each_with_index do |icon, index|
        draw_icon(icon, x + size * index, y)
      end
    end
  end
end

[Window_Message, Window_ChoiceList, Window_ItemList, Window_Help,
 Window_NumberInput].each { |klass| klass.send(:include, BSResolutionFix::WindowMetrics) }

class Window_Help
  # BSFixes defines this directly on Window_Help, above included modules.
  if instance_methods(false).include?(:reset_font_settings)
  alias bsresolution_help_reset_font_settings reset_font_settings
  def reset_font_settings(*args)
    bsresolution_help_reset_font_settings(*args)
    contents.font.size = [BSResolutionFix.pixels(contents.font.size), 96].min
  end
  end
end

class Window_Message
  alias bsresolution_update_placement update_placement
  def update_placement
    bsresolution_update_placement
    self.y = 0 if @position == 0
    self.y = Graphics.height - height if @position == 2
  end
  alias bsresolution_new_line_x new_line_x
  def new_line_x
    BSResolutionFix.pixels(bsresolution_new_line_x)
  end
  def draw_face(face_name, face_index, x, y, size = 96)
    bitmap = Cache.face(face_name)
    source = BSFaceSheet.rect(bitmap, face_index, 0, 0, size, size)
    scaled = BSResolutionFix.pixels(size)
    contents.stretch_blt(Rect.new(x, y, scaled, scaled), bitmap, source)
    show_name_window(face_name, face_index, x, scaled) if respond_to?(:show_name_window)
  end
end

if defined?(Window_KisekiStatus)
class Window_KisekiStatus
  alias bsresolution_item_width item_width
  alias bsresolution_item_height item_height
  alias bsresolution_item_rect item_rect
  alias bsresolution_draw_item draw_item
  def item_width; BSResolutionFix.pixels(bsresolution_item_width); end
  def item_height; BSResolutionFix.pixels(bsresolution_item_height); end
  # BEGIN KISEKI DRAWING
  def item_rect(index)
    bsresolution_item_rect(index)
  end

  def bsresolution_artwork(name, &block)
    BSHudBitmapCache.artwork(name, BSResolutionFix.scale, &block)
  end

  def draw_item(index)
    actor = $game_party.battle_members[index]
    rect = item_rect(index)
    bsresolution_artwork('Actor_bg1') do |background|
      contents.blt(rect.x, rect.y, background, background.rect)
    end
    size = BSResolutionFix.pixels(48)
    BSHudBitmapCache.portrait(actor.face_name, actor.face_index, size) do |portrait|
      contents.blt(rect.x + BSResolutionFix.pixels(2), rect.y + BSResolutionFix.pixels(2), portrait, portrait.rect)
    end
    if actor.dead?
      bsresolution_artwork('Actor_bg1') do |background|
        contents.blt(rect.x, rect.y, background, background.rect)
      end
    end
    bsresolution_artwork(actor.dead? ? 'Actor_bg3' : 'Actor_bg2') do |frame|
      contents.blt(rect.x, rect.y, frame, frame.rect)
    end
    bsresolution_gauge(rect.x, rect.y, 47, 20, actor.hp_rate, hp_gauge_color1, hp_gauge_color2)
    bsresolution_gauge(rect.x, rect.y, 42, 24, actor.mp_rate, mp_gauge_color1, mp_gauge_color2)
    if Saba::KisekiStatus::SHOW_TP
      bsresolution_gauge(rect.x, rect.y, 37, 28, actor.tp_rate, tp_gauge_color1, tp_gauge_color2)
    end
    @last_hps.push(actor.hp_rate)
    @last_mps.push(actor.mp_rate)
    @last_tps.push(actor.tp_rate)
  end

  def bsresolution_gauge(origin_x, origin_y, x, y, rate, color1, color2)
    px = origin_x + BSResolutionFix.pixels(x)
    py = origin_y + BSResolutionFix.pixels(y + line_height - 8)
    width = BSResolutionFix.pixels(50)
    one = BSResolutionFix.pixels(1)
    two = BSResolutionFix.pixels(2)
    # Round boundaries, rather than each thickness independently.
    contents.fill_rect(px - two, py - one, width + two * 2,
      BSResolutionFix.pixels(3) + one, text_color(15))
    contents.fill_rect(px - one, py - two, width + one * 2,
      BSResolutionFix.pixels(4) + two, text_color(15))
    contents.fill_rect(px, py, width, two, gauge_back_color)
    fill = (width * [[rate, 0].max, 1].min).floor
    contents.gradient_fill_rect(px, py, fill, two, color1, color2) if fill > 0
  end
  # END KISEKI DRAWING


end
end

if defined?(Prico)
  # The three-window version uses different constants from the single-window one.
  { :WindowY1 => 110, :WindowY2 => 170, :WindowY3 => 230 }.each do |name, bottom|
    if Prico.const_defined?(name)
      Prico.send(:remove_const, name)
      Prico.const_set(name, Graphics.height - bottom)
    end
  end
end

if Spriteset_Map.method_defined?(:bmsp_mapfog_update_fog)
class Spriteset_Map
  alias bsresolution_update_fog bmsp_mapfog_update_fog
  def bmsp_mapfog_update_fog
    bsresolution_update_fog
    # Darkness masks cover the screen once. Ordinary moving fog still tiles.
    bitmap = @bmsp_fog.bitmap
    if bitmap && @bmsp_fog_name =~ /\Akurayami/i
      @bmsp_fog.zoom_x = Graphics.width.to_f / bitmap.width
      @bmsp_fog.zoom_y = Graphics.height.to_f / bitmap.height
      @bmsp_fog.ox = @bmsp_fog.oy = 0
    else
      @bmsp_fog.zoom_x = @bmsp_fog.zoom_y = 1.0
    end
  end
end

end

# Additional game menus share the same final-size font/icon/row metrics.
[ :Window_SkillList, :Window_SystemOptions, :Window_ActorCommand,
  :Window_PartyCommand, :Window_BattleStatus, :Window_BattleEnemy ].each do |name|
  next unless Object.const_defined?(name)
  Object.const_get(name).send(:include, BSResolutionFix::WindowMetrics)
end

if defined?(Window_SkillList)
  # BSFixes defines draw_item_name directly on this class.
  Window_SkillList.send(:define_method, :draw_item_name,
    BSResolutionFix::WindowMetrics.instance_method(:draw_item_name))
end

class Window_SkillList
  def draw_item(index)
    skill = @data[index]
    return unless skill
    rect = item_rect(index)
    rect.width -= BSResolutionFix.pixels(4)
    cost = @actor.skill_tp_cost(skill)
    cost = @actor.skill_mp_cost(skill) if cost <= 0
    reserved = cost > 0 ? text_size(cost.to_s).width + BSResolutionFix.pixels(8) : 0
    draw_item_name(skill, rect.x, rect.y, enable?(skill), rect.width - reserved)
    draw_skill_cost(rect, skill)
  end
end

class Window_ActorCommand
  alias bsresolution_actor_width window_width
  def window_width
    [BSResolutionFix.pixels(bsresolution_actor_width), Graphics.width].min
  end
end

class Window_PartyCommand
  alias bsresolution_party_width window_width
  def window_width
    width = bsresolution_party_width
    width == Graphics.width ? width : [BSResolutionFix.pixels(width), Graphics.width].min
  end
end

class Window_BattleStatus
  # BattleCommand/ATB/ED use fixed coordinates inside the status rows.
  # Lay out the face, name, state icons and HP/MP/AP in the actual row width.
  alias bsresolution_battle_draw_item draw_item
  alias bsresolution_battle_ap_index draw_actor_ap_index
  def bsresolution_status_layout(index)
    rect = item_rect_for_text(index)
    gap = BSResolutionFix.pixels(8)
    face_width = BSResolutionFix.pixels(96)
    name_width = BSResolutionFix.pixels(100)
    icons_width = BSResolutionFix.pixels(48)
    x = rect.x + face_width + name_width + icons_width + gap * 3
    remaining = [rect.x + rect.width - x, 1].max
    hp_width = ((remaining - gap * 2) * 0.38).to_i
    mp_width = ((remaining - gap * 2) * 0.27).to_i
    ap_width = remaining - gap * 2 - hp_width - mp_width
    [rect, face_width, name_width, icons_width, gap, x, hp_width, mp_width, ap_width]
  end
  def draw_item(index)
    return bsresolution_battle_draw_item(index) if BSResolutionFix.scale == 1.0
    actor = $game_party.battle_members[index]
    rect, face_width, name_width, icons_width, gap, x, hp_width, mp_width, ap_width = bsresolution_status_layout(index)
    face = Cache.face(actor.face_name)
    source = BSFaceSheet.rect(face, actor.face_index, ED::BTL_FACE_RECT_X,
      ED::BTL_FACE_RECT_Y, ED::BTL_FACE_RECT_WIDTH, ED::BTL_FACE_RECT_HEIGHT)
    contents.stretch_blt(Rect.new(rect.x, rect.y, face_width,
      BSResolutionFix.pixels(ED::BTL_FACE_RECT_HEIGHT)), face, source)
    draw_actor_name(actor, rect.x + face_width + gap, rect.y, name_width)
    draw_actor_icons(actor, rect.x + face_width + name_width + gap * 2, rect.y, icons_width)
    bsresolution_resource(actor, x, rect.y, hp_width, :hp)
    bsresolution_resource(actor, x + hp_width + gap, rect.y, mp_width, :mp)
    draw_actor_ap_index(index)
  end
  def bsresolution_resource(actor, x, y, width, kind)
    hp = kind == :hp
    rate = hp ? actor.hp_rate : actor.mp_rate
    color1 = hp ? hp_gauge_color1 : mp_gauge_color1
    color2 = hp ? hp_gauge_color2 : mp_gauge_color2
    draw_gauge(x, y, width, rate, color1, color2)
    label = BSResolutionFix.pixels(32)
    change_color(system_color)
    draw_text(x, y, label, line_height, hp ? Vocab::hp_a : Vocab::mp_a)
    change_color(hp ? hp_color(actor) : mp_color(actor))
    current = hp ? actor.hp : actor.mp
    maximum = hp ? actor.mhp : actor.mmp
    draw_text(x + label, y, [width - label, 0].max, line_height, "#{current}/#{maximum}", 2)
  end
  def draw_actor_ap_index(index)
    return bsresolution_battle_ap_index(index) if BSResolutionFix.scale == 1.0
    rect, face_width, name_width, icons_width, gap, x, hp_width, mp_width, width = bsresolution_status_layout(index)
    actor = $game_party.battle_members[index]
    x += hp_width + mp_width + gap * 2
    contents.clear_rect(x, rect.y, width, line_height)
    colors = actor.ap_gauge_color
    gauge_y = rect.y + line_height - BSResolutionFix.pixels(8)
    thickness = BSResolutionFix.pixels(6)
    contents.fill_rect(x, gauge_y, width, thickness, colors[0])
    fill = (width * [[actor.ap_rate, 0].max, 1].min).to_i
    contents.gradient_fill_rect(x, gauge_y, fill, thickness, colors[1], colors[2]) if fill > 0
    if ATB::AP_GAUGE_NAME
      change_color(ATB::AP_GAUGE_NAME_TEXT_COLOR)
      draw_text(x, rect.y, width, line_height, 'AP')
    end
    if ATB::AP_GAUGE_PERCENT
      change_color(ATB::AP_GAUGE_MAIN_TEXT_COLOR)
      value = actor.ap_rate_100.to_s
      value += '%' if ATB::AP_GAUGE_SIGN
      draw_text(x, rect.y, width, line_height, value, 2)
    end
  end
end

class Sprite_Battler
  alias bsresolution_battler_initialize initialize
  def initialize(viewport, battler = nil)
    bsresolution_battler_initialize(viewport, battler)
    # The perspective formula must use design coordinates, not scaled screen_y.
    if battler && !battler.actor? && @use_tmbsprex && defined?(TMBSPREX)
      unless TMBSPREX::NO_ZOOM_TROOP.include?($game_troop.troop.id) || TMBSPREX::NO_ZOOM_ENEMY.include?(battler.enemy.id)
        self.zoom_x = (battler.screen_y * 480.0 / Graphics.height - 312.0) * 0.005 + 1.0
      end
    end
  end
  alias bsresolution_battler_update update
  def update
    # Remove only our last multiplier before breathing/perspective updates.
    if @bsresolution_enemy_scale
      self.zoom_x /= @bsresolution_enemy_scale
      self.zoom_y /= @bsresolution_enemy_scale
      @bsresolution_enemy_scale = nil
    end
    bsresolution_battler_update
    if @battler && !@battler.actor?
      factor = BSResolutionFix.scale
      self.zoom_x *= factor
      self.zoom_y *= factor
      @bsresolution_enemy_scale = factor
    end
  end
end
end
end
