# Internal ModMenu component; load through modmenu/bootstrap.rb.
module ModLoader
module ModMenu
  DEFAULT_CATEGORY = "General"
  DEFAULT_HOTKEY   = ModLoader::Keyboard::F10

  #--------------------------------------------------------------------------
  # Entry kinds. Each knows how to draw itself into a window row and how to
  # react to Enter / Left / Right. The window stays dumb; entries own behaviour.
  #--------------------------------------------------------------------------

  # Base entry: a plain selectable label (rarely used directly).
  class Item
    attr_reader :label

    def initialize(label, opts = {})
      @label = label.to_s
      @opts  = opts
      ModMenu.register_text(@label) unless @opts[:translate] == false
      description = @opts[:description]
      ModMenu.register_text(description) if description.is_a?(String)
    end

    def selectable?
      value = @opts.fetch(:enabled, true)
      value.respond_to?(:call) ? !!value.call : !!value
    end
    def identifier; @opts.fetch(:id, @label); end

    # The label resolved through I18n (the literal doubles as the key; an
    # untranslated label comes back unchanged).
    def label_text; @opts[:translate] == false ? @label : ModMenu.tr(@label); end

    # Descriptions remain translatable even when the label is a player's name.
    def description_text
      text = @opts[:description]
      text = text.call if text.respond_to?(:call)
      text ? ModMenu.tr(text.to_s) : ''
    end

    def label_color(window, default = window.normal_color)
      case color = @opts[:color]
      when nil; default
      when :destructive; window.knockout_color
      when Color; color
      else
        raise ArgumentError, "Unsupported ModMenu label color: #{color.inspect}"
      end
    end

    # Draw one row. +window+ is the ModMenu_ListWindow, +rect+ its text rect.
    def draw(window, rect)
      window.reset_font_settings
      window.change_color(label_color(window), selectable?)
      if @opts[:detail]
        gap = 12
        name_width = (rect.width * 0.45).to_i
        window.draw_text(rect.x, rect.y, name_width, rect.height, label_text)
        window.change_color(window.system_color, selectable?)
        window.draw_text(rect.x + name_width + gap, rect.y,
                         rect.width - name_width - gap, rect.height, @opts[:detail].to_s, 2)
      else
        window.draw_text(rect, label_text, 0)
      end
    end

    def on_ok(window);    end
    def on_left(window);  end
    def on_right(window); end
  end

  # A non-selectable section heading.
  class HeaderItem < Item
    def selectable?; false; end

    def draw(window, rect)
      window.change_color(label_color(window, window.system_color))
      window.draw_text(rect, label_text, 1)
      window.change_color(window.normal_color)
    end
  end

  # Runs a block on Enter. :close_after => true closes the menu afterwards.
  class ActionItem < Item
    def initialize(label, opts, block)
      super(label, opts)
      @block = block
    end

    def on_ok(window)
      result = @block.call if @block
      return false if result == false
      if @opts[:close_after] == :all
        window.close_menu
      elsif @opts[:close_after]
        window.request_close
      end
      result
    end
  end

  # The factory returns a fresh ModMenu_CommandWindow, or nil to decline.
  class WindowItem < ActionItem
    def on_ok(window)
      child = @block.call if @block
      window.open_child(child) if child
    end
  end

  # Shared value plumbing for toggle/slider/choice: resolves the current value
  # from :get / the NVRAM section / :default, and writes back through :set, the
  # section, and :on_change.
  class ValueItem < Item
    def initialize(label, opts)
      super(label, opts)
      @value = load_value
    end

    def key; @opts[:key]; end

    def value
      @opts[:get] ? @opts[:get].call : @value
    end

    def value=(new_value)
      @value = new_value
      @opts[:set].call(new_value)        if @opts[:set]
      ModMenu.section[key] = new_value    if key
      @opts[:on_change].call(new_value)   if @opts[:on_change]
      new_value
    end

    def draw(window, rect)
      window.reset_font_settings
      label = label_text
      # Measure the translated title in the active font. Keep a gap and reserve
      # space for the value even when a translation is longer than the row.
      title_width = [label_width(window), (rect.width * 0.6).to_i].min
      value_offset = title_width + 12
      lrect = rect.clone
      lrect.width = value_offset - 12
      window.change_color(label_color(window), selectable?)
      window.draw_text(lrect, label, 0)
      window.change_color(window.normal_color)
      vrect = rect.clone
      vrect.x += value_offset
      vrect.width = [rect.width - value_offset - 4, 1].max
      draw_value(window, vrect)
    end

    def label_width(window)
      window.menu_text_width(label_text)
    end

    # Override per kind. Default: plain right-aligned string.
    def draw_value(window, rect)
      window.draw_text(rect, value.to_s, 2)
    end

    private

    def load_value
      if @opts[:get]
        @opts[:get].call
      elsif key && ModMenu.section.key?(key)
        ModMenu.section[key]
      else
        @opts[:default]
      end
    end
  end

  # ON/OFF flag. Enter or Left/Right flips it.
  class ToggleItem < ValueItem
    def on_ok(window);    flip(window); end
    def on_left(window);  flip(window); end
    def on_right(window); flip(window); end

    def draw_value(window, rect)
      window.draw_inline_options(rect, [ModMenu.tr(off_text), ModMenu.tr(on_text)], value ? 1 : 0)
    end

    private

    def initialize(label, opts)
      super
      ModMenu.register_text(on_text)
      ModMenu.register_text(off_text)
    end

    def flip(window); self.value = !value; true; end
    def on_text;  @opts[:on_text]  || "ON";  end
    def off_text; @opts[:off_text] || "OFF"; end
  end

  # Integer in [min, max], stepped by Left/Right. Drawn as a gradient gauge plus
  # the value text. Colour pair via :gauge => [c1, c2] (palette index or Color).
  class SliderItem < ValueItem
    def on_left(window);  step(-1); end
    def on_right(window); step(+1); end

    def label_width(window)
      window.slider_group(self).map { |item| window.menu_text_width(item.label_text) }.max
    end

    def draw_value(window, rect)
      width = window.slider_group(self).map { |item| item.value_width(window) }.max
      window.draw_slider(rect, rate, gauge_colors(window), formatted, width)
    end

    # Reserve endpoints too, so ordinary digit changes and an "off" label do
    # not move the gauge. The current value covers custom intermediate formats.
    def value_width(window)
      [min, max, value].map { |number| window.menu_text_width(formatted(number)) }.max
    end

    private

    def step(dir)
      lo, hi, st = min, max, @opts[:step] || 1
      self.value = [[value + dir * st, lo].max, hi].min
    end

    def min; @opts[:min] || 0;   end
    def max; @opts[:max] || 100; end

    def rate
      lo, hi = min, max
      return 0.0 if hi == lo
      r = (value - lo).to_f / (hi - lo)
      r < 0 ? 0.0 : (r > 1 ? 1.0 : r)
    end

    def gauge_colors(window)
      g = @opts[:gauge]
      if g.is_a?(Array) && g.size == 2
        [window.menu_color(g[0]), window.menu_color(g[1])]
      else
        [window.mp_gauge_color1, window.mp_gauge_color2]   # blue by default
      end
    end

    def formatted(number = value)
      @opts[:format] ? @opts[:format].call(number) : number.to_s
    end
  end

  # Cycles a fixed list of values (wraps). Optional parallel :labels for display.
  class ChoiceItem < ValueItem
    def on_left(window);  cycle(-1); end
    def on_right(window); cycle(+1); end

    def draw_value(window, rect)
      list = values
      return if list.empty?
      cur = list.index(value) || 0
      window.draw_inline_options(rect, (0...list.size).map { |i| label_at(i) }, cur)
    end

    private

    def initialize(label, opts)
      super
      list   = opts[:values] || []
      labels = opts[:labels]
      list.each_index do |i|
        ModMenu.register_text(((labels && labels[i]) ? labels[i] : list[i]).to_s)
      end
    end

    def values; @opts[:values] || []; end

    def cycle(dir)
      list = values
      return if list.empty?
      i = list.index(value) || 0
      self.value = list[(i + dir) % list.size]
    end

    def label_at(i)
      labels = @opts[:labels]
      raw = (labels && labels[i]) ? labels[i].to_s : values[i].to_s
      ModMenu.tr(raw)
    end
  end

  # Both the global category registry and a submenu collect the same items.
  module EntryRegistration
    def header(label, opts = {}); register(HeaderItem.new(label, opts), opts[:category]); end
    def action(label, opts = {}, &block); register(ActionItem.new(label, opts, block), opts[:category]); end
    def window(label, opts = {}, &block); register(WindowItem.new(label, opts, block), opts[:category]); end
    def toggle(label, opts = {}); register(ToggleItem.new(label, opts), opts[:category]); end
    def slider(label, opts = {}); register(SliderItem.new(label, opts), opts[:category]); end
    def choice(label, opts = {}); register(ChoiceItem.new(label, opts), opts[:category]); end
    def submenu(label, opts = {}, &block); register(SubmenuItem.new(label, opts, block), opts[:category]); end
  end

  class CategoryItems
    include EntryRegistration
    attr_reader :items
    def initialize; @items = []; end
    def register(item, category = nil); @items << item; item; end
  end

  class MenuDefinition
    include EntryRegistration
    attr_reader :items, :opts
    def initialize(label, opts, block)
      @label, @opts, @block = label, opts, block
      rebuild unless dynamic?
    end
    def register(item, category = nil); @items << item; item; end
    def dynamic?; !!@opts[:refresh]; end
    def refresh_key; @opts[:refresh].call if dynamic?; end
    def valid?; !@opts[:valid] || @opts[:valid].call; end
    def prepare; rebuild if dynamic?; end
    def rebuild
      @items = [HeaderItem.new(@label, :translate => @opts[:translate])]
      @block.call(self) if @block
      @items << BackItem.new(@opts[:back] || 'Back')
    end
  end

  class SubmenuItem < Item
    attr_reader :definition
    def initialize(label, opts, block)
      super(label, opts)
      @definition = MenuDefinition.new(label, opts, block)
    end
    def on_ok(window)
      return false unless @definition.valid?
      window.open_child(ModMenu_SubmenuWindow.new(@definition))
    end
  end

  class BackItem < Item
    def on_ok(window); window.request_close; end
  end

end # module ModMenu
end # module ModLoader
