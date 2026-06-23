#==============================================================================
# BSMP Hooks — part 5/5 (loads last): patches into the game's own classes
# (Spriteset_Map / Sprite_Character / Game_Player / Game_Map / Scene_*), the
# $bsmp_client / $bsmp_server / $bsmp_players wiring and the debug console
# commands. These reopen top-level RPG Maker classes, so they live outside
# module BSMP. See 1200 - BSMP Core.rb.
#
# Console commands:
#   make_server(type, max_players)   make_test_client    make_test_player
#   delete_test_player               send_c2s_packet(type, data)
#   read_s2c_packets                 set_skin(actor_id)  set_nick(nick)
#   show_test_window                 mech
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-Hooks"]
$imported["IDL-BSMP-Hooks"] = "1.0"

if defined?(BSMP)

class Spriteset_Map
  attr_reader :character_sprites
  attr_reader :bsmp_players

  alias bsmp_orig_initialize initialize
  alias bsmp_orig_create_characters create_characters
  alias bsmp_orig_update update
  alias bsmp_orig_dispose dispose

  def create_characters
    bsmp_orig_create_characters
    @bsmp_players = {}
    $bsmp_players.bsmp_players.each_value do |player|
      next if player.map_id != $game_map.map_id
      add_player(player)
    end
  end

  def update
    bsmp_orig_update
    bsmp_reconcile_players
    bsmp_broadcast_mobs
    update_bsmp_status
  end

  # Map owner only: every MOB_SYNC_INTERVAL frames, broadcast the positions of all
  # moving events on this map so non-owners glide their copies to match. Skipped when
  # no remote player shares our map (no one to render them), so an owner wandering
  # alone spends nothing. "Only movers" + zlib keep the packet small.
  def bsmp_broadcast_mobs
    return if not BSMP::World.map_owner_here?
    return if not $game_map
    @bsmp_mob_tick = (@bsmp_mob_tick || 0) + 1
    return if @bsmp_mob_tick < BSMP::Config::MOB_SYNC_INTERVAL
    @bsmp_mob_tick = 0
    return if not bsmp_guest_on_this_map?
    events = $game_map.events.values
    # Balloons can appear on any event (a static enemy shows "!" before it starts
    # moving), so scan all of them; positions only matter for movers.
    events.each { |e| bsmp_detect_balloon(e) }
    movers = events.select { |e| e.bsmp_mover? }
    return if movers.empty?
    data = $game_map.map_id.to_s
    movers.each do |e|
      forming = e.instance_variable_get(:@forming) ? 1 : 0 rescue 0
      data << ";#{e.id},#{e.x},#{e.y},#{e.direction},#{e.bsmp_base_opacity},#{e.move_speed},#{e.transparent ? 1 : 0},#{forming}"
      BSMP.debug_log { "bcast mob #{e.id} base_op=#{e.bsmp_base_opacity} op=#{e.opacity} tr=#{e.transparent}" } if e.bsmp_base_opacity != 255 or e.transparent
    end
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::MOB_SYNC, 0, data))
  end

  # Rising-edge balloon detection. A mob's balloon_id (the "!" notice etc.) is set
  # by AI as a direct ivar write, so we watch the value rather than the write: when
  # it goes 0 -> N (or N -> M), broadcast MOB_BALLOON once. Sprite_Character zeroes
  # balloon_id when the animation ends, which re-arms the edge. Per-map state in
  # @bsmp_balloons (Scene_Map is recreated per map, so it resets on transfer).
  def bsmp_detect_balloon(event)
    @bsmp_balloons ||= {}
    current = event.balloon_id
    if current > 0 and @bsmp_balloons[event.id] != current
      bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::MOB_BALLOON, 0,
        "#{$game_map.map_id};#{event.id};#{current}"))
    end
    @bsmp_balloons[event.id] = current
  end

  def bsmp_guest_on_this_map?
    return false if not $bsmp_players
    $bsmp_players.bsmp_players.each_value do |pl|
      return true if pl.map_id == $game_map.map_id
    end
    false
  end

  # Self-healing: keep the on-screen sprites matching the players currently on this
  # map, and advance their interpolation. Doing add/remove only on join/leave/map
  # packets was racy -- a player joining mid-map had map_id 0 at add() time and only
  # appeared after a map change (create_characters). Reconciling every frame fixes
  # that; add_player and the dispose below are idempotent/cheap.
  def bsmp_reconcile_players
    $bsmp_players.bsmp_players.each_value do |character|
      next if character.map_id != $game_map.map_id
      add_player(character)
      character.update
    end
    @bsmp_players.keys.each do |player_id|
      player = $bsmp_players[player_id]
      next if player and player.map_id == $game_map.map_id
      sprite = @bsmp_players.delete(player_id)
      next if sprite.nil?
      @character_sprites.delete(sprite)
      sprite.dispose
    end
  end

  def dispose
    dispose_bsmp_windows
    bsmp_orig_dispose
  end

  # Show the status panel while networking runs; create it lazily (so toggling the
  # server on/off mid-map works) and drop everything the moment networking stops.
  def update_bsmp_status
    if bsmp_network_running?
      @bsmp_status_window ||= BSMP::Status_Window.new
      @bsmp_status_window.update
      update_bsmp_roster
    else
      dispose_bsmp_windows
    end
  end

  # Full roster overlay while the roster key is held (scoreboard-style).
  def update_bsmp_roster
    if ModLoader.respond_to?(:input_press?) and ModLoader.input_press?(BSMP.settings.roster_key)
      @bsmp_roster_window ||= BSMP::Roster_Window.new
      @bsmp_roster_window.update
    elsif @bsmp_roster_window
      @bsmp_roster_window.dispose
      @bsmp_roster_window = nil
    end
  end

  def dispose_bsmp_windows
    if @bsmp_status_window
      @bsmp_status_window.dispose
      @bsmp_status_window = nil
    end
    if @bsmp_roster_window
      @bsmp_roster_window.dispose
      @bsmp_roster_window = nil
    end
  end

  def add_player(player)
    return if @bsmp_players.key?(player.player_id)
    sprite = Sprite_Character.new(@viewport1, player)
    @bsmp_players[player.player_id] = sprite
    @character_sprites.push(sprite)
  end

  def delete_player(player)
    return if not @bsmp_players.key?(player.player_id)
    sprite = @bsmp_players.delete(player.player_id)
    @character_sprites.delete(sprite)
    sprite.dispose
  end

  def update_player(player)
    on_map = player.map_id == $game_map.map_id
    shown = @bsmp_players.key?(player.player_id)
    if on_map and not shown
      # joined our map
      add_player(player)
    elsif shown and not on_map
      # left our map
      delete_player(player)
    end
  end
