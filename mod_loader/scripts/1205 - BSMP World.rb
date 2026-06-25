#==============================================================================
# BSMP World — part 1b/5: world-state serialization. Turns the host-canonical
# shared world ($game_switches / $game_variables / $game_self_switches) into a
# compact binary blob and back, for the join-time world dump (and later the
# session write-back). No Marshal (RCE-safe); the transport zlib-compresses the
# blob automatically once it crosses the size threshold. See 1200 - BSMP Core.rb.
#
# Format (version-tagged, little bit-twiddling, all ints LEB128 varint):
#   u8   FORMAT
#   u8   MODE  (0 = filtered/shared-only, 1 = full/wholesale) — stamped by the host's
#              BSMP.settings.world_snapshot_full, so the receiver applies the matching mode
#   switches:   FULL     -> varint N, then ceil(N/8) packed bits (index 1..N)
#               FILTERED -> varint COUNT, then COUNT * [varint shared_id, u8 value]
#   variables:  FULL     -> varint COUNT, then COUNT * [varint index, value] (all non-zero)
#               FILTERED -> same shape, but only the SHARED non-zero vars
#                   value = u8 tag + payload; recursive. Tags: 0 int (zigzag),
#                   1 string (len+bytes), 2 array (count + values), 3 true, 4 false,
#                   5 nil, 6 float (8 B LE). Unknown classes -> logged, stored as nil.
#   self-switches: varint COUNT, then COUNT * [varint map_id, varint event_id, u8 ch]
#                   (always world state — same in both modes)
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-World"]
$imported["IDL-BSMP-World"] = "1.0"

if defined?(BSMP)

