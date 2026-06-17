#==============================================================================
# LinesCheckerServer — HTTP-API для проверки длины/ширины текста средствами
# реального RGSS3-рендера (см. LinesChecker.text_width в 1050).
#
# Транспорт: ModLoader.http_listen / http_poll / http_respond. Сервер крутится
# в C++ потоке, очередь запросов дренится в главном Ruby-потоке раз в кадр
# через Scene_Base#update_basic.
#
# Контексты и лимиты (см. модуль Contexts ниже):
#   dialog          → 614px, без лимита строк
#   dialog_portrait → 502px (DIALOG_MAX_WIDTH - аватарка), без лимита строк
#   description     → 616px, до 4 строк
#   choice          → 616px, ровно 1 строка
#   scroll          → 51 символ (без графики, нестабильная геометрия окна)
#
# Эндпоинты:
#   GET  /ping
#     resp: "pong"
#
#   POST /measure
#     body: {"text": "строка с \\n", "context": "<имя контекста>"}
#     resp: {
#       "ok": true, "context": "...", "max_width": 614, "max_lines": null,
#       "max_chars": null,
#       "lines": [{"text":"...", "width":123, "fits":true}, ...],
#       "lines_count": 2, "fits": true, "overflow_count": 0
#     }
#
#   POST /measure_batch
#     body: NDJSON — по объекту {"text":"...","context":"..."} на строку,
#           разделитель — реальный \n; внутри JSON-строки реальных \n быть не
#           должно (только escape \\n).
#     resp: {"ok": true, "count": N, "results": [<measure response>, ...]}
#     Обработка синхронная; на N сотен записей блокирует кадр.
#==============================================================================

$imported ||= {}
if not $imported["LinesCheckerServer"] and ModLoader.respond_to?(:http_poll)
$imported["LinesCheckerServer"] = "0.2"

PORT = 27420

