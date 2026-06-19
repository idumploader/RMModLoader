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
      header = "BSMP  #{host? ? 'HOST' : 'CLIENT'}  -  #{online_count} online"
      # Full contents height as the rect → vertically centered, symmetric.
      draw_text(MARGIN_X, 0, contents.width - MARGIN_X * 2, contents.height, header)
    end

  end

  # Full player roster overlay, centered, shown while Config::ROSTER_KEY is held
  # (scoreboard-style). Lists everyone — you first, then the remote players — with
  # the host marked. Created/disposed on demand by the Spriteset_Map hook and
  # resized to the current player count.
  class Roster_Window < Window

    HEAD_COLOR = Color.new(255, 230, 150, 255)
    HOST_COLOR = Color.new(120, 220, 140, 255)
    TEXT_COLOR = Color.new(255, 255, 255, 255)

    def initialize
      @signature = nil
      super
      recenter
      refresh
    end

    def window_width
      return 340
    end

    def row_height
      size = Font.respond_to?(:default_size) ? Font.default_size : 24
      [line_height, size + 8].max
    end

    def window_height
      row_height * (1 + entries.size) + standard_padding * 2
    end

    # [name, is_host, is_self] for everyone, with the local player first.
    def entries
      list = [[self_name, host?, true]]
      remotes.each { |pl| list << [remote_name(pl), host_remote?(pl), false] }
      list
    end

    def remotes
      $bsmp_players ? $bsmp_players.bsmp_players.values : []
    end

    def host?
      $bsmp_server and $bsmp_server.running?
    end

    def self_name
      member = $game_party && $game_party.battle_members[0]
      member ? member.name : "You"
    end

    def remote_name(pl)
      n = pl.nickname.to_s
      n.empty? ? "Player" : n
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

    def refresh
      self.contents.fill_rect(0, 0, contents.width, contents.height, BACK_COLOR)
      list = entries

      self.contents.font.color = HEAD_COLOR
      draw_text(MARGIN_X, 0, contents.width - MARGIN_X * 2, row_height, "Players (#{list.size})")

      y = row_height
      list.each do |name, is_host, is_self|
        self.contents.font.color = is_host ? HOST_COLOR : TEXT_COLOR
        label = name.dup
        label << "  [HOST]" if is_host
        label << "  (you)" if is_self
        draw_text(MARGIN_X, y, contents.width - MARGIN_X * 2, row_height, label)
        y += row_height
      end
    end

  end

end # module BSMP

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-UI"]
