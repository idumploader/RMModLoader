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