#==============================================================================
# BSMP Players Menu — co-op roster actions overlay (Stage 1: teleport to a player)
#
# Opened from the ModMenu "Co-op" tab ("Players"). A Window_Command overlay modeled
# on ModMenu_ListWindow (file 10): it reads raw VK (ModLoader.input_*) and nulls RPG
# Maker's Input while up (the freeze layer below composes with the ModMenu's own), so
# it works on the map / in battle / in a menu and freezes the game underneath. Lists
# the local player (a disabled info row — you can't teleport to yourself) plus every
# connected peer; OK on a peer opens a small action window. Stage 1 action: Teleport
# (a PERSONAL local reserve_transfer to the peer's map/tile — NOT broadcast, or it
# would drag the whole party). Host Kick is Stage 2 (a second action + a ban-list).
#
# Loads after 10 (ModMenu: Input freeze + Window_Command pattern) and the BSMP core.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-PlayersMenu"]
$imported["IDL-BSMP-PlayersMenu"] = "1.0"

if defined?(BSMP)

module BSMP
  module PlayersMenu
    @window         = nil
    @open_requested = false

    class << self
      attr_accessor :window

      # Active = our list window is up and driving input (its action child counts too,
      # since it lives only while the list window does). Drives the Input freeze below
      # and gates the ModMenu hotkey so F10 can't reopen the settings menu over us.
      def active?
        (@window and not @window.disposed? and not @window.closing) ? true : false
      end

      # The ModMenu action requests us (it closes itself first); we actually open on the
      # next Scene_Base#update, once the ModMenu is gone, to avoid a one-frame overlap.
      def request_open
        @open_requested = true
      end

      def open_if_requested
        return unless @open_requested
        return if modmenu_active?   # wait for the ModMenu to finish closing
        @open_requested = false
        return unless bsmp_network_running?
        return if active?
        @window = PlayersMenu_ListWindow.new
      end

      def modmenu_active?
        defined?(ModLoader) and defined?(ModLoader::ModMenu) and ModLoader::ModMenu.active?
      rescue
        false
      end

      # Per-frame from Scene_Base#update: drive our window and dispose it once it closes.
      def update
        open_if_requested
        return unless @window and not @window.disposed?
        @window.update
        if @window.closing
          @window.dispose
          @window = nil
        end
      end

      # Roster rows: the local player first (synthesized — self is never in $bsmp_players),
      # then every connected peer. { :id, :name, :location, :map, :x, :y, :is_self }.
      def rows
        list = []
        list << { :id => self_id, :name => self_name, :location => self_location,
                  :map => ($game_map ? $game_map.map_id : 0),
                  :x   => ($game_player ? $game_player.x : 0),
                  :y   => ($game_player ? $game_player.y : 0), :is_self => true }
        if $bsmp_players
          $bsmp_players.bsmp_players.each do |uid, pl|
            list << { :id => uid, :name => (pl.nickname || uid.to_s), :location => pl.location_name.to_s,
                      :map => pl.map_id, :x => pl.x, :y => pl.y, :is_self => false }
          end
        end
        list
      end

      def self_id
        if $bsmp_server and $bsmp_server.respond_to?(:server_user_id) and $bsmp_server.server_user_id
          $bsmp_server.server_user_id
        elsif $bsmp_client and $bsmp_client.respond_to?(:user_id)
          $bsmp_client.user_id
        else
          0
        end
      end

      def self_name
        a = ($game_party ? $game_party.battle_members[0] : nil)
        a ? a.name : "You"
      end

      def self_location
        BSMP.respond_to?(:current_location_name) ? BSMP.current_location_name.to_s : ""
      end

      # Teleport the LOCAL player to a peer's map/tile. Personal — no STORY_TRANSFER.
      # reserve_transfer just queues (performs on the next map update); the map-ownership
      # re-claim on arrival is automatic (on_map_setup). Refused mid-battle (it wouldn't
      # perform there) and for an unknown target map. Returns true on a queued transfer.
      def teleport_to(row)
        return false if $game_party and $game_party.in_battle
        return false if row[:map].nil? or row[:map].to_i <= 0
        return false unless $game_player
        $game_player.reserve_transfer(row[:map].to_i, row[:x].to_i, row[:y].to_i, 0)
        true
      end

      # Host kick (Stage 2). Hands off to the server, which bans the id for the session
      # (ignores its packets + REJECTs a rejoin), drops it, and sends a courtesy KICK.
      def kick(row)
        return false unless BSMP.respond_to?(:host?) and BSMP.host?
        return false if row.nil? or row[:is_self]
        return false unless $bsmp_server and $bsmp_server.respond_to?(:kick_player)
        $bsmp_server.kick_player(row[:id])
        true
      end
    end
  end
end