end

class Sprite_Character

  attr_reader :nickname_sprite

  alias bsmp_orig_initialize initialize
  alias bsmp_orig_update update
  alias bsmp_orig_dispose dispose
  alias bsmp_orig_update_position update_position

  def initialize(viewport, character)
    bsmp_orig_initialize(viewport, character)
    @character_nickname = nil
  end

  def dispose
    bsmp_orig_dispose
    @nickname_sprite.dispose if @nickname_sprite
  end

  def nickname_width
    return 64
  end

  def nickname_height
    return 20
  end

  def create_nickname_sprite
    @nickname_sprite = Sprite_Base.new(self.viewport)
    @nickname_sprite.bitmap = Bitmap.new(nickname_width, nickname_height)
    @nickname_sprite.bitmap.font.size = 21
    @nickname_sprite.x = self.x - nickname_width / 2
    @nickname_sprite.y = self.y - 32 - nickname_height
    @nickname_sprite.z = 100
  end

  def nickname_changed?
    return @character_nickname != @character.nickname
  end

  def update
    bsmp_orig_update
    update_nickname if nickname_changed?
  end

  def update_nickname
    @character_nickname = @character.nickname

    create_nickname_sprite if not @nickname_sprite
    @nickname_sprite.bitmap.fill_rect(0, 0, @nickname_sprite.bitmap.width, @nickname_sprite.bitmap.height, Color.new(0, 0, 0, 0))

    off_x = [0, @nickname_sprite.bitmap.width - @nickname_sprite.bitmap.text_size(@character_nickname).width].max / 2
    @nickname_sprite.bitmap.draw_text(off_x, 0, @nickname_sprite.bitmap.width, @nickname_sprite.bitmap.height, @character_nickname)
  end

  def update_position
    bsmp_orig_update_position
    if @nickname_sprite
      @nickname_sprite.x = self.x - nickname_width / 2
      @nickname_sprite.y = self.y - 32 - nickname_height
    end
  end

  def character_pos_changed?
    @old_x != self.x or @old_y != self.y
  end

  def update_nickname_pos
    @nickname_sprite.x = self.x - nickname_width / 2
    @nickname_sprite.y = self.y - 32 - nickname_height
  end

