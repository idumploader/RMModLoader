#==============================================================================
# HttpRouter — единый мастер HTTP-роутинга поверх ModLoader.http_* .
#
# Зачем: транспорт (C++ HttpServer) — это одна общая очередь запросов, которую
# извлекающе дренит ModLoader.http_poll. Дренить её должен РОВНО ОДИН поллер,
# иначе несколько скриптов воруют запросы друг у друга. Поэтому листен, поллинг,
# диспетч и общий JSON живут здесь, а фичи-скрипты только регистрируют роуты.
#
# Использование из другого скрипта (грузится ПОСЛЕ этого, т.е. префикс > 1040):
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
# Хендлер получает (req, params) и может вернуть:
#   • [status, content_type, body]   — явный кортеж
#   • String                         — 200 text/plain
#   • Hash / Array                   — 200 application/json
#   • nil                            — 204 No Content
# Исключение в хендлере изолируется -> 500 (поллер и прочие роуты живы).
#
# Сервер стартует лениво на первом кадре (после загрузки всех скриптов), порт —
# из конфига mod_loader.json ("http_port") либо DEFAULT_PORT.
#==============================================================================

$imported ||= {}
if not $imported["HttpRouter"] and ModLoader.respond_to?(:http_poll)
$imported["HttpRouter"] = "1.0"

module ModLoader
  module Http
    DEFAULT_PORT = 27420

    #--------------------------------------------------------------------------
    # Минимальный JSON (RGSS3 не имеет json в stdlib). Плоская форма
    # string->string для запросов + полноценный encode для ответов.
    #--------------------------------------------------------------------------
    module Json
      # Char-by-char парсер. Регулярка с [^"\\]* + multi-byte UTF-8 строкой в
      # Ruby 1.9 ведёт себя неконсистентно (молча не матчит длинные Cyrillic
      # значения). Извлекаем только пары "key":"string_value"; остальные значения
      # (число, объект, массив, null, bool) пропускаем — для конвертов и плоских
      # запросов этого хватает.
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

      # Block-based чтобы gsub не интерпретировал спец-последовательности в
      # строке-замене.
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

      # Один проход слева-направо. Цепочка gsub'ов давала неправильный порядок:
      # для входа "\\n" сначала ловит "\\n" -> newline, оставляя orphan '\'.
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
    # Роутер + поллер.
    #--------------------------------------------------------------------------
    Route = Struct.new(:verb, :matcher, :keys, :handler)

    @routes  = []
    @started = false   # пытались ли уже стартовать листен
    @up      = false   # листен реально поднялся

    class << self
      attr_reader :routes

      # --- регистрация ---
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

      # --- ответные хелперы для хендлеров ---
      def json(obj, status = 200); [status, "application/json", Json.encode(obj)]; end
      def text(str, status = 200); [status, "text/plain", str.to_s]; end

      # --- разбор пути ---
      # Regexp        -> [rx, []]
      # "/item/:id"   -> [/\A\/item\/([^\/]+)\z/, [:id]]
      # обычная строка-> точное совпадение
      #
      # Разбиваем по сегментам "/": literal-сегменты экранируем, ":name" целиком
      # становится захватом ([^/]+). Так точки/спецсимволы в пути остаются
      # литералами, а параметры не зависят от поведения Regexp.escape.
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

      # --- диспетч (один на всех) ---
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

      # Нормализация того, что вернул хендлер, в [status, content_type, body].
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

      # --- единственный поллер: дренит очередь раз в кадр ---
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

# Единственная точка дренажа очереди — раз в кадр в главном Ruby-потоке.
class Scene_Base
  alias :ml_http_router_update_basic :update_basic
  def update_basic
    ml_http_router_update_basic
    ModLoader::Http.tick
  end
end

end # not $imported["HttpRouter"]
