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

    def self.install
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

      #--- Diagnostics --------------------------------------------------------
      M.header("Diagnostics", :category => CAT)
      M.toggle("Debug log", bind(:debug).merge(:category => CAT))
      M.toggle("Packet trace", bind(:debug_packets).merge(:category => CAT))

      # Language lives in the loader's own "General" tab (12 - ModMenuDefaults),
      # not here — it's a global ModLoader setting, not a co-op one.

      #--- Status -------------------------------------------------------------
      M.header("Status", :category => CAT)
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
