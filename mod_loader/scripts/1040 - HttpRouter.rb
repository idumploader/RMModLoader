#==============================================================================
# HttpRouter — the single HTTP routing master on top of ModLoader.http_* .
#
# Why: the transport (C++ HttpServer) is one shared request queue that is
# drained destructively by ModLoader.http_poll. EXACTLY ONE poller must drain
# it, else several scripts steal each other's requests. So listen, polling,
# dispatch and the shared JSON live here, and feature scripts only add routes.
#
# Usage from another script (loaded AFTER this one, i.e. prefix > 1040):
#
#   if defined?(ModLoader::Http)
#     ModLoader::Http.get("/ping") { "pong" }                 # String -> 200 text
#     ModLoader::Http.post("/thing") do |req, params|
#       data = ModLoader::Http::Json.parse(req["body"])
#       ModLoader::Http.json({ "ok" => true })                # Hash  -> 200 json
#     end
#     ModLoader::Http.get("/item/:id") { |req, p| "id=#{p[:id]}" }
#   end
#
# A handler receives (req, params) and may return:
#   • [status, content_type, body]   — explicit tuple
#   • String                         — 200 text/plain
#   • Hash / Array                   — 200 application/json
#   • nil                            — 204 No Content
# An exception in a handler is isolated -> 500 (poller and other routes live).
#
# The server starts lazily on the first frame (after all scripts load); port
# from mod_loader.json ("http_port") or DEFAULT_PORT.
#==============================================================================

$imported ||= {}
if not $imported["IDL-HttpRouter"] and ModLoader.respond_to?(:http_poll)
$imported["IDL-HttpRouter"] = "1.0"

