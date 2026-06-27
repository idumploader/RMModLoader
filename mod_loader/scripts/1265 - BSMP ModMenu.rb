#==============================================================================
# BSMP ModMenu — plug BSMP's preferences into the shared in-game menu (ModMenu,
# script 10; open with F10). Entries drive BSMP.settings live and persist to its
# own NVRAM :bsmp section, so they do NOT use ModMenu's :key (that would write to
# the :modmenu section instead). Each :set applies to the working copy (read live
# by the running session) and commits :bsmp so the choice survives a restart.
#
# Loads after ModMenu (10) and BSMP Core (1200); both guarded so a build without
# either just skips registration.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-ModMenu"]
$imported["IDL-BSMP-ModMenu"] = "1.0"

if defined?(BSMP) and defined?(ModLoader::ModMenu)

module BSMP
  module MenuBinding
    M   = ModLoader::ModMenu
    CAT = "Co-op"

    # A bound value entry: read from / write to BSMP.settings[field], committing
    # the :bsmp section on every edit so it persists like a console tweak would.
    def self.getter(field)
      proc { BSMP.settings.send(field) }
    end

    def self.setter(field)
      proc do |value|
        BSMP.settings.send("#{field}=", value)
        BSMP.settings.commit
      end
    end

    def self.bind(field)
      { :get => getter(field), :set => setter(field) }
    end

    # Start hosting with the current lobby settings (dropping any client link
    # first, like the make_server console command). create_lobby is async — the
    # status plate flips to HOST once Steam confirms the lobby.
    def self.host!
      return unless $bsmp_server
      $bsmp_client.leave_lobby if $bsmp_client and $bsmp_client.connected?
      $bsmp_server.create_lobby(BSMP.settings.lobby_type, BSMP.settings.max_players)
    end

    # Leave the session: a host stops its server (the only way out for the host),
    # a guest leaves the lobby. Both clear their roster/sprites.
    def self.leave!
      $bsmp_server.leave_lobby if $bsmp_server and $bsmp_server.running?
      $bsmp_client.leave_lobby if $bsmp_client and $bsmp_client.connected?
    end

    def self.install
      #--- Session ------------------------------------------------------------
      M.header("Session", :category => CAT)
      M.action("Host lobby", :category => CAT, :close_after => true) { host! }
      M.action("Leave session", :category => CAT, :close_after => true) { leave! }
      # Players overlay (1267): teleport to a peer; the host can also kick. Kept up here in
      # Session for quick access. Closes this menu first; the overlay opens next frame.
      M.action("Players", :category => CAT, :close_after => true) do
        if bsmp_network_running?
          BSMP::PlayersMenu.request_open
        else
          msgbox("BSMP: not connected.")
        end
      end

      #--- Lobby --------------------------------------------------------------
      M.header("Lobby", :category => CAT)
      M.choice("Visibility", bind(:lobby_type).merge(
               :category => CAT,
               :values => [BSMP::Config::LOBBY_PRIVATE,
                           BSMP::Config::LOBBY_FRIENDS_ONLY,
                           BSMP::Config::LOBBY_PUBLIC,
                           BSMP::Config::LOBBY_INVISIBLE],
               :labels => ["Private", "Friends", "Public", "Invisible"]))
      M.toggle("Verify same game", bind(:check_game).merge(
               :category => CAT, :on_text => "ON", :off_text => "OFF"))
      M.toggle("Strict content check", bind(:check_data_hash).merge(
               :category => CAT, :on_text => "ON", :off_text => "OFF"))
      M.slider("Max players", bind(:max_players).merge(
               :category => CAT, :min => 2, :max => 16, :step => 1,
               :gauge => [18, 10]))

      #--- Battle -------------------------------------------------------------
      M.header("Battle", :category => CAT)
      # Stored in frames (~60/s); show and step in seconds.
      M.slider("Turn timeout", bind(:battle_input_timeout_frames).merge(
               :category => CAT, :min => 300, :max => 10800, :step => 300,
               :gauge => [14, 6],
               :format => proc { |f| "#{f / 60}s" }))
      M.slider("Battle watchdog", bind(:battle_watchdog_frames).merge(
               :category => CAT, :min => 0, :max => 3600, :step => 60,
               :gauge => [14, 6],
               :format => proc { |f| f <= 0 ? "off" : "#{f / 60}s" }))
      # Per-peer kill switch for the double-battle dedup (a slow reader re-fighting a
      # cutscene battle the group already won). Local only — turning it off just makes
      # THIS peer re-fight; no desync.
      M.toggle("Double-battle dedup", bind(:battle_dedup).merge(
               :category => CAT, :on_text => "ON", :off_text => "OFF"))

      #--- Roster -------------------------------------------------------------
      M.header("Roster", :category => CAT)
      M.choice("Key mode", bind(:roster_mode).merge(
               :category => CAT,
               :values => [:hold, :toggle],
               :labels => ["Hold", "Toggle"]))

      #--- Diagnostics --------------------------------------------------------
      M.header("Diagnostics", :category => CAT)
      M.toggle("Debug log", bind(:debug).merge(:category => CAT))
      M.toggle("Packet trace", bind(:debug_packets).merge(:category => CAT))
      M.toggle("Log to file", bind(:log_to_file).merge(:category => CAT))
      M.action("Mark log (bug here)", :category => CAT) { BSMP.mark_log("from menu") }
      # World sync mode (host-authoritative). WHITELIST (default) = share only the SHARED_*
      # allowlist, peer-local state stays private (a missed flag only desyncs). BLACKLIST =
      # share everything except Config::PERSONAL_*, for when the allowlist has gaps and
      # progress desyncs -- non-destructive (personal state is still protected). Stored as a
      # Symbol; this toggle maps it (ON = :blacklist, OFF = :whitelist).
      M.toggle("World sync: blacklist", :category => CAT, :on_text => "BLACKLIST", :off_text => "WHITELIST",
               :get => proc { BSMP.settings.world_sync_mode == :blacklist },
               :set => proc { |v| BSMP.settings.world_sync_mode = (v ? :blacklist : :whitelist) })

      # Language lives in the loader's own "General" tab (12 - ModMenuDefaults),
      # not here — it's a global ModLoader setting, not a co-op one.

      #--- Status -------------------------------------------------------------
      M.header("Status", :category => CAT)
      M.toggle("Status plate", bind(:show_status_plate).merge(
               :category => CAT, :on_text => "ON", :off_text => "OFF"))
      M.slider("Plate X", bind(:status_plate_x).merge(
               :category => CAT, :min => 0, :max => 100, :step => 5,
               :gauge => [14, 6], :format => proc { |v| "#{v}%" }))
      M.slider("Plate Y", bind(:status_plate_y).merge(
               :category => CAT, :min => 0, :max => 100, :step => 5,
               :gauge => [14, 6], :format => proc { |v| "#{v}%" }))
      M.action("Show co-op status", :category => CAT) do
        if BSMP.respond_to?(:host?) and ($bsmp_server or $bsmp_client)
          role = BSMP.host? ? "Host" : "Client"
          msgbox("BSMP #{role}\nPlayers online: #{BSMP.battle_player_count}")
        else
          msgbox("BSMP: not connected.")
        end
      end
    end
  end

  MenuBinding.install
end

end # if defined?(BSMP) and defined?(ModLoader::ModMenu)

end # not $imported["IDL-BSMP-ModMenu"]