#==============================================================================
# ■ Input — freeze RPG Maker's own input while the Players menu is up (the menu
# navigates via raw VK). Composes with the ModMenu's identical override (file 10):
# each layer short-circuits when ITS menu is active, otherwise delegates down.
#==============================================================================
module Input
  class << self
    alias bsmp_pm_orig_trigger? trigger?
    alias bsmp_pm_orig_press?   press?
    alias bsmp_pm_orig_repeat?  repeat?
    alias bsmp_pm_orig_dir4     dir4
    alias bsmp_pm_orig_dir8     dir8
  end
  def self.trigger?(key); BSMP::PlayersMenu.active? ? false : bsmp_pm_orig_trigger?(key); end
  def self.press?(key);   BSMP::PlayersMenu.active? ? false : bsmp_pm_orig_press?(key);   end
  def self.repeat?(key);  BSMP::PlayersMenu.active? ? false : bsmp_pm_orig_repeat?(key);  end
  def self.dir4; BSMP::PlayersMenu.active? ? 0 : bsmp_pm_orig_dir4; end
  def self.dir8; BSMP::PlayersMenu.active? ? 0 : bsmp_pm_orig_dir8; end
end

#==============================================================================
# ■ The player list window. Real Window_Command (cursor/scroll/draw from the engine);
# only the input methods are overridden to read raw VK, since Input is nulled above.
#==============================================================================
class PlayersMenu_ListWindow < Window_Command
  K = ModLoader::Keyboard
  attr_reader :closing

  def initialize
    @closing       = false
    @rows          = BSMP::PlayersMenu.rows
    @action_window = nil
    @ok_armed      = false   # ignore OK until the confirm key (held over from the ModMenu
                             # action that opened us) is released once — else it bleeds through
    super(0, 0)
    self.x = (Graphics.width  - width)  / 2
    self.y = (Graphics.height - height) / 2
    self.z = 2100   # above the ModMenu (z 2000)
    select_first_enabled
  end

  def window_width;        (Graphics.width * 0.6).to_i; end
  def visible_line_number; [[@rows.size + 1, 1].max, 12].min; end

  def make_command_list
    @rows ||= BSMP::PlayersMenu.rows
    @rows.each do |row|
      label = row[:is_self] ? "#{row[:name]}  #{BSMP.t('bsmp.menu_you')}" : row[:name]
      add_command(label, :player, !row[:is_self], row)   # self row is a disabled info line
    end
    add_command(BSMP.t("bsmp.menu_close"), :close, true)
  end

  # name in a left column, location greyed in its own right column (each clipped to its
  # column width so a long location can't overlap the nickname).
  def draw_item(index)
    cmd     = @list[index]
    rect    = item_rect_for_text(index)
    enabled = command_enabled?(index)
    ext     = cmd[:ext]
    loc     = (ext.is_a?(Hash) ? ext[:location].to_s : "")
    if loc.empty?
      change_color(normal_color, enabled)
      draw_text(rect.x, rect.y, rect.width, line_height, cmd[:name])
    else
      gap    = 12
      name_w = (rect.width * 0.45).to_i
      loc_x  = rect.x + name_w + gap
      loc_w  = rect.width - name_w - gap
      change_color(normal_color, enabled)
      draw_text(rect.x, rect.y, name_w, line_height, cmd[:name])
      change_color(system_color, enabled)
      draw_text(loc_x, rect.y, loc_w, line_height, loc, 2)
    end
  end

  def select_first_enabled
    i = (0...item_max).find { |k| command_enabled?(k) }
    select(i || 0)
  end

  # super (Window_Selectable#update) runs our process_cursor_move / process_handling;
  # also tick the action child so its cursor animates while it's up.
  def update
    super
    @action_window.update if action_open?
  end

  #--- raw-VK input (Input is nulled while we're up) ---
  def vk_down?(*vks);    vks.any? { |vk| ModLoader.input_repeat?(vk) }; end
  def vk_pressed?(*vks); vks.any? { |vk| ModLoader.input_trigger?(vk) }; end

  def process_cursor_move
    return if action_open?
    return unless cursor_movable?
    last = @index
    move_index(+1) if vk_down?(K::DOWN, K::S)
    move_index(-1) if vk_down?(K::UP,   K::W)
    Sound.play_cursor if @index != last
  end

  def move_index(dir)
    return if item_max == 0
    i = @index
    item_max.times do
      i = (i + dir) % item_max
      break if command_enabled?(i)
    end
    select(i) if command_enabled?(i)
  end

  def confirm_held?
    ModLoader.input_press?(K::RETURN) or ModLoader.input_press?(K::SPACE)
  end

  def process_handling
    if action_open?
      @action_window.process_input
      return
    end
    return unless open? && active
    @ok_armed = true unless confirm_held?   # arm once the carryover press is released
    return request_close if vk_pressed?(K::ESC)
    process_ok if @ok_armed and vk_pressed?(K::RETURN, K::SPACE)
  end

  def process_ok
    return unless command_enabled?(@index)
    cmd = @list[@index]
    if cmd[:symbol] == :close
      Sound.play_cancel
      request_close
    elsif cmd[:symbol] == :player
      Sound.play_ok
      open_action(cmd[:ext])
    end
  end

  def open_action(row)
    @action_window = PlayersMenu_ActionWindow.new(self, row)
  end

  def action_open?
    @action_window and not @action_window.disposed?
  end

  def close_action
    @action_window.dispose if action_open?
    @action_window = nil
    @ok_armed = false   # re-guard: the confirm that closed the action shouldn't re-open it
  end

  def request_close
    return if @closing
    @closing = true
    close_action
    deactivate
  end

  def dispose
    close_action
    super
  end