module LinesChecker
  # ---- Контексты ----
  module Contexts
    ALL = {
      "dialog"          => { :max_width => 614,       :max_lines => nil, :max_chars => nil },
      "dialog_portrait" => { :max_width => 614 - 112, :max_lines => nil, :max_chars => nil },
      "description"     => { :max_width => 616,       :max_lines => 4,   :max_chars => nil },
      # Window_ChoiceList: width капается Graphics.width = 640, contents_width = 616.
      # max_lines: 1 — окно односторочное на пункт, \n ломает рендер.
      "choice"          => { :max_width => 616,       :max_lines => 1,   :max_chars => nil },
      "scroll"          => { :max_width => nil,       :max_lines => nil, :max_chars => 51  },
    }

    DEFAULT = "dialog".freeze

    def self.lookup(name)
      ALL[name] || ALL[DEFAULT]
    end
  end

  # ---- Минимальный JSON ----
  # RGSS3 не имеет json в stdlib; для нашей плоской формы запроса/ответа хватит.
  module JsonMini
    # Char-by-char парсер. Регулярка с [^"\\]* + multi-byte UTF-8 строкой в Ruby 1.9
    # ведёт себя неконсистентно (молча не матчит длинные Cyrillic значения).
    # Извлекаем только пары "key":"string_value", остальные значения (число, объект,
    # массив, null, bool) пропускаем — нам этого хватит для запросов/ответов.
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
        # Найти следующий '"' (начало ключа), пропуская мусор.
        nxt = s.index('"', i)
        break if nxt.nil?
        i = nxt + 1
        key_start = i
        i = skip_string_body(s, i, n)
        return result if i >= n
        key = s[key_start...i]
        i += 1 # skip closing "
        i = skip_ws(s, i, n)
        # Ожидаем ':'
        next if i >= n || s[i] != ':'
        i += 1
        i = skip_ws(s, i, n)
        next if i >= n
        if s[i] == '"'
          # Строковое значение — забираем.
          i += 1
          val_start = i
          i = skip_string_body(s, i, n)
          return result if i >= n
          val = s[val_start...i]
          i += 1 # skip closing "
          result[unescape(key)] = unescape(val)
        else
          # Не строка — пропускаем целиком (число / объект / массив / null / bool).
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
        # число / null / true / false — пропускаем до запятой/закрывающей скобки
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

    # Block-based чтобы gsub не интерпретировал спец-последовательности в строке-замене.
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

    # Один проход слева-направо. Альтернативная цепочка gsub'ов даёт неправильный
    # порядок: для входа "\\n" (3 символа: backslash backslash n — escape для
    # литерального бэкслеш+n) сначала ловит "\\n" → newline, оставляя orphan '\'.
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

  # ---- Подменяемый кодировщик Bitmap → байты (точка расширения под будущий /render) ----
  module BitmapEncoder
    module BmpViaTempFile
      MIME = "image/bmp".freeze
      def self.mime; MIME; end
      def self.encode(bitmap)
        name = "lc_preview_#{Thread.current.object_id}_#{rand(2**32)}"
        file = "#{name}.bmp"
        ModLoader.dump_as_bmp(bitmap, name)
        bytes = File.binread(file)
        File.delete(file) rescue nil
        bytes
      end
    end

    @active = BmpViaTempFile
    def self.active;     @active;     end
    def self.active=(e); @active = e; end
  end

  # ---- Роутер ----
  module Router
    def self.dispatch(req)
      method = req["method"]
      path   = req["path"]

      case [method, path]
      when ["GET",  "/ping"]          then ping
      when ["POST", "/measure"]       then measure(req["body"])
      when ["POST", "/measure_batch"] then measure_batch(req["body"])
      else                                  not_found(method, path)
      end
    rescue => e
      error_500(e)
    end

    def self.ping
      [200, "text/plain", "pong"]
    end

    def self.not_found(method, path)
      [404, "text/plain", "no route for #{method} #{path}"]
    end

    def self.error_500(e)
      [500, "text/plain", "#{e.class}: #{e.message}\n#{e.backtrace.first}"]
    end

    def self.measure(body)
      req = JsonMini.parse(body)
      [200, "application/json", JsonMini.encode(measure_one(req["text"], req["context"]))]
    end

    # NDJSON-конверт (JsonMini не парсит вложенные массивы): тело — пачка
    # объектов вида {"text":"...","context":"..."}, разделённых "\n". Внутри
    # JSON-строки реальных \n нет — там escape-последовательности \\n.
    def self.measure_batch(body)
      results = []
      body.to_s.split("\n").each do |line|
        next if line.empty?
        req = JsonMini.parse(line)
        results << measure_one(req["text"], req["context"])
      end
      json = JsonMini.encode({ "ok" => true, "count" => results.size, "results" => results })
      [200, "application/json", json]
    end

    def self.measure_one(text, ctx_name)
      text     = (text     || "").to_s
      ctx_name = (ctx_name || Contexts::DEFAULT).to_s
      ctx      = Contexts.lookup(ctx_name)

      lines = text.split("\n", -1)
      lines_results = lines.map { |line| measure_line(line, ctx) }

      overflow  = lines_results.count { |l| !l["fits"] }
      lines_fit = ctx[:max_lines].nil? || lines.size <= ctx[:max_lines]
      overall   = lines_fit && overflow == 0

      {
        "ok"             => true,
        "context"        => ctx_name,
        "max_width"      => ctx[:max_width],
        "max_lines"      => ctx[:max_lines],
        "max_chars"      => ctx[:max_chars],
        "lines"          => lines_results,
        "lines_count"    => lines.size,
        "fits"           => overall,
        "overflow_count" => overflow,
      }
    end

    def self.measure_line(line, ctx)
      if ctx[:max_width]
        width = LinesChecker.text_width(line)
        { "text" => line, "width" => width, "fits" => width <= ctx[:max_width] }
      else
        { "text" => line, "length" => line.length, "fits" => line.length <= ctx[:max_chars] }
      end
    end
  end

  # ---- Поллер: дренит очередь раз в кадр в главном потоке ----
  module Poller
    def self.tick
      while (req_json = ModLoader.http_poll)
        req = parse_envelope(req_json)
        status, content_type, body = Router.dispatch(req)
        ModLoader.http_respond(req["id"], status, content_type, body.to_s)
      end
    end

    # Распарсивает JSON-конверт, который ModLoader присылает в http_poll.
    # Шейп: {"id":"...","method":"GET","path":"/x","query":"","headers":{...},"body":"..."}
    def self.parse_envelope(json_str)
      # JsonMini.parse работает только с плоскими string→string; нам этого хватит
      # для id/method/path/body. headers нам сейчас не нужны.
      JsonMini.parse(json_str)
    end
  end
end

# Дренаж очереди каждый кадр.
class Scene_Base
  alias :lines_checker_server_orig_update_basic :update_basic
  def update_basic
    lines_checker_server_orig_update_basic
    LinesChecker::Poller.tick
  end
end

# Автостарт сервера.
if ModLoader.http_listen(PORT)
  puts "[LinesCheckerServer] listening on http://127.0.0.1:#{PORT}"
else
  puts "[LinesCheckerServer] failed to start on port #{PORT} (already in use?)"
end

end # not $imported["LinesCheckerServer"]