module BSMP

  module World

    # Bump when the wire layout below changes incompatibly.
    FORMAT = 4   # 3: added covenant spirits section. 4: MODE byte + filtered (shared-only) snapshot

    SELF_SWITCH_CHARS = "ABCD"

    # --- shared world-state classification (live sync) ------------------------
    # Which switches/variables are part of the shared world (vs peer-local), and
    # whether an event page is host-owned world progression. Kept here next to the
    # snapshot dump/load, which walks the same Config shared-id sets. self-switches
    # are always shared, so they have no predicate.

    def self.shared_switch?(id)
      Config::SHARED_SWITCH_IDS.include?(id) or
        Config::SHARED_SWITCH_RANGES.any? { |r| r.include?(id) }
    end

    def self.shared_variable?(id)
      Config::SHARED_VARIABLE_IDS.include?(id) or
        Config::SHARED_VARIABLE_RANGES.any? { |r| r.include?(id) }
    end

    # The concrete shared id sets (IDS + expanded RANGES), clamped to the live table size,
    # unique + sorted — the FILTERED snapshot dump/load walks exactly these. Built per call
    # (only at join/resync, so cheap) so a Config edit is picked up with no caching.
    def self.shared_switch_id_list
      ids = Config::SHARED_SWITCH_IDS.dup
      Config::SHARED_SWITCH_RANGES.each { |r| ids.concat(r.to_a) }
      n = switch_count
      ids.select { |i| i >= 1 and i <= n }.uniq.sort
    end

    def self.shared_variable_id_list
      ids = Config::SHARED_VARIABLE_IDS.dup
      Config::SHARED_VARIABLE_RANGES.each { |r| ids.concat(r.to_a) }
      n = variable_count
      ids.select { |i| i >= 1 and i <= n }.uniq.sort
    end

    # An event page is "host-owned world progression" (a guest must not run its
    # autorun/parallel) when its activating condition hinges on a synced flag: any
    # self-switch (all shared), or a shared switch/variable. Takes a page condition
    # (RPG::Event::Page::Condition) so it's pure and unit-testable.
    def self.world_owned_condition?(c)
      return true if c.self_switch_valid
      return true if c.switch1_valid and shared_switch?(c.switch1_id)
      return true if c.switch2_valid and shared_switch?(c.switch2_id)
      return true if c.variable_valid and shared_variable?(c.variable_id)
      false
    end

    # A story cutscene that EVERY peer should watch despite being gated on a synced
    # flag (Config::SHARED_CUTSCENE_EVENTS). Drives two exceptions: guests run its
    # autorun (1245) and its self-switch latch stays per-peer / unsynced (1240).
    def self.shared_cutscene_event?(map_id, event_id)
      list = Config::SHARED_CUTSCENE_EVENTS[map_id]
      list ? list.include?(event_id) : false
    end

    # --- map ownership (per-map authority) ------------------------------------
    # True on the peer that the lobby host has authorised to own the CURRENT map. The
    # owner simulates mobs, streams MOB_SYNC, runs command_301 on touch, and acts as
    # the battle host for encounters on this map. Everyone else on the same map (incl.
    # the lobby host when not the owner) puppets and joins battles as mute clients.
    # Optimistic on map entry (set true before the reply arrives) so the owner starts
    # simulating immediately; flipped to false on a denied reply, self-healing via the
    # owner's MOB_SYNC.
    @map_owner_here = false
    @owned_map_id   = nil

    # Server-side registrar state. Lives on the lobby host only; on guests these stay
    # empty (the host is the single source of truth for who owns what). Kept here, not
    # on BSMP::Server, so all world logic (ownership rules + relay policy) lives in one
    # place — Net stays a thin transport.
    @server_map_owners    = {}  # {map_id => user_id}
    @server_map_mob_cache = {}  # {map_id => {event_id => {x,y,dir,op,speed,trans,forming}}}

    class << self
      attr_accessor :map_owner_here, :owned_map_id
      attr_reader   :server_map_owners, :server_map_mob_cache
    end

    def self.map_owner_here?
      @map_owner_here
    end

    # True only on the lobby host (where the registrar runs).
    def self.registrar?
      BSMP.host?
    end

    # Called from Game_Map#setup on every map change: release the previous map's
    # ownership (if we held it) and request the new one. Host claims locally; guests
    # ask the registrar. Optimistically assumes grant; the reply corrects if not.
    def self.on_map_setup(map_id)
      release_owned_map if @owned_map_id and @owned_map_id != map_id
      @owned_map_id = map_id
      @map_owner_here = true
      if BSMP.host?
        @map_owner_here = host_claim_map(map_id)
      elsif BSMP.guest?
        bsmp_send_packet(BasicNetworkPacket.new(Events::MAP_OWNERSHIP_REQUEST, 0, map_id.to_s))
      else
        @map_owner_here = true  # single-player / offline: always owner
      end
    end

    def self.release_owned_map
      return if @owned_map_id.nil?
      if BSMP.host?
        handle_ownership_release($bsmp_server.server_user_id, @owned_map_id)
      elsif BSMP.guest?
        bsmp_send_packet(BasicNetworkPacket.new(Events::MAP_OWNERSHIP_RELEASE, 0, @owned_map_id.to_s))
      end
      @map_owner_here = false
    end

    # Host granted (1) or denied (0) our request. On grant with a snapshot segment,
    # apply it to our local mobs so a handoff doesn't reset them mid-chase. On deny we
    # drop into puppet mode; the owner's MOB_SYNC will resync us.
    def self.on_map_ownership_reply(packet)
      parts = packet.data.split(';')
      map_id = parts[0].to_i
      granted = parts[1] == '1'
      snapshot = parts[2..-1]
      if granted
        @map_owner_here = true
        @owned_map_id = map_id
        apply_mob_snapshot(snapshot) unless snapshot.empty?
      else
        @map_owner_here = false
      end
    end

    # --- registrar entry-points (host-side; called from Net's on_packet_read) --
    # The host is the single authority on who owns which map; guests send it
    # MAP_OWNERSHIP_REQUEST / RELEASE and get back MAP_OWNERSHIP_REPLY. These three
    # methods are the only registrar mutation points; everything else is internal.

    # A peer asked to own this map. First-come-first-served: grant only if no one else
    # owns it. The reply carries the cached mob snapshot on a grant (so a handoff
    # resumes mid-state). Idempotent: same user re-asking for its own map re-grants.
    def self.handle_ownership_request(user_id, map_id)
      return unless registrar?
      granted = claim_map(map_id, user_id)
      send_ownership_reply(user_id, map_id, granted)
    end

    # The owner left the map (or this is the host's own setup-time release for its
    # previous map). Free the slot and try to hand it to another peer still standing
    # on it, sending them the snapshot we've cached from the previous owner's stream.
    def self.handle_ownership_release(user_id, map_id)
      return unless registrar?
      return if @server_map_owners[map_id] != user_id
      @server_map_owners.delete(map_id)
      reassign_map_ownership(map_id)
    end

    # A peer disconnected (lobby leave / drop). Free every map they owned and try to
    # reassign each to a remaining peer on it.
    def self.handle_player_leaved(user_id)
      return unless registrar?
      @server_map_owners.dup.each do |map_id, owner|
        next if owner != user_id
        @server_map_owners.delete(map_id)
        reassign_map_ownership(map_id)
      end
    end

    # The relay path calls this for every MOB_SYNC the host forwards, so the host
    # always has a fresh snapshot per map — used as the initial state when ownership
    # is reassigned. Host's own broadcasts don't pass through here (no relay to self),
    # which is fine: nothing reassigns the host's map to the host mid-sim.
    def self.cache_mob_snapshot_from_packet(packet)
      return unless registrar?
      return if packet.data.nil? or packet.data.empty?
      parts = packet.data.split(';')
      map_id = parts.shift.to_i
      snap = (@server_map_mob_cache[map_id] ||= {})
      parts.each do |entry|
        f = entry.split(',')
        next if f.size < 7
        id = f[0].to_i
        snap[id] = {
          :x       => f[1].to_i,
          :y       => f[2].to_i,
          :dir     => f[3].to_i,
          :op      => f[4].to_i,
          :speed   => f[5].to_i,
          :trans   => f[6].to_i,
          :forming => (f[7] ? f[7].to_i == 1 : false)
        }
      end
    end

    # --- registrar internals ---------------------------------------------------

    # First-come-first-served claim. The host itself goes through the same path
    # (host_claim_map), so being the lobby host doesn't auto-grant the current map —
    # only being first does. Returns true on grant.
    def self.claim_map(map_id, user_id)
      return false if @server_map_owners.key?(map_id) and @server_map_owners[map_id] != user_id
      @server_map_owners[map_id] = user_id
      true
    end

    # Host's local claim shortcut (used by on_map_setup on the host).
    def self.host_claim_map(map_id)
      return false unless registrar? and $bsmp_server
      claim_map(map_id, $bsmp_server.server_user_id)
    end

    # Free a map (owner left or disconnected) and reassign to any other peer still on
    # it. Reassign picks the lowest user_id present on the map (deterministic across
    # peers) so there's no race; the cached MOB_SYNC snapshot is appended to the grant
    # so the new owner resumes mid-state. The host itself only auto-reclaims when it's
    # standing on the freed map.
    def self.reassign_map_ownership(map_id)
      return unless registrar?
      return if @server_map_owners.key?(map_id)
      candidates = []
      # The lobby host is a candidate when it's standing on this map (it's not tracked
      # in $bsmp_players — that holds REMOTE peers — so we add it explicitly).
      candidates << $bsmp_server.server_user_id if $game_map and $game_map.map_id == map_id
      if $bsmp_players
        $bsmp_players.bsmp_players.each do |uid, pl|
          candidates << uid if pl.map_id == map_id
        end
      end
      return if candidates.empty?
      new_owner = candidates.min
      @server_map_owners[map_id] = new_owner
      send_ownership_reply(new_owner, map_id, true)
    end

    # Build and send a MAP_OWNERSHIP_REPLY to a single peer. data =
    # "map_id;1|0[;id,x,y,dir,op,speed,trans,forming;...]". The snapshot segment is
    # appended only on a grant and only if the host has cached state for this map.
    def self.send_ownership_reply(target_user_id, map_id, granted)
      return unless registrar? and $bsmp_server
      snap = granted ? (@server_map_mob_cache[map_id] || {}) : {}
      snap_str = snap.map { |id, s| "#{id},#{s[:x]},#{s[:y]},#{s[:dir]},#{s[:op]},#{s[:speed]},#{s[:trans]},#{s[:forming] ? 1 : 0}" }.join(';')
      data = "#{map_id};#{granted ? 1 : 0}"
      data << ";#{snap_str}" unless snap_str.empty?
      packet = BasicNetworkPacket.new(Events::MAP_OWNERSHIP_REPLY, $bsmp_server.server_user_id, data)
      if target_user_id == $bsmp_server.server_user_id
        # We're granting to ourselves (the host); deliver locally, no network hop.
        on_map_ownership_reply(packet)
      else
        client = $bsmp_server.find_client(target_user_id)
        $bsmp_server.send_packet_to(client, packet) if client
      end
    end

    # --- snapshot apply (client-side, on grant) -------------------------------

    # Apply a serialised mob snapshot ("id,x,y,dir,op,speed,trans,forming;...") to the
    # local events. Used on ownership grant to resume a previous owner's state without
    # resetting the chase. Mirrors Game_Event#bsmp_apply_sync but for the full roster.
    def self.apply_mob_snapshot(entries)
      return if $game_map.nil?
      entries.each do |entry|
        f = entry.split(',')
        next if f.size < 7
        ev = $game_map.events[f[0].to_i]
        next if ev.nil?
        ev.bsmp_apply_sync(f[1].to_i, f[2].to_i, f[3].to_i, f[4].to_i, f[5].to_i, f[6].to_i)
        # forming flag isn't a public ivar; reflectively set it for the symbol AI
        ev.instance_variable_set(:@forming, f[7].to_i == 1) if ev.instance_variable_defined?(:@forming)
      end
    end

    # True once a game is actually loaded (the $game_* objects exist). Handshake
    # must not dump/apply from the title screen.
    def self.ready?
      $game_switches and $game_variables and $game_self_switches and $data_system
    end

    # --- serialize -----------------------------------------------------------

    def self.dump
      w = "".force_encoding("ASCII-8BIT")
      w << [FORMAT].pack("C")
      # Host-side scope choice, stamped into the blob so the receiver applies the same mode.
      full = (BSMP.settings.world_snapshot_full rescue false) ? true : false
      w << [full ? 1 : 0].pack("C")
      dump_switches(w, full)
      dump_variables(w, full)
      dump_self_switches(w)
      dump_spirits(w)
      w
    end

    # Covenant tokens ("spirits") the party owns — world progress (they unlock summoning
    # that character in battle), so a joiner adopts the host's set.
    def self.dump_spirits(w)
      ids = $game_party ? ($game_party.instance_variable_get(:@spirits) || []) : []
      write_uint(w, ids.size)
      ids.each { |id| write_uint(w, id) }
    end

    def self.dump_switches(w, full)
      if full
        n = switch_count
        write_uint(w, n)
        bytes = Array.new((n + 7) / 8, 0)
        (1..n).each do |i|
          bytes[(i - 1) >> 3] |= (1 << ((i - 1) & 7)) if $game_switches[i]
        end
        w << bytes.pack("C*")
      else
        # Shared switches only: every shared id with its value (incl. false, so a host-OFF
        # clears a guest's stale ON). Peer-local switches are left out entirely.
        ids = shared_switch_id_list
        write_uint(w, ids.size)
        ids.each do |i|
          write_uint(w, i)
          w << [$game_switches[i] ? 1 : 0].pack("C")
        end
      end
    end

    def self.dump_variables(w, full)
      indices = if full
        (1..variable_count).select { |i| $game_variables[i] != 0 }
      else
        shared_variable_id_list.select { |i| $game_variables[i] != 0 }
      end
      write_uint(w, indices.size)
      indices.each do |i|
        write_uint(w, i)
        encode_value(w, $game_variables[i])
      end
    end

    def self.dump_self_switches(w)
      data = self_switch_data
      trues = data ? data.select { |_, v| v } : {}
      write_uint(w, trues.size)
      trues.each do |key, _|
        map_id, event_id, ch = key
        write_uint(w, map_id)
        write_uint(w, event_id)
        w << [SELF_SWITCH_CHARS.index(ch) || 0].pack("C")
      end
    end

    # --- deserialize (full replace; host world is canonical) -----------------

    def self.load(blob)
      return false if not ready?
      r = Reader.new(blob)
      format = r.u8
      if format != FORMAT
        p "BSMP::World: snapshot format #{format} != #{FORMAT}, ignoring"
        return false
      end
      full = (r.u8 == 1)  # host-stamped mode (0 = filtered/shared-only, 1 = full)
      # Applying the snapshot writes thousands of switches/vars; guard so the
      # live-sync setter hooks don't re-broadcast each one as a fact.
      $bsmp_applying_fact = true
      begin
        load_switches(r, full)
        load_variables(r, full)
        load_self_switches(r)
        load_spirits(r)
      ensure
        $bsmp_applying_fact = false
      end
      $game_map.need_refresh = true if $game_map
      true
    end

    def self.load_switches(r, full)
      if full
        n = r.uint
        raw = r.bytes((n + 7) / 8)
        (1..n).each do |i|
          bit = (raw.getbyte((i - 1) >> 3) >> ((i - 1) & 7)) & 1
          $game_switches[i] = (bit == 1)
        end
      else
        # Filtered: set only the shared ids the host sent; peer-local switches untouched.
        count = r.uint
        count.times do
          i = r.uint
          $game_switches[i] = (r.u8 == 1)
        end
      end
    end

    def self.load_variables(r, full)
      if full
        # Reset to default first so a guest's stray non-zero vars don't survive the
        # adoption of the host's world, then apply the host's non-zero set.
        (1..variable_count).each { |i| $game_variables[i] = 0 }
      else
        # Filtered: clear only the SHARED vars (so a host-zero shared var clears the guest's
        # stale value), leaving the guest's peer-local vars intact, then apply the host's set.
        shared_variable_id_list.each { |i| $game_variables[i] = 0 }
      end
      count = r.uint
      count.times do
        i = r.uint
        $game_variables[i] = decode_value(r)
      end
    end

    # Recursive value codec for variable contents. Only ever constructs plain
    # Ruby primitives (no object instantiation from peer data), so it's RCE-safe
    # unlike Marshal.load.
    def self.encode_value(w, v)
      case v
      when Integer
        w << [0].pack("C")
        write_sint(w, v)
      when String
        b = v.dup.force_encoding("ASCII-8BIT")
        w << [1].pack("C")
        write_uint(w, b.bytesize)
        w << b
      when Array
        w << [2].pack("C")
        write_uint(w, v.size)
        v.each { |e| encode_value(w, e) }
      when TrueClass
        w << [3].pack("C")
      when FalseClass
        w << [4].pack("C")
      when NilClass
        w << [5].pack("C")
      when Float
        w << [6].pack("C")
        w << [v].pack("E") # 8-byte little-endian double
      else
        # Unknown class (Hash, Symbol, custom object): can't safely transfer.
        # Store as nil so the stream stays deterministic; log it.
        p "BSMP::World: unsupported value class #{v.class}, stored as nil"
        w << [5].pack("C")
      end
    end

    def self.decode_value(r)
      tag = r.u8
      case tag
      when 0 then r.sint
      when 1 then r.bytes(r.uint).force_encoding("UTF-8")
      when 2
        Array.new(r.uint) { decode_value(r) }
      when 3 then true
      when 4 then false
      when 5 then nil
      when 6 then r.bytes(8).unpack("E")[0]
      else nil
      end
    end

    def self.load_self_switches(r)
      data = self_switch_data
      data.clear if data # full replace; we re-add only the host's true ones
      count = r.uint
      count.times do
        map_id   = r.uint
        event_id = r.uint
        ch       = SELF_SWITCH_CHARS[r.u8, 1] || "A"
        $game_self_switches[[map_id, event_id, ch]] = true
      end
    end

    def self.load_spirits(r)
      n = r.uint
      ids = []
      n.times { ids << r.uint }          # always drain the bytes first (spirits is the last
                                          # section, so an early return below is still safe)
      return unless $game_party and $game_party.respond_to?(:add_spirit)
      # add_spirit is idempotent; we're inside the apply_fact guard so it won't echo.
      ids.each { |id| $game_party.add_spirit(id) }
    end

    # --- counts / internals --------------------------------------------------

    def self.switch_count
      $data_system.switches.size - 1 # index 0 is unused
    end

    def self.variable_count
      $data_system.variables.size - 1 # index 0 is unused
    end

    def self.self_switch_data
      $game_self_switches.instance_variable_get(:@data)
    end

    # --- varint primitives ---------------------------------------------------

    # Unsigned LEB128.
    def self.write_uint(w, n)
      raise "write_uint: negative #{n}" if n < 0
      loop do
        b = n & 0x7F
        n >>= 7
        if n == 0
          w << [b].pack("C")
          break
        end
        w << [b | 0x80].pack("C")
      end
    end

    # Signed via zigzag (Bignum-safe: no fixed-width shift).
    def self.write_sint(w, n)
      write_uint(w, n >= 0 ? n * 2 : -n * 2 - 1)
    end

    # Cursor reader over a binary string.
    class Reader
      def initialize(str)
        @s = str.dup.force_encoding("ASCII-8BIT")
        @pos = 0
      end

      def u8
        b = @s.getbyte(@pos)
        @pos += 1
        b
      end

      def uint
        result = 0
        shift = 0
        loop do
          b = @s.getbyte(@pos)
          @pos += 1
          result |= (b & 0x7F) << shift
          break if (b & 0x80) == 0
          shift += 7
        end
        result
      end

      def sint
        z = uint
        z.even? ? z >> 1 : -((z + 1) >> 1)
      end

      def bytes(n)
        s = @s[@pos, n] || ""
        @pos += n
        s
      end

      def eof?
        @pos >= @s.bytesize
      end
    end

  end

  # --- map / location naming ------------------------------------------------
  # BSMP.* map-naming helpers (moved here from Core — they sit with the map logic).

  # Best human name for OUR current map: the lore display_name (the on-screen
  # banner) if set, else the editor tree name. Broadcast with PLAYER_CHANGED_MAP
  # so viewers show a real location without loading the peer's map.
  def self.current_location_name
    name = $game_map.display_name.to_s
    if name.empty? and $data_mapinfos and $data_mapinfos[$game_map.map_id]
      name = $data_mapinfos[$game_map.map_id].name.to_s
    end
    name
  end

  # PLAYER_CHANGED_MAP payload: "map_id;location_name".
  def self.current_map_payload
    "#{$game_map.map_id};#{current_location_name}"
  end

  # Local fallback name for an arbitrary map id (editor tree name); used when a
  # peer didn't send a name. "?" if unknown.
  def self.location_name(map_id)
    info = $data_mapinfos ? $data_mapinfos[map_id] : nil
    (info and info.name and not info.name.empty?) ? info.name : "?"
  end

  # Map-ownership reply dispatches straight to World (it owns the local owner flag
  # + the mob-snapshot apply), so Core's Events table needs no thin wrapper.
  module Events
    HANDLERS[MAP_OWNERSHIP_REPLY] = World.method(:on_map_ownership_reply)
  end