module ModLoader
  module Http
    DEFAULT_PORT = 27420

    #--------------------------------------------------------------------------
    # Minimal JSON (RGSS3 has no json in stdlib). Flat string->string form
    # for requests + a full encode for responses.
    #--------------------------------------------------------------------------
    module Json
      # Char-by-char parser. A regex with [^"\\]* over a multi-byte UTF-8
      # string behaves inconsistently in Ruby 1.9 (silently skips long
      # Cyrillic values). We extract only "key":"string_value" pairs; other
      # values (number, object, array, null, bool) are skipped — enough for
      # envelopes and flat requests.
      def self.parse(str)
        result = {}
        s = str.to_s
        begin
          s = s.dup.force_encoding("UTF-8")
        rescue
        end
        n = s.length
        i = 0
        while i < n
          nxt = s.index('"', i)
          break if nxt.nil?
          i = nxt + 1
          key_start = i
          i = skip_string_body(s, i, n)
          return result if i >= n
          key = s[key_start...i]
          i += 1 # skip closing "
          i = skip_ws(s, i, n)
          next if i >= n || s[i] != ':'
          i += 1
          i = skip_ws(s, i, n)
          next if i >= n
          if s[i] == '"'
            i += 1
            val_start = i
            i = skip_string_body(s, i, n)
            return result if i >= n
            val = s[val_start...i]
            i += 1 # skip closing "
            result[unescape(key)] = unescape(val)
          else
            i = skip_non_string_value(s, i, n)
          end
        end
        result
      end

      def self.skip_string_body(s, i, n)
        while i < n
          c = s[i]
          if c == "\\"
            i += 2
          elsif c == '"'
            return i
          else
            i += 1
          end
        end
        i
      end

      def self.skip_ws(s, i, n)
        while i < n && (s[i] == " " || s[i] == "\t" || s[i] == "\n" || s[i] == "\r")
          i += 1
        end
        i
      end

      def self.skip_non_string_value(s, i, n)
        c = s[i]
        if c == "{" || c == "["
          depth = 1
          i += 1
          while i < n && depth > 0
            cc = s[i]
            if cc == "{" || cc == "["
              depth += 1
            elsif cc == "}" || cc == "]"
              depth -= 1
            elsif cc == '"'
              i += 1
              i = skip_string_body(s, i, n)
            end
            i += 1
          end
          i
        else
          while i < n && s[i] != "," && s[i] != "}" && s[i] != "]"
            i += 1
          end
          i
        end
      end

      def self.encode(obj)
        case obj
        when Hash    then "{" + obj.map { |k, v| "#{encode(k.to_s)}:#{encode(v)}" }.join(",") + "}"
        when Array   then "[" + obj.map { |v| encode(v) }.join(",") + "]"
        when String  then '"' + escape(obj) + '"'
        when nil     then "null"
        when true, false then obj.to_s
        when Numeric then obj.to_s
        else              encode(obj.to_s)
        end
      end

      # Block-based so gsub doesn't interpret special sequences in the
      # replacement string.
      def self.escape(s)
        s.gsub(/[\\"\n\r\t]/) do |c|
          case c
          when "\\" then '\\\\'
          when '"'  then '\\"'
          when "\n" then '\\n'
          when "\r" then '\\r'
          when "\t" then '\\t'
          end
        end
      end

      # Single left-to-right pass. A gsub chain gave the wrong order:
      # for input "\\n" it catches "\\n" -> newline first, leaving orphan '\'.
      def self.unescape(s)
        s.gsub(/\\(.)/m) do
          case $1
          when '"'  then '"'
          when 'n'  then "\n"
          when 'r'  then "\r"
          when 't'  then "\t"
          when '\\' then '\\'
          else "\\#{$1}"
          end
        end
      end
    end

    #--------------------------------------------------------------------------
    # Router + poller.
    #--------------------------------------------------------------------------
    Route = Struct.new(:verb, :matcher, :keys, :handler)

    @routes  = []
    @started = false   # whether we already tried to start listening
    @up      = false   # the listen actually came up

    class << self
      attr_reader :routes

      # --- registration ---
      def route(method, path, &blk)
        raise ArgumentError, "ModLoader::Http.route requires a block" unless blk
        matcher, keys = compile(path)
        m = method.to_s.upcase
        if routes.any? { |r| r.verb == m && r.matcher.source == matcher.source }
          puts "[HttpRouter] WARNING: route #{m} #{path} re-registered (last wins)"
        end
        routes << Route.new(m, matcher, keys, blk)
        nil
      end

      def get(p, &b);    route("GET",    p, &b); end
      def post(p, &b);   route("POST",   p, &b); end
      def put(p, &b);    route("PUT",    p, &b); end
      def delete(p, &b); route("DELETE", p, &b); end

      # --- response helpers for handlers ---
      def json(obj, status = 200); [status, "application/json", Json.encode(obj)]; end
      def text(str, status = 200); [status, "text/plain", str.to_s]; end

      # --- path parsing ---
      # Regexp        -> [rx, []]
      # "/item/:id"   -> [/\A\/item\/([^\/]+)\z/, [:id]]
      # plain string -> exact match
      #
      # Split on "/" segments: literals are escaped, ":name" becomes a whole
      # capture ([^/]+). This keeps dots/special chars in the path as
      # literals, and params stay independent of Regexp.escape behavior.
      def compile(path)
        return [path, []] if path.is_a?(Regexp)
        keys = []
        parts = path.to_s.split("/", -1).map do |seg|
          if seg =~ /\A:([A-Za-z_]\w*)\z/
            keys << $1.to_sym
            "([^/]+)"
          else
            Regexp.escape(seg)
          end
        end
        [/\A#{parts.join("/")}\z/, keys]
      end

      # --- dispatch (one for all) ---
      def dispatch(req)
        meth = req["method"].to_s
        path = req["path"].to_s
        routes.each do |r|
          next unless r.verb == meth
          m = r.matcher.match(path)
          next unless m
          params = {}
          r.keys.each_with_index { |k, idx| params[k] = m[idx + 1] }
          return coerce(r.handler.call(req, params))
        end
        [404, "text/plain", "no route for #{meth} #{path}"]
      rescue => e
        [500, "text/plain", "#{e.class}: #{e.message}\n#{e.backtrace.first}"]
      end

      # Normalize whatever the handler returned into [status, content_type, body].
      def coerce(result)
        case result
        when Array
          if result.size == 3 && result[0].is_a?(Integer) && result[1].is_a?(String)
            result
          else
            [200, "application/json", Json.encode(result)]
          end
        when Hash
          [200, "application/json", Json.encode(result)]
        when nil
          [204, "text/plain", ""]
        else
          [200, "text/plain", result.to_s]
        end
      end

      # --- the single poller: drains the queue once per frame ---
      def tick
        ensure_listening
        return unless @up
        while (json = ModLoader.http_poll)
          req = Json.parse(json)
          status, ctype, body = dispatch(req)
          ModLoader.http_respond(req["id"].to_s, status.to_i, ctype.to_s, body.to_s)
        end
      end

      def ensure_listening
        return if @started
        @started = true
        port = configured_port
        @up = ModLoader.http_listen(port)
        if @up
          puts "[HttpRouter] listening on http://127.0.0.1:#{port} (#{routes.size} routes)"
        else
          puts "[HttpRouter] failed to listen on port #{port} (already in use?)"
        end
      end

      def configured_port
        v = (ModLoader.config_get("http_port") rescue nil)
        (v.is_a?(Integer) && v > 0) ? v : DEFAULT_PORT
      end
    end
  end
end

# The only queue-drain point — once per frame on the main Ruby thread.
class Scene_Base
  alias :ml_http_router_update_basic :update_basic
  def update_basic
    ml_http_router_update_basic
    ModLoader::Http.tick
  end
end

end # not $imported["IDL-HttpRouter"]
