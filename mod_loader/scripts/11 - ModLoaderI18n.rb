#==============================================================================
# ModLoaderI18n - a tiny, fast translation-key store for mods.
#
# A mod declares its UI strings with a key and a source-language default, then
# looks them up at draw time:
#
#   T = ModLoader::I18n
#   T.define("mymod.return", "Return to")          # once, at load
#   draw_text(rect, T["mymod.return"], 0)          # at use site
#   # or both in one call:
#   draw_text(rect, T.t("mymod.greet", "Hi, %s") % name, 0)
#
# Because lookup happens at the use site, switching language takes effect on the
# next refresh on its own - no constant rewriting, no module scanning.
#
# --- Translation files (hand-editable) ---
# One Ruby-hash file per language under <data_directory>/translations/<lang>.rb:
#
#   # translations/ru.rb
#   {
#     "mymod.return" => "Вернуться",
#     "mymod.greet"  => "Привет, %s",
#   }
#
# The source language (DEFAULT_LANG) needs no file - its strings are the in-code
# defaults. A missing key falls back to the default, then to the key itself.
# Generate/refresh a file with every registered key via T.dump_template(:ru).
#
# Performance: each language file is parsed once (native Ruby parser) and cached;
# every lookup is two O(1) hash hits. Nothing runs per frame, no draw hooks.
#
# Format choice: a .rb hash (not rvdata2/JSON/YAML) - editable in any text
# editor, parsed by Ruby itself (no stdlib require, which is unreliable on the
# game's cut-down 1.9.2), and round-trips comments and multi-line values.
#
# Language is persisted in ModLoader.nvram[:language].
# Dependencies: ModLoader.data_directory, ModLoaderNVRAM (9).
#==============================================================================

$imported ||= {}
if not $imported["IDL-ModLoaderI18n"]
$imported["IDL-ModLoaderI18n"] = "1.0"

module ModLoader
module I18n
  DIR          = File.join(ModLoader.data_directory, "translations")
  DEFAULT_LANG = :en   # source language: its text lives as in-code defaults

  class << self
    # Current language (Symbol). Restored from NVRAM, else DEFAULT_LANG.
    def language
      @language ||= (persisted_language || DEFAULT_LANG)
    end

    # Switch language. Warms the cache and persists the choice. The new strings
    # show up wherever code looks them up on its next refresh.
    def language=(lang)
      lang = lang.to_sym
      return lang if lang == @language
      @language = lang
      ModLoader.nvram[:language] = lang   # one write-through
      table(lang)                          # parse + cache now, not mid-draw
      lang
    end

    # Register a source-language default for +key+ (first registration wins).
    def define(key, default)
      defaults[key] = default unless defaults.key?(key)
      default
    end

    # Look up +key+ in the current language; fall back to default, then key.
    def [](key)
      tbl = table(language)
      tbl[key] || defaults[key] || key
    end

    # Lookup with an inline default - registers it on first call.
    def t(key, default = nil)
      define(key, default) if default
      self[key]
    end

    # Languages that have a file on disk (Symbols). DEFAULT_LANG may be absent.
    def available
      return [] unless Dir.exist?(DIR)
      Dir.glob(File.join(DIR, "*.rb")).map { |p| File.basename(p, ".rb").to_sym }
    end

    # Drop cached tables so the next lookup re-reads from disk.
    def reload
      @tables = {}
      self
    end

    # Write (merging) a template holding every registered key for +lang+, so a
    # translator gets all keys with the source text to overwrite. Existing
    # translations are preserved, and still-untranslated keys (value equal to the
    # source default, or absent) are grouped under a TODO section up top so what's
    # left to do is obvious at a glance. Returns the path.
    def dump_template(lang)
      ensure_dir
      lang     = lang.to_sym
      existing = load_table(lang)
      todo, done = defaults.keys.sort.partition do |k|
        !existing.key?(k) || existing[k] == defaults[k]
      end
      File.open(file_for(lang), "w:UTF-8") do |f|
        f.puts "# translations/#{lang}.rb - edit the values, keep the keys"
        f.puts "{"
        write_section(f, "TODO - untranslated (#{todo.size})", todo, existing)
        write_section(f, "translated (#{done.size})",          done, existing)
        f.puts "}"
      end
      @tables.delete(lang) if @tables
      file_for(lang)
    end

    # Refresh templates for the given languages, or for every language that
    # already has a file when none are named. Each merges new keys in without
    # clobbering existing translations. Returns the written paths.
    def dump_templates(*langs)
      langs = available if langs.empty?
      langs.map { |lang| dump_template(lang) }
    end

    private

    # Write one "# --- title ---" comment block of key => value lines (skips an
    # empty group). Untranslated lines fall back to the source default.
    def write_section(file, title, keys, existing)
      return if keys.empty?
      file.puts "  # --- #{title} ---"
      keys.each { |k| file.puts "  #{quote(k)} => #{quote(existing[k] || defaults[k])}," }
    end

    def defaults
      @defaults ||= {}
    end

    # Memoized per-language table; parsed at most once.
    def table(lang)
      @tables ||= {}
      @tables[lang] ||= load_table(lang)
    end

    # Parse <lang>.rb into a Hash. Wrapped in parens so a leading "{" is always
    # read as a hash literal. Any error degrades to an empty table (-> defaults).
    def load_table(lang)
      path = file_for(lang)
      return {} unless File.exist?(path)
      src = File.open(path, "r:UTF-8") { |f| f.read }
      result = eval("(\n" + src + "\n)")
      result.is_a?(Hash) ? result : {}
    rescue SyntaxError, StandardError => error
      p "[I18n] failed to load #{path} (#{error}) - using defaults"
      {}
    end

    def file_for(lang)
      File.join(DIR, "#{lang}.rb")
    end

    def persisted_language
      ModLoader.nvram[:language] if ModLoader.respond_to?(:nvram)
    end

    def ensure_dir
      Dir.mkdir(DIR) unless Dir.exist?(DIR)
    end

    # Minimal double-quote escaping; leaves multibyte (Cyrillic etc.) readable.
    def quote(str)
      '"' + str.to_s.gsub(/[\\"\n]/) { |c| c == "\n" ? "\\n" : "\\" + c } + '"'
    end
  end
end
end

end # not $imported["IDL-ModLoaderI18n"]