end # module BSMP

#==============================================================================
# ▼ Scene_Base / SceneManager — co-op suppression of the stock game-over
#------------------------------------------------------------------------------
# A non-owner (a peer whose current map is owned by someone else) ignores the
# default all_dead? -> Scene_Gameover trigger, regardless of which code path
# raises it. BS2 reaches Scene_Gameover from several places: Scene_Base's
# per-frame check_gameover, Game_Interpreter#command_311 (Change HP) when the
# change drops the party to 0, and command_353 (explicit Game Over event). All
# of them funnel through SceneManager.goto(Scene_Gameover), so a single guard
# there covers every path.
#
# Why: after a lost co-op battle, the owner's authoritative revive / respawn
# (death common event) lands a few frames late on non-owners via
# BATTLE_PARTY_SYNC. Without the guard, a transient all_dead? on a non-owner
# trips the stock game-over first — symptom: "walks around fine on solo maps,
# dies the moment they step onto a map with another player" (that's the
# moment they become non-owner and party_sync catches up). The map owner keeps
# the stock check — it owns the post-battle interpreter and the loss.
#==============================================================================
if defined?(BSMP) and BSMP::World.respond_to?(:map_owner_here?)
class Scene_Base
  if method_defined?(:check_gameover)
    alias bsmp_world_check_gameover check_gameover
    def check_gameover
      return if bsmp_network_running? and not BSMP::World.map_owner_here?
      bsmp_world_check_gameover
    end
  end
end

module SceneManager
  class << self
    alias bsmp_world_goto goto
    def goto(scene_class)
      # Suppress every transition into Scene_Gameover for a co-op non-owner. The
      # owner's defeat path (death common event / process_defeat on the owner's
      # BattleManager) is the authoritative outcome; a non-owner's local all_dead?
      # is a sync echo and must not strand it in the stock game-over screen.
      if scene_class == Scene_Gameover and bsmp_network_running? and not BSMP::World.map_owner_here?
        return
      end
      bsmp_world_goto(scene_class)
    end
  end
end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-World"]
