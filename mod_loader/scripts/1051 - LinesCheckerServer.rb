#==============================================================================
# LinesCheckerServer — CONSUMER of HttpRouter (1040). Registers the text
# length/width checking endpoints, measured with the real RGSS3 renderer.
# Listen, polling and dispatch live entirely in the ModLoader::Http master.
#
# Dependencies:
#   • 1040 - HttpRouter      (ModLoader::Http — router/poller/JSON)
#   • 1050 - LinesChecker    (LinesChecker.text_width — width measurement)
#
# Contexts and limits (see Contexts below):
#   dialog          → 614px, no line limit
#   dialog_portrait → 502px (614 - 112 portrait), no line limit
#   description     → 616px, up to 4 lines
#   choice          → 616px, exactly 1 line
#   scroll          → 51 chars (char-based, unstable window geometry)
#
# Endpoints:
#   GET  /ping
#     resp: "pong"
#
#   POST /measure
#     body: {"text": "line with \\n", "context": "<context name>"}
#     resp: {
#       "ok": true, "context": "...", "max_width": 614, "max_lines": null,
#       "max_chars": null,
#       "lines": [{"text":"...", "width":123, "fits":true}, ...],
#       "lines_count": 2, "fits": true, "overflow_count": 0
#     }
#
#   POST /measure_batch
#     body: NDJSON — one {"text":"...","context":"..."} object per line,
#           separator is a real \n; inside the JSON string there must be no
#           real \n (only the escape \\n).
#     resp: {"ok": true, "count": N, "results": [<measure response>, ...]}
#     Processing is synchronous; for hundreds of entries it blocks the frame.
#==============================================================================

$imported ||= {}
if not $imported["IDL-LinesCheckerServer"] and defined?(ModLoader::Http) and
   defined?(LinesChecker) and LinesChecker.respond_to?(:text_width)
$imported["IDL-LinesCheckerServer"] = "0.3"

module LinesChecker
  # ---- Contexts ----
  module Contexts
    ALL = {
      "dialog"          => { :max_width => 614,       :max_lines => nil, :max_chars => nil },
      "dialog_portrait" => { :max_width => 614 - 112, :max_lines => nil, :max_chars => nil },
      "description"     => { :max_width => 616,       :max_lines => 4,   :max_chars => nil },
      # Window_ChoiceList: width capped at Graphics.width = 640, contents_width = 616.
      # max_lines: 1 — window is single-line per item, \n breaks the render.
      "choice"          => { :max_width => 616,       :max_lines => 1,   :max_chars => nil },
      "scroll"          => { :max_width => nil,       :max_lines => nil, :max_chars => 51  },
    }

    DEFAULT = "dialog".freeze

    def self.lookup(name)
      ALL[name] || ALL[DEFAULT]
    end
  end

  # ---- Measurement (all domain logic; transport in ModLoader::Http) ----
  module Measurer
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

    # NDJSON envelope (our JSON can't parse nested arrays): the body is a batch
    # of {"text":"...","context":"..."} objects separated by a real "\n".
    # Inside a JSON string there is no real \n — only the escape \\n.
    def self.measure_batch(body)
      results = []
      body.to_s.split("\n").each do |line|
        next if line.empty?
        req = ModLoader::Http::Json.parse(line)
        results << measure_one(req["text"], req["context"])
      end
      { "ok" => true, "count" => results.size, "results" => results }
    end
  end
end

# ---- Endpoint registration in the master ----
http = ModLoader::Http

http.get("/ping") { "pong" }

http.post("/measure") do |req, _params|
  data = ModLoader::Http::Json.parse(req["body"])
  http.json(LinesChecker::Measurer.measure_one(data["text"], data["context"]))
end

http.post("/measure_batch") do |req, _params|
  http.json(LinesChecker::Measurer.measure_batch(req["body"]))
end

puts "[LinesCheckerServer] registered GET /ping, POST /measure, POST /measure_batch"

end # not $imported["IDL-LinesCheckerServer"]