end

class Game_Player

  alias bsmp_orig_update update
  alias bsmp_orig_refresh refresh
  alias bsmp_orig_move_straight move_straight
  alias bsmp_orig_move_diagonal move_diagonal

  attr_accessor :last_real_move_speed

  def update
    last_moving = moving?
    bsmp_orig_update
    send_pos_packet if last_moving and not moving?
    if @last_real_move_speed != real_move_speed
      @last_real_move_speed = real_move_speed
      send_speed_packet
    end
  end

  def refresh
    bsmp_orig_refresh

    return if not bsmp_network_running?
    # Game_Player#refresh fires in bursts (party/leader changes, transfers, battle entry),
    # almost always with the SAME graphic/nick — broadcasting each one floods peers (and
    # their console logging) and visibly stutters on a battle transition. Send only when
    # it actually changed.
    sig = "#{@character_name};#{@character_index};#{self.actor ? self.actor.name : ''}"
    return if sig == @bsmp_last_char_sig
    @bsmp_last_char_sig = sig
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_CHARACTER, 0, sig))
  end

  def move_straight(d, turn_ok = true)
    bsmp_orig_move_straight(d, turn_ok) if not $disable_player_move

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_MOVED, 0, d.to_s)
    bsmp_send_packet(packet)
  end

  def move_diagonal(horz, vert)
    bsmp_orig_move_diagonal(horz, vert)

    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_MOVED_DIAG, 0, "#{horz};#{vert}")
    bsmp_send_packet(packet)
  end

  def send_pos_packet
    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_POS, 0, "#{self.x};#{self.y}")
    bsmp_send_packet(packet)
  end

  def send_speed_packet
    return if not bsmp_network_running?
    packet = BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_SPEED, 0, self.real_move_speed.to_s)
    bsmp_send_packet(packet)
  end

  def bsmp_enable_nickname
    @nickname = $game_party.battle_members[0].name
  end

end

class Game_Character

  attr_accessor :nickname

end

class Scene_Map

  attr_reader :spriteset

end

class Scene_Base

  alias bsmp_orig_update update
  def update
    bsmp_orig_update
    SteamAPI.run_callbacks
    bsmp_read_packets
    bsmp_update_ping
    BSMP::UI.update_sync_overlay
    # Polling fallback for map-ownership setup. Our Game_Map#setup alias above is
    # the primary hook, but some BS2 mods redefine Game_Map#setup without preserving
    # earlier aliases, blowing the hook away. Catching the map change here (one
    # integer compare per frame, every scene) is independent of the alias chain —
    # on_map_setup is idempotent on the same map_id, so the polling is a no-op once
    # owned_map_id matches the current map.
    if $game_map and BSMP::World.owned_map_id != $game_map.map_id
      BSMP::World.on_map_setup($game_map.map_id)
    end
  end

