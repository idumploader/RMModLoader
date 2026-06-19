#==============================================================================
# BSMP World Events — guest-side suppression of host-owned world cutscenes.
#
# A guest does NOT run an autorun (trigger 3) or parallel (trigger 4) event page
# whose activating condition references a SHARED flag (a shared switch/variable,
# or any self-switch — all self-switches are shared). Those "world cutscenes" run
# only on the host; their outcome flags arrive as live facts (see the setter hooks
# in 1240) and refresh the guest's events into the post-cutscene state. See spec
# sections 5.3 / 6.
#
# Untouched: the host, single-player, and a guest's unconditional or local-switch
# autorun/parallel (genuinely local logic). Loads after the game's own Game_Event
# (and mods that reopen it), so the aliases wrap the final versions.
#==============================================================================

$imported ||= {}
if not $imported["IDL-BSMP-WorldEvents"]
$imported["IDL-BSMP-WorldEvents"] = "1.0"

if defined?(BSMP)

class Game_Event < Game_Character

  # Host-owned world progression if ANY of the event's pages is gated on a synced
  # flag — not just the active one. The common run-once cutscene has an
  # unconditional autorun page 1 (which sets self-switch A) and a page 2 gated on
  # self-switch A; we must catch it via page 2, or the guest would re-play page 1.
  # The page set is immutable, so memoize per event (recomputed on map reload).
  def bsmp_world_owned_event?
    return @bsmp_world_owned unless @bsmp_world_owned.nil?
    @bsmp_world_owned = !@event.nil? && @event.pages.any? { |pg| BSMP.world_owned_condition?(pg.condition) }
  end

  # A guest skips running host-owned autorun/parallel pages. guest? is checked
  # first so the host and single-player pay almost nothing here.
  def bsmp_suppress_world_event?
    return false if not BSMP.guest?
    return false if @trigger != 3 and @trigger != 4
    bsmp_world_owned_event?
  end

  # Autorun (trigger 3): don't let it start, so the map interpreter never picks it
  # up (@starting stays false).
  alias bsmp_orig_check_event_trigger_auto check_event_trigger_auto
  def check_event_trigger_auto
    return if bsmp_suppress_world_event?
    bsmp_orig_check_event_trigger_auto
  end

  # Parallel (trigger 4): drop the interpreter for a host-owned page so update's
  # `return unless @interpreter` skips running the cutscene. Re-decided on every
  # refresh (setup_page_settings re-runs when the page changes).
  alias bsmp_orig_setup_page_settings setup_page_settings
  def setup_page_settings
    bsmp_orig_setup_page_settings
    @interpreter = nil if bsmp_suppress_world_event?
  end

end

end # if defined?(BSMP)

end # not $imported["IDL-BSMP-WorldEvents"]
