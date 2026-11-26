# Core features load in the same order as the original numbered entrypoints.
# Each component owns its import guard; reload evaluates this list again.
[
  'core/resetter.rb',
  'input/keyboard.rb',
  'input/clipboard.rb',
  'input/gamepad.rb',
  'input/capture.rb',
  'input/line_input.rb',
  'input/text_input.rb',
  'core/lifecycle.rb',
  'core/nvram.rb',
  'modmenu/bootstrap.rb',
  'core/i18n.rb',
  'modmenu/defaults.rb',
  'core/optimizations.rb',
  'renderer/settings.rb',
  'display/settings.rb',
  'display/live_resize.rb',
  'renderer/viewport_effects.rb',
  'input/settings.rb',
  'input/movement.rb',
].each { |component| ModLoader::Framework.load(component) }