end

#==============================================================================
# ■ Per-player action window (Stage 1: Teleport / Cancel; Stage 2 adds Kick). Driven
# by the list window's process_input call (no own update — it's not a scene ivar).
#==============================================================================
class PlayersMenu_ActionWindow < Window_Command
  K = ModLoader::Keyboard

  def initialize(list_window, row)
    @list_window = list_window
    @row         = row
    @ok_armed    = false   # ignore the confirm key held over from the list-window OK
    super(0, 0)
    self.x = (Graphics.width  - width)  / 2
    self.y = (Graphics.height - height) / 2
    self.z = 2200
  end

  def window_width; 260; end

  def make_command_list
    add_command(BSMP.t("bsmp.menu_teleport"), :teleport, teleport_ok?)
    add_command(BSMP.t("bsmp.menu_kick"),     :kick) if kick_available?
    add_command(BSMP.t("bsmp.menu_cancel"),   :cancel)
  end

  def teleport_ok?
    not ($game_party and $game_party.in_battle)
  end

  # Host only, and never on the self row.
  def kick_available?
    BSMP.respond_to?(:host?) and BSMP.host? and @row and not @row[:is_self]
  end

  def vk_down?(*vks);    vks.any? { |vk| ModLoader.input_repeat?(vk) }; end
  def vk_pressed?(*vks); vks.any? { |vk| ModLoader.input_trigger?(vk) }; end

  def confirm_held?
    ModLoader.input_press?(K::RETURN) or ModLoader.input_press?(K::SPACE)
  end

  # Called by the list window each frame while we're up.
  def process_input
    @ok_armed = true unless confirm_held?   # arm once the carryover press is released
    last = @index
    select((@index + 1) % item_max) if vk_down?(K::DOWN, K::S)
    select((@index - 1) % item_max) if vk_down?(K::UP,   K::W)
    Sound.play_cursor if @index != last
    return on_cancel if vk_pressed?(K::ESC)
    on_ok if @ok_armed and vk_pressed?(K::RETURN, K::SPACE)
  end

  def on_ok
    return unless command_enabled?(@index)
    case @list[@index][:symbol]
    when :teleport
      if BSMP::PlayersMenu.teleport_to(@row)
        Sound.play_ok
        @list_window.request_close   # close the whole menu -> the queued transfer runs
      else
        Sound.play_buzzer            # in battle / unknown map
      end
    when :kick
      if BSMP::PlayersMenu.kick(@row)
        Sound.play_ok
        @list_window.request_close
      else
        Sound.play_buzzer
      end
    when :cancel
      on_cancel
    end
  end

  def on_cancel
    Sound.play_cancel
    @list_window.close_action
  end
end

#==============================================================================
# ■ Scene integration. Drive the overlay every frame (it's not a scene ivar, so we
# update/dispose it ourselves), and block the ModMenu hotkey while we're up so F10
# can't stack the settings menu on top of us.
#==============================================================================
class Scene_Base
  alias bsmp_pm_update update
  def update
    bsmp_pm_update
    BSMP::PlayersMenu.update
  end

  # The overlay isn't a scene ivar (so it survives the ModMenu close that opened it),
  # which means dispose_all_windows won't drop it on a scene change. Dispose it here so
  # it can't leak a stray window across scenes.
  alias bsmp_pm_terminate terminate
  def terminate
    w = BSMP::PlayersMenu.window
    if w and not w.disposed?
      w.dispose
      BSMP::PlayersMenu.window = nil
    end
    bsmp_pm_terminate
  end

  if method_defined?(:modmenu_update_hotkey)
    alias bsmp_pm_modmenu_hotkey modmenu_update_hotkey
    def modmenu_update_hotkey
      return if BSMP::PlayersMenu.active?
      bsmp_pm_modmenu_hotkey
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-PlayersMenu"]
