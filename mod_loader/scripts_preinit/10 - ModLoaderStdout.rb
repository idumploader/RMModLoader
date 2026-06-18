#==============================================================================
# ModLoaderStdout — redirects Ruby $stdout into the ModLoader log.
#
# Preinit script: installs a CustomOutputRedirector so every puts/print/p (and
# anything writing to $stdout) is forwarded to ModLoader.log. Runs before the
# game's own scripts, so their output is captured too.
#
# Version gate: ModLoader.version != "2.4"
#==============================================================================

if ModLoader.version != "2.4"

class CustomOutputRedirector
      def initialize(target_method)
        @target_method = target_method
      end

      def write(string)
        @target_method.call(string)
      end

      def flush; end
      def sync; true; end
      def sync=(value); end
      def tty?; false; end
end

def mod_loader_output_log(message)
  ModLoader.log(message)
end

redirector = CustomOutputRedirector.new(method(:mod_loader_output_log))
$stdout = redirector

end # ModLoader.version != "2.4"