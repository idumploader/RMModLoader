require_relative 'support/modmenu_rgss'

class ModMenuLayoutTest < Minitest::Test
  M = ModLoader::ModMenu

  class DrawingBitmap < Bitmap
    attr_reader :fills
    def initialize(width, height)
      super
      @fills = []
    end
    def fill_rect(x, y, width, height, _color)
      @fills << Rect.new(x, y, width, height)
    end
    def gradient_fill_rect(x, y, width, height, *_colors)
      @fills << Rect.new(x, y, width, height)
    end
  end

  class DrawingWindow < Window_Base
    include ModMenu_ItemDrawing
    attr_reader :text_draws

    def initialize
      super(0, 0, 640, 480)
      @text_draws = []
      @contents = DrawingBitmap.new(616, 456)
    end

    def gauge_back_color; Color.new(0, 0, 0, 255); end

    def items=(items)
      @list = items.map { |item| { :ext => item } }
    end

    def draw_text(*args)
      if args.first.is_a?(Rect)
        rect, text, align = args
      else
        x, y, width, height, text, align = args
        rect = Rect.new(x, y, width, height)
      end
      @text_draws << [rect.clone, text, align || 0]
    end
  end

  def setup
    @window = DrawingWindow.new
  end

  def teardown
    @window.dispose
  end

  def test_long_translated_title_collapses_options_that_would_overlap_it
    item = M::ToggleItem.new('World sync', :default => true,
      :off_text => 'WHITELIST', :on_text => 'BLACKLIST')
    translations = { 'World sync' => 'Синх. мира: чёрный список',
      'WHITELIST' => 'Белый список', 'BLACKLIST' => 'Чёрный список' }
    row = Rect.new(20, 0, 600, 24)
    M.stub(:tr, proc { |key| translations.fetch(key, key) }) { item.draw(@window, row) }

    assert_equal ['Синх. мира: чёрный список', '<  Чёрный список  >'], @window.text_draws.map { |draw| draw[1] }
    assert_separate_fields(row)
  end

  def test_short_choices_remain_inline_when_they_fit_beside_the_title
    item = M::ChoiceItem.new('Mode', :values => [:a, :b], :labels => ['One', 'Two'], :default => :a)
    row = Rect.new(20, 0, 480, 24)
    item.draw(@window, row)
    assert_equal ['Mode', 'One', 'Two'], @window.text_draws.map { |draw| draw[1] }
    assert_separate_fields(row)
  end

  def test_short_labels_and_inline_values_reserve_glyph_overhang
    item = M::ToggleItem.new('Wait for new frame', :default => true,
      :off_text => 'OFF', :on_text => 'ВКЛ')
    item.draw(@window, Rect.new(0, 0, 600, 27))
    padding = M.ui_pixels(4)
    @window.text_draws.each do |rect, text, _align|
      assert_operator rect.width, :>=, @window.text_size(text).width + padding
    end
  end

  def test_short_title_leaves_all_remaining_width_for_options
    labels = ['Low detail', 'Medium detail', 'High detail']
    item = M::ChoiceItem.new('Mode', :values => [:low, :medium, :high],
      :labels => labels, :default => :medium)
    row = Rect.new(20, 0, 600, 24)
    item.draw(@window, row)
    assert_equal ['Mode'] + labels, @window.text_draws.map { |draw| draw[1] }
    assert_separate_fields(row)
  end

  def test_narrow_rows_keep_the_title_and_compact_value_in_separate_bounds
    item = M::ChoiceItem.new('Очень длинное название настройки',
      :values => [:a, :b], :labels => ['Первый вариант', 'Второй вариант'], :default => :b)
    row = Rect.new(20, 0, 220, 24)
    item.draw(@window, row)
    assert_equal '<  Второй вариант  >', @window.text_draws.last[1]
    assert_equal (row.width * 0.6).to_i, @window.text_draws.first[0].width
    assert_separate_fields(row)
  end

  def test_long_compact_options_keep_arrows_in_the_same_bounds_when_selection_changes
    labels = ['Очень длинное значение ' * 8, 'Ещё более длинное значение ' * 16]
    item = M::ChoiceItem.new('Длинное название настройки',
      :values => [:a, :b], :labels => labels, :default => :a)

    [220, 480, 600].each do |width|
      row = Rect.new(20, 48, width, 24)
      bounds = []
      [:a, :b].each_with_index do |value, index|
        @window.text_draws.clear
        item.value = value
        item.draw(@window, row)

        assert_equal 2, @window.text_draws.size
        rect, text, alignment = @window.text_draws.last
        assert_equal "<  #{labels[index]}  >", text
        assert_equal 2, alignment
        assert_equal row.y, rect.y
        assert_equal row.height, rect.height
        assert_equal row.x + row.width - 4, rect.x + rect.width
        assert_separate_fields(row)
        bounds << rect
      end
      assert_equal bounds[0], bounds[1]
    end
  end

  def test_slider_gauge_stays_between_a_long_title_and_its_value
    color = Color.new(255, 255, 255, 255)
    item = M::SliderItem.new('Длинное название настройки',
      :default => 50, :gauge => [color, color])
    @window.items = [item]
    row = Rect.new(20, 0, 600, 24)
    item.draw(@window, row)
    title = @window.text_draws.first[0]
    value_rect, value = @window.text_draws.last
    value_left = value_rect.x + value_rect.width - @window.text_size(value).width
    assert_equal 2, @window.contents.fills.size
    @window.contents.fills.each do |rect|
      assert_operator rect.x, :>, title.x + title.width
      assert_operator rect.x + rect.width, :<, value_left
    end
    assert_separate_fields(row)
  end

  def test_slider_hides_its_gauge_when_only_the_value_fits
    color = Color.new(255, 255, 255, 255)
    item = M::SliderItem.new('Длинное название настройки', :default => 50,
      :gauge => [color, color], :format => proc { |value| "#{value} секунд" })
    @window.items = [item]
    row = Rect.new(20, 0, 220, 24)
    item.draw(@window, row)
    assert_empty @window.contents.fills
    assert_equal '50 секунд', @window.text_draws.last[1]
    assert_separate_fields(row)
  end

  def slider(label, opts = {})
    color = Color.new(255, 255, 255, 255)
    M::SliderItem.new(label, { :default => 0, :gauge => [color, color] }.merge(opts))
  end

  def gauge_bounds(items)
    @window.contents.fills.clear
    items.each_with_index { |item, index| item.draw(@window, Rect.new(20, index * 24, 600, 24)) }
    @window.contents.fills.each_slice(2).map { |background, _fill| [background.x, background.width] }
  end

  def test_sliders_share_both_gauge_edges_within_a_section
    sliders = [slider('Амплитуда волны', :max => 40),
      slider('Длина волны', :min => 8, :max => 240, :default => 120),
      slider('Скорость волны', :max => 50, :default => 10,
        :format => proc { |v| format('%.2f rad/f', v / 100.0) })]
    @window.items = [M::HeaderItem.new('Волна')] + sliders
    bounds = gauge_bounds(sliders)
    assert_equal 3, bounds.size
    assert_equal 1, bounds.uniq.size
  end

  def test_headers_separate_slider_groups_but_other_items_do_not
    first = [slider('A'), slider('BB')]
    second = [slider('Longer slider title'), slider('Other',
      :format => proc { |v| "#{v} units" })]
    @window.items = [first[0], M::ToggleItem.new('Flag', :default => true), first[1],
      M::HeaderItem.new('Next section')] + second
    bounds = gauge_bounds(first + second)
    assert_equal bounds[0], bounds[1]
    assert_equal bounds[2], bounds[3]
    refute_equal bounds[0], bounds[2]
  end

  def test_range_and_off_label_reserve_space_before_the_current_value_grows
    items = [slider('Amount', :max => 1000), slider('Other', :max => 10,
      :format => proc { |v| v == 0 ? 'off' : v.to_s })]
    @window.items = items
    before = gauge_bounds(items)
    items[0].value = 1000
    items[1].value = 10
    assert_equal before, gauge_bounds(items)
    assert_equal before[0], before[1]
  end

  def test_slider_group_remeasures_translated_titles
    items = [slider('First'), slider('Second')]
    @window.items = items
    before = gauge_bounds(items)
    M.stub(:tr, proc { |key| key == 'Second' ? 'Более длинная подпись' : key }) do
      after = gauge_bounds(items)
      assert_equal after[0], after[1]
      assert_operator after[0][0], :>, before[0][0]
    end
  end

  def assert_separate_fields(row)
    title = @window.text_draws.first[0]
    @window.text_draws.drop(1).each do |rect, _text, _align|
      assert_operator rect.x, :>, title.x + title.width
      assert_operator rect.width, :>, 0
      assert_operator rect.x + rect.width, :<=, row.x + row.width
    end
  end
end
