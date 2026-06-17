#==============================================================================
# LinesChecker — проверка длины и ширины переводов в базах данных и на картах.
#
# Что проверяет:
#   • Текст в диалоговых окнах   (101 + 401)
#   • Пункты выбора              (102)
#   • Прокручиваемый текст       (105 + 405)
#   • Описания предметов/навыков (Items, Skills, Weapons, Armors — @description)
#
# Запуск:
#   • Вручную: mapcheck
#   • Автоматически при старте игры — раскомментировать строку в Scene_Title#start
#
# Отчёт сохраняется в LongDialogLines.txt в папке проекта.
#==============================================================================

$imported ||= {}
if not $imported["IDL-LinesChecker"]
$imported["IDL-LinesChecker"] = "2.0"

module LinesChecker
  # ---- Лимиты ----

  # Прокручиваемый текст — char-based (геометрия окна нестабильна).
  MAX_LEN = 51

  # Диалоговое окно (101 + 401)
  DIALOG_MAX_WIDTH          = 614
  DIALOG_PORTRAIT_DEDUCTION = 112  # сужение под аватарку слева

  # Описания в Window_Help.
  # contents_width = Graphics.width - standard_padding * 2 = 640 - 24 = 616.
  # 4 строки — в WindowFix.rb Window_Help увеличен с 2 до 4 строк.
  DESCRIPTION_MAX_WIDTH = 616
  DESCRIPTION_MAX_LINES = 4

  # Window_ChoiceList авторазмер по тексту, но капается Graphics.width = 640.
  # При cap contents_width = 640 - padding*2 = 616. Escape-коды (\C[n], \N[n])
  # съедаются draw_text_ex и не занимают места — потому только пикселями.
  CHOICE_MAX_WIDTH = 616

  REPORT_FILE = "LongDialogLines.txt"

  # Базы данных с полем @description
  DESCRIPTION_DATABASES = {
    "Items"   => "item",
    "Skills"  => "skill",
    "Weapons" => "weapon",
    "Armors"  => "armor",
  }

  # ---- Вспомогательный Window для измерения ширины ----

  class MeasureWindow < Window_Base
    def process_normal_character(c, pos)
      pos[:x] += text_size(c).width
    end

    # Полное измерение с учётом RGSS escape-кодов (\C[n], \N[n] и т.п.).
    def measure(text)
      reset_font_settings
      text = convert_escape_characters(text)
      pos = { :x => 0, :y => 0, :new_x => 0, :height => calc_line_height(text) }
      process_character(text.slice!(0, 1), text, pos) until text.empty?
      pos[:x]
    end

    # Быстрый путь для строк без escape-кодов: один text_size вместо char-by-char.
    # reset_font_settings на случай если предыдущий measure() оставил font в \C[n].
    def measure_plain(text)
      reset_font_settings
      contents.text_size(text).width
    end
  end

  # Память: при массовых проходах (mapcheck, HTTP /measure_batch) одна и та же
  # строка часто встречается десятки раз — кэш даёт x5-10 ускорение даже без
  # fast-path.
  def self.text_width(text)
    @measure_window  ||= MeasureWindow.new(0, 0, 0, 0)
    @text_width_cache ||= {}
    cached = @text_width_cache[text]
    return cached if cached
    width = text.include?("\\") ? @measure_window.measure(text.dup)
                                : @measure_window.measure_plain(text)
    @text_width_cache[text] = width
    width
  end

  # ---- Точка входа ----

  def self.run
    # Имя игрока на максимум — тестируем худший случай для \N[1]
    $game_actors[1].name = "щщщщщщ"

    issues = []
    check_all_maps(issues)
    check_all_descriptions(issues)

    if issues.empty?
      msgbox "Все тексты в пределах допустимой длины."
    else
      save_report(issues)
      msgbox "Найдено #{issues.size} превышений. Отчёт сохранён в файл #{REPORT_FILE}."
    end
  rescue => e
    msgbox "Ошибка при проверке: #{e.message}\n#{e.backtrace.first}"
  end

  # ---- Карты: диалоги, выбор, прокрутка ----

  def self.check_all_maps(issues)
    Dir.glob("Data/Map*.rvdata2").sort.each do |file|
      next unless file =~ /Map(\d+)\.rvdata2$/
      map_id = $1.to_i
      map = load_data(file)
      map.events.each_value do |event|
        check_event(event, "map#{map_id}", issues)
      end
    end
  end

  def self.check_event(event, source, issues)
    event.pages.each do |page|
      list = page.list
      next if list.nil?
      i = 0
      while i < list.size
        case list[i].code
        when 101 then i = check_dialog(list, i, source, issues)
        when 102 then       check_choices(list[i], source, issues); i += 1
        when 105 then i = check_scroll(list, i, source, issues)
        else                i += 1
        end
      end
    end
  end

  # 101 (Show Text Attributes) + N × 401 (Text Continuation)
  def self.check_dialog(list, i, source, issues)
    character_name = list[i].parameters[0].to_s
    max_width = character_name.empty? ? DIALOG_MAX_WIDTH
                                      : DIALOG_MAX_WIDTH - DIALOG_PORTRAIT_DEDUCTION
    i += 1
    while i < list.size && list[i].code == 401
      report_too_wide(list[i].parameters[0], max_width, source, issues)
      i += 1
    end
    i
  end

  # 102 (Show Choices). Окно выбора одностольно — \n не переносит на новую
  # строку, а ломает рендер; отдельно репортим многосторочные пункты.
  def self.check_choices(cmd, source, issues)
    choices = cmd.parameters[0]
    return unless choices.is_a?(Array)
    choices.each do |choice|
      next unless choice.is_a?(String)
      tag = "#{source} (выбор)"
      if choice.include?("\n")
        issues << "#{tag}: многосторочный пункт (#{choice.count("\n") + 1} строк): #{choice.inspect}"
      end
      report_too_wide(choice, CHOICE_MAX_WIDTH, tag, issues)
    end
  end

  # 105 (Show Scrolling Text) + N × 405
  def self.check_scroll(list, i, source, issues)
    i += 1
    while i < list.size && list[i].code == 405
      report_too_long(list[i].parameters[0], MAX_LEN, source, "скролл", issues)
      i += 1
    end
    i
  end

  # ---- Описания @description в Items/Skills/Weapons/Armors ----

  def self.check_all_descriptions(issues)
    DESCRIPTION_DATABASES.each do |basename, kind|
      data = load_data("Data/#{basename}.rvdata2")
      data.each do |entry|
        next if entry.nil?
        check_description(entry, kind, issues)
      end
    end
  end

  def self.check_description(entry, kind, issues)
    desc = entry.description.to_s
    return if desc.empty?

    source = "#{kind} #{entry.id} (#{entry.name})"
    lines = desc.split("\n", -1)

    if lines.size > DESCRIPTION_MAX_LINES
      issues << "#{source}: больше #{DESCRIPTION_MAX_LINES} строк (#{lines.size})"
    end

    lines.each_with_index do |line, idx|
      next unless line.is_a?(String)
      width = text_width(line)
      next if width <= DESCRIPTION_MAX_WIDTH
      issues << "#{source} строка #{idx + 1}: #{line} (длина: #{line.length}, ширина: #{width})"
    end
  end

  # ---- Хелперы записи в отчёт ----

  def self.report_too_wide(line, max_width, source, issues)
    return unless line.is_a?(String)
    width = text_width(line)
    return if width <= max_width
    issues << "#{source}: #{line} (длина: #{line.length}, ширина: #{width})"
  end

  def self.report_too_long(line, max_len, source, kind, issues)
    return unless line.is_a?(String)
    return if line.length <= max_len
    issues << "#{source}: (#{kind}) #{line} (длина: #{line.length})"
  end

  def self.save_report(lines)
    File.open(REPORT_FILE, "w:UTF-8") do |f|
      lines.each { |l| f.puts l }
    end
  end
end

# Автоматический запуск при старте игры
class Scene_Title
  alias :lines_checker_orig_start :start
  def start
    lines_checker_orig_start
    # LinesChecker.run
  end
end

def check_char_width
  Window_Base.new(0, 0, 0, 0).text_size("щщщщщ щщщщщ щщщщщ щщщщщ щщщщщ щщщщщ щщщщщ щ")
end

def mapcheck
  LinesChecker.run
end

end # not $imported["IDL-LinesChecker"]
