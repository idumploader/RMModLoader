#==============================================================================
# CrashLog — log uncaught runtime exceptions to a file with a full backtrace.
#
# RPG Maker runs the game inside `rgss_main { SceneManager.run }` (the Main script).
# rgss_main handles RGSSReset (F12) by re-running the block; ANY OTHER exception
# escapes rgss_main, pops the native "Script error" dialog, and kills the process —
# with nothing written to disk. This wraps SceneManager.run (the body of that block),
# so an exception caught here is exactly one that would escape rgss_main. We append it
# to mod_loader/crash-log.txt (timestamp, class, message, scene, full backtrace) and
# then RE-RAISE, so the normal error dialog still appears — we only add the log.
#
# Standalone deploy utility: no BSMP / ModMenu dependency, just the RGSS3 engine.
#==============================================================================

$imported ||= {}
if not $imported["IDL-CrashLog"]
$imported["IDL-CrashLog"] = "1.0"

module CrashLog
  PATH = "mod_loader/crash-log.txt"

  # Append one crash record. Never raises — logging must not break the crash path.
  def self.write(e)
    File.open(PATH, "a") do |f|
      f.puts "=" * 70
      stamp = (Time.now.strftime("%Y-%m-%d %H:%M:%S") rescue "?")
      f.puts "[#{stamp}] #{e.class}: #{e.message}"
      f.puts "  scene: #{SceneManager.scene.class}" rescue nil
      (e.backtrace || []).each { |line| f.puts "  #{line}" }
      f.puts
    end
  rescue
    nil
  end
end

# Wrap the main loop. Guarded so an F12 reset (which re-runs the script list) can't
# double-alias. SceneManager exists by now — it's an engine script, loaded before any
# mod script — but guard anyway.
if defined?(SceneManager)
  module SceneManager
    class << self
      alias crashlog_orig_run run
      def run
        crashlog_orig_run
      rescue Exception => e
        # F12 reset is normal control flow — let rgss_main catch it and re-run.
        raise if defined?(RGSSReset) and e.is_a?(RGSSReset)
        CrashLog.write(e)
        raise   # keep the native error dialog; we only added the log
      end
    end
  end
end

end # not $imported["IDL-CrashLog"]
