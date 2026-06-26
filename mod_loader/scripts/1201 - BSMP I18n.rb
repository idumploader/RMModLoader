#==============================================================================
# BSMP I18n — route BSMP's on-screen strings through ModLoader::I18n (script 11)
# so they can be translated, while the in-code English here stays the default.
#
# STRINGS is the single source of truth: key => English default. Every key is
# registered with I18n.define AT LOAD TIME (in the global scope, not lazily on
# first draw) so I18n.dump_template(:ru) sees the whole set and writes a complete
# translations/<lang>.rb for a translator to fill in. Draw sites then look a key
# up with BSMP.t("bsmp.x"); a missing translation falls back to the English here,
# and a build without the I18n store falls back to STRINGS directly.
#
# Format keys hold printf patterns (%s/%d) — the call site supplies the values:
#   BSMP.t("bsmp.status_header") % [role, online_count]
#
# To refresh the Russian/Japanese files with any newly-added keys, open the mod
# menu (F10) -> Test -> "Dump translation templates" (merges, never clobbers).
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-I18n"]
$imported["IDL-BSMP-I18n"] = "1.0"

if defined?(BSMP)

module BSMP
  # key => source-language (English) default. Keep keys namespaced "bsmp.*".
  STRINGS = {
    # --- status plate (top-right) ---
    "bsmp.role_host"          => "HOST",
    "bsmp.role_client"        => "CLIENT",
    "bsmp.status_header"      => "BSMP  %s  -  %d online",  # role, online count
    # --- roster overlay (hold the roster key) ---
    "bsmp.roster_title"       => "Players (%d)",            # player count
    "bsmp.roster_host_tag"    => "  [HOST]",
    "bsmp.roster_you_tag"     => "  (you)",
    "bsmp.name_self"          => "You",                     # own row, no party name
    "bsmp.name_player"        => "Player",                  # remote with no nickname
    "bsmp.location_unknown"   => "?",
    # --- sync / progress overlays ---
    "bsmp.sync_caption"       => "Syncing game, please wait...",
    "bsmp.save_transfer"      => "Transferring save...",
    # --- co-op gates / turns ---
    "bsmp.ready_gate_wait"    => "Waiting for party  %d/%d", # here / needed
    "bsmp.battle_wait_others" => "Waiting for other players...",
    "bsmp.your_turn"          => "Your turn",
    # --- players menu overlay (1267) ---
    "bsmp.menu_teleport"      => "Teleport to",
    "bsmp.menu_kick"          => "Kick",
    "bsmp.menu_cancel"        => "Cancel",
    "bsmp.menu_close"         => "Close",
    "bsmp.menu_you"           => "(you)",
  }

  # Register every default up front so dump_template can enumerate the keys.
  if defined?(ModLoader::I18n)
    STRINGS.each { |key, default| ModLoader::I18n.define(key, default) }
  end

  # Look up a display string in the current language. Falls back to the English
  # default (via I18n, or directly from STRINGS on a build without the store).
  def self.t(key)
    if defined?(ModLoader::I18n)
      ModLoader::I18n[key]
    else
      STRINGS[key] || key
    end
  end
end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-I18n"]
