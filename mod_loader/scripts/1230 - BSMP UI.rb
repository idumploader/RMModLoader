#==============================================================================
# BSMP UI — part 4/5: on-screen widgets. Window (top-right backdrop base),
# Timed_Window (auto-fading) and Progress_Window (caption + progress bar, used
# by the save-transfer UI). See 1200 - BSMP Core.rb.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-UI"]
$imported["IDL-BSMP-UI"] = "1.0"

if defined?(BSMP)

module BSMP

  class Window < Window_Base
    Z          = 188
    MARGIN_X   = 16
    BACK_COLOR = Color.new(0, 42, 102, 160)

    def initialize
      super(Graphics.width - window_width - MARGIN_X, 0, window_width, window_height)
      self.z = Z
      self.opacity = 0
      self.back_opacity = 0

      self.contents.fill_rect(0, 0, window_width, window_height, BACK_COLOR)
    end

    def window_height
      return line_height * 2
    end

    def window_width
      return Graphics.width / 2
    end

    def update

    end
  end

  class Timed_Window < Window

    TIME_FRAMES = 180
    OPACITY     = 32

    def initialize
      super
      @frame_count = 0
    end

    def update
      super
      @frame_count += 1
      if @frame_count >= TIME_FRAMES
        self.contents_opacity -= OPACITY
        dispose if self.contents_opacity == 0
      end
    end

    def refresh(caption, text = "")

    end
  end

  class Progress_Window < Window

    PROGRESS_HEIGHT = 5
    NOPROGRESS_COLOR = Color.new(200, 200, 200, 255)
    PROGRESS_COLOR = Color.new(136, 8, 8, 255)

    attr_reader :progress
    attr_reader :text

    def initialize
      super
      self.progress = 0.0
      @window_changed = false
    end

    def update
      super
      if @window_changed
        update_window_size
        update_progress
        @window_changed = false
      end
    end

    def window_height
      return line_height * 3 + 5 if @text
      return line_height * 2
    end

    def text=(text)
      @text = text
      @window_changed = true
    end

    def progress=(progress)
      @progress = progress
      @window_changed = true
    end

    def update_progress
      self.contents.fill_rect(0, 0, window_width, window_height, BACK_COLOR)

      off_y = line_height / 2
      if @text
        draw_text(MARGIN_X, off_y, self.contents.width - MARGIN_X * 2, line_height, @text)
        off_y += line_height + 5
      end
      @progress = [1.0, @progress].min
      self.contents.fill_rect(MARGIN_X, off_y, self.contents.width - MARGIN_X * 2, PROGRESS_HEIGHT, NOPROGRESS_COLOR)
      self.contents.fill_rect(MARGIN_X, off_y, self.contents.width * @progress - MARGIN_X * 2, PROGRESS_HEIGHT, PROGRESS_COLOR)
    end

    def update_window_size
      old_height = self.height
      self.height = window_height
      create_contents if old_height != self.height
    end

  end

  # Compact, always-on top-right plate: just role (HOST / CLIENT) and how many
  # players are online. Driven by the Spriteset_Map lifecycle (created lazily while
  # networking runs, disposed on map change / scene exit), so it follows map
  # transfers for free. Re-renders only when role/count changes, not every frame.
  # The full roster (nicknames) lives in the separate Roster_Window, not here, so
  # this plate stays small.
  class Status_Window < Window

    HOST_COLOR   = Color.new(120, 220, 140, 255)
    CLIENT_COLOR = Color.new(140, 190, 255, 255)

    def initialize
      @signature = nil
      super
      refresh
    end

    def window_width
      return 260
    end

    # This game runs a larger-than-default font, so the engine's line_height (24)
    # is too short and clips. Size the single row to the actual font instead.
    def row_height
      size = Font.respond_to?(:default_size) ? Font.default_size : 24
      [line_height, size + 8].max
    end

    # One line, symmetric padding (top+bottom standard_padding), so the text sits
    # centered with no lopsided gap.
    def window_height
      row_height + standard_padding * 2
    end

    def host?
      $bsmp_server and $bsmp_server.running?
    end

    def online_count
      ($bsmp_players ? $bsmp_players.bsmp_players.size : 0) + 1
    end

    def signature
      [host?, online_count]
    end

    def update
      sig = signature
      return if sig == @signature
      @signature = sig
      refresh
    end

    def refresh
      self.contents.fill_rect(0, 0, contents.width, contents.height, BACK_COLOR)
      self.contents.font.color = host? ? HOST_COLOR : CLIENT_COLOR
      role   = BSMP.t(host? ? "bsmp.role_host" : "bsmp.role_client")
      header = BSMP.t("bsmp.status_header") % [role, online_count]
      # Full contents height as the rect → vertically centered, symmetric.
      draw_text(MARGIN_X, 0, contents.width - MARGIN_X * 2, contents.height, header)
    end

  end

  # Full player roster overlay, centered, shown while BSMP.settings.roster_key is held
  # (scoreboard-style). Lists everyone — you first, then the remote players — with
  # the host marked. Created/disposed on demand by the Spriteset_Map hook and
  # resized to the current player count.
  class Roster_Window < Window

    HEAD_COLOR = Color.new(255, 230, 150, 255)
    HOST_COLOR = Color.new(120, 220, 140, 255)
    TEXT_COLOR = Color.new(255, 255, 255, 255)
    LOC_COLOR  = Color.new(180, 180, 180, 255)

    def initialize
      @signature = nil
      super
      recenter
      refresh
    end

    def window_width
      # Scale with the screen so the name and the (often long) location each get
      # their own column without overlapping.
      [[Graphics.width * 7 / 10, 520].max, Graphics.width - 32].min
    end

    def row_height
      size = Font.respond_to?(:default_size) ? Font.default_size : 24
      [line_height, size + 8].max
    end

    def window_height
      row_height * (1 + entries.size) + standard_padding * 2
    end

    # [name, location, ping, is_host, is_self] for everyone, local player first.
    def entries
      list = [[self_name, self_location, self_ping, host?, true]]
      remotes.each { |pl| list << [remote_name(pl), remote_location(pl), pl.ping, host_remote?(pl), false] }
      list
    end

    # Ping-to-host: the host is the anchor (none); a guest reports its own.
    def self_ping
      host? ? -1 : ($bsmp_my_ping || -1)
    end

    def ping_text(ms)
      (ms && ms > 0) ? "#{ms}ms" : "-"
    end

    def remotes
      $bsmp_players ? $bsmp_players.bsmp_players.values : []
    end

    def host?
      $bsmp_server and $bsmp_server.running?
    end

    def self_name
      member = $game_party && $game_party.battle_members[0]
      member ? member.name : BSMP.t("bsmp.name_self")
    end

    def remote_name(pl)
      n = pl.nickname.to_s
      n.empty? ? BSMP.t("bsmp.name_player") : n
    end

    def self_location
      name = BSMP.current_location_name
      name.empty? ? BSMP.t("bsmp.location_unknown") : name
    end

    # The name the peer broadcast; fall back to a local lookup by map id.
    def remote_location(pl)
      loc = pl.location_name.to_s
      loc.empty? ? BSMP.location_name(pl.map_id) : loc
    end

    # On a client, the remote whose id is the lobby owner is the host.
    def host_remote?(pl)
      $bsmp_client && $bsmp_client.connected? && pl.player_id == $bsmp_client.server_user_id
    end

    def signature
      entries
    end

    def update
      sig = signature
      return if sig == @signature
      @signature = sig
      resize
      recenter
      refresh
    end

    def resize
      old_height = self.height
      self.height = window_height
      create_contents if old_height != self.height
    end

    def recenter
      self.x = (Graphics.width - width) / 2
      self.y = (Graphics.height - height) / 2
    end

    GAP    = 16 # space between columns
    PING_W = 96 # reserved far-right column so a long location can't eat the ping

    def refresh
      self.contents.fill_rect(0, 0, contents.width, contents.height, BACK_COLOR)
      list = entries
      w = contents.width - MARGIN_X * 2

      # Three non-overlapping columns: name (left), location (middle, clipped to its
      # own width), ping (fixed, far right). Keeps a long location off the ping.
      name_w = w * 2 / 5
      loc_x  = MARGIN_X + name_w + GAP
      loc_w  = w - name_w - GAP * 2 - PING_W
      ping_x = MARGIN_X + w - PING_W

      self.contents.font.color = HEAD_COLOR
      draw_text(MARGIN_X, 0, w, row_height, BSMP.t("bsmp.roster_title") % list.size)

      y = row_height
      list.each do |name, loc, ping, is_host, is_self|
        label = name.dup
        label << BSMP.t("bsmp.roster_host_tag") if is_host
        label << BSMP.t("bsmp.roster_you_tag") if is_self
        self.contents.font.color = is_host ? HOST_COLOR : TEXT_COLOR
        draw_text(MARGIN_X, y, name_w, row_height, label)
        self.contents.font.color = LOC_COLOR
        draw_text(loc_x, y, loc_w, row_height, loc, 0)
        draw_text(ping_x, y, PING_W, row_height, ping_text(ping), 2)
        y += row_height
      end
    end

  end

  # Centered "syncing world" overlay, shown while the client is pulling/applying
  # the host's world: the WORLD_REQUEST round-trip on a save-load, and the (brief
  # but blocking) World.load apply on a lobby join. Static — no per-frame redraw.
  class Sync_Window < Window
    TEXT_COLOR = Color.new(255, 255, 255, 255)

    def initialize
      super
      recenter
      refresh
    end

    def window_width
      [[Graphics.width / 2, 360].max, Graphics.width - 32].min
    end

    def row_height
      size = Font.respond_to?(:default_size) ? Font.default_size : 24
      [line_height, size + 8].max
    end

    def window_height
      row_height + standard_padding * 2
    end

    def recenter
      self.x = (Graphics.width - width) / 2
      self.y = (Graphics.height - height) / 2
    end

    def refresh
      self.contents.fill_rect(0, 0, contents.width, contents.height, BACK_COLOR)
      self.contents.font.color = TEXT_COLOR
      draw_text(0, 0, contents.width, contents.height, BSMP.t("bsmp.sync_caption"), 1)
    end

    def update
    end
  end

  # Lifecycle for the sync overlay. Kept as module state (not a scene ivar) so it
  # survives the Scene_Load -> Scene_Map handoff during a save-load. Driven from
  # Scene_Base#update so it shows on any scene.
  module UI
    def self.update_sync_overlay
      if $bsmp_client and $bsmp_client.connected? and $bsmp_client.syncing?
        @sync_window ||= Sync_Window.new
        @sync_window.update
      elsif @sync_window
        @sync_window.dispose
        @sync_window = nil
      end
    end
  end

end # module BSMP

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-UI"]