end

class Game_Map

  alias bsmp_orig_setup setup

  def setup(map_id)
    bsmp_orig_setup(map_id)
    # Note: ownership re-evaluation lives in the Scene_Base#update polling path
    # (one level up), not here. Some BS2 mods redefine Game_Map#setup without
    # preserving aliases, which would blow this hook away; the polling fallback is
    # independent and idempotent on the same map_id, so it covers every case.
    return if not bsmp_network_running?
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::PLAYER_CHANGED_MAP, 0, BSMP.current_map_payload))
  end

end

# Loading a save (or starting a new game) replaces our world ($game_switches/
# variables/self_switches) with the save's / defaults. A connected guest must
# re-adopt the host's world afterwards. We block on the snapshot HERE, before the
# scene transitions to the map, so the map never renders with the stale world (an
# overlay driven from Scene#update can't cover the load's Graphics.transition).
# Covers F12 too: RGSSReset keeps globals/connection and just restarts the scene
# loop, so the guest re-loads a save while still connected.
module DataManager
  class << self
    alias bsmp_orig_load_game load_game
    def load_game(index)
      result = bsmp_orig_load_game(index)
      $bsmp_client.sync_world_blocking if $bsmp_client and $bsmp_client.connected?
      result
    end

    alias bsmp_orig_setup_new_game setup_new_game
    def setup_new_game
      bsmp_orig_setup_new_game
      $bsmp_client.sync_world_blocking if $bsmp_client and $bsmp_client.connected?
    end
  end
end

# --- Live world-state sync: broadcast a fact whenever a SHARED flag is written
# locally. The anti-echo guard ($bsmp_applying_fact) suppresses re-broadcast while
# we're applying a received fact / world snapshot. self-switches are all shared.

class Game_Switches
  alias bsmp_orig_set []=
  def []=(switch_id, value)
    bsmp_orig_set(switch_id, value)
    return if $bsmp_applying_fact
    return if not bsmp_network_running?
    return if not BSMP::World.shared_switch?(switch_id)
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::SWITCH_CHANGED, 0, "#{switch_id};#{value ? 1 : 0}"))
  end
end

class Game_Variables
  alias bsmp_orig_set []=
  def []=(variable_id, value)
    bsmp_orig_set(variable_id, value)
    return if $bsmp_applying_fact
    return if not bsmp_network_running?
    return if not BSMP::World.shared_variable?(variable_id)
    # Shared variables are assumed integer (story counters); extend with the World
    # value codec later if a shared var ever holds something else.
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::VARIABLE_CHANGED, 0, "#{variable_id};#{value.to_i}"))
  end
end

class Game_SelfSwitches
  alias bsmp_orig_set []=
  def []=(key, value)
    bsmp_orig_set(key, value)
    # Debug-only: fires on EVERY self-switch write — including the hundreds set while
    # APPLYING a world snapshot / live deltas (the guard below only stops re-broadcast,
    # not this log). debug_log's block form keeps the message unbuilt unless debug is
    # on, so a snapshot apply / flag-heavy battle event pays nothing here when off.
    # defined?(BSMP) because this is a reopened core class that can fire pre-BSMP.
    BSMP.debug_log { "set self_switch #{key.inspect}=#{value} applying=#{$bsmp_applying_fact} net=#{bsmp_network_running?}" } if defined?(BSMP)
    return if $bsmp_applying_fact
    return if not bsmp_network_running?
    bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::SELF_SWITCH_CHANGED, 0, "#{key[0]};#{key[1]};#{key[2]};#{value ? 1 : 0}"))
  end
end

# --- BSMP globals + debug console commands ---

$bsmp_applying_fact = false
$bsmp_applying_loot = false

$bsmp_client = BSMP::Client.new()
$bsmp_server = BSMP::Server.new()

def bsmp_send_packet(packet)
  $bsmp_client.send_packet(packet) if $bsmp_client.connected?
  $bsmp_server.send_packet(packet) if $bsmp_server.running?
end

def bsmp_network_running?
  $bsmp_server.running? or $bsmp_client.connected?
end

def bsmp_read_packets
  $bsmp_server.read_packets if $bsmp_server.running?
  if $bsmp_client.connected?
    $bsmp_client.read_packets
    $bsmp_client.ensure_announced # re-announce once in-game (joined from the title)
  end
end

# Minimal network pump (Steam callbacks + incoming packets) for blocking wait loops that
# never reach Scene_Base#update — chiefly Scene_Battle's wait_for_message ("Появился …"
# emerge), animation/charge waits. Without this the host stops answering a guest's
# WORLD_REQUEST (and everything else) for the whole message, stranding a joiner until the
# message is dismissed. Read-only side; self-guarded so it's a no-op when not networked.
def bsmp_net_pump
  return unless defined?(SteamAPI)
  SteamAPI.run_callbacks
  bsmp_read_packets
end

# Our own last measured ping to the host (ms); -1 = host / not measured yet.
$bsmp_my_ping = -1
BSMP_PING_INTERVAL = 60 # frames between measurements (~1s)

# Only guests measure: each periodically reads its round-trip ping to the host and
# broadcasts it, so everyone's roster shows everyone's ping-to-host. The host is the
# anchor (no ping). Guarded on the native method so an older DLL just shows no ping.
def bsmp_update_ping
  return if not BSMP.guest?
  return if not SteamAPI.respond_to?(:get_session_ping)
  $bsmp_ping_timer = ($bsmp_ping_timer || 0) + 1
  return if $bsmp_ping_timer < BSMP_PING_INTERVAL
  $bsmp_ping_timer = 0
  return if not $bsmp_client.server_user_id
  $bsmp_my_ping = SteamAPI.get_session_ping($bsmp_client.server_user_id)
  bsmp_send_packet(BasicNetworkPacket.new(BSMP::Events::PLAYER_PING, 0, $bsmp_my_ping.to_s))
end

def set_nick(nick)
  $game_player.nickname = nick
end

def mech
  return SceneManager.scene.spriteset.character_sprites[-1]
end

def make_server(type = BSMP.settings.lobby_type, max_players = BSMP.settings.max_players)
  # $bsmp_server = BSMP::Server.new
  $bsmp_client.leave_lobby if $bsmp_client.connected?
  $bsmp_server.create_lobby(type, max_players)
end

def make_test_client
  # $bsmp_client = BSMP::Client.new
  return if not $bsmp_server.running?
  $bsmp_client.read_channel_id = 1
  $bsmp_client.join_lobby($bsmp_server.lobby_id)
end

def make_test_player
  return if not $bsmp_server.running?
  player_id = $bsmp_server.get_lobby_owner

  client = BSMP::ServerClient.new(player_id, 1)
  $bsmp_server.add_client(client)
  $bsmp_client.update_player_data
end

def delete_test_player
  return if not $bsmp_server.running?
  player_id = $bsmp_server.get_lobby_owner

  client = $bsmp_server.find_client(player_id)
  $bsmp_server.delete_client(client) if client
end

def send_c2s_packet(type, data)
  return if not $bsmp_client.connected?
  packet = BasicNetworkPacket.new(type, 0, data)
  $bsmp_client.send_packet(packet)
end

def read_s2c_packets
  return if not $bsmp_server.running?
  $bsmp_server.read_packets
end

def set_skin(actor_id)
  actor = $data_actors[actor_id]
  return "Actor not found" if not actor
  $game_player.actor.set_graphic(actor.character_name, actor.character_index, actor.face_name, actor.face_index)
  $game_player.refresh
end

def show_test_window
  $bwnd = BSMP::Progress_Window.new()
  $bwnd.text = BSMP.t("bsmp.save_transfer")
  $bwnd.progress = 0.3
  $game_temp.streffect.push($bwnd)
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-Hooks"]
