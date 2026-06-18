#==============================================================================
# PrependPatch - a Module#prepend backport for the RGSS 1.9.2 runtime.
#
# RPG Maker VX Ace runs Ruby 1.9.2, which predates Module#prepend (added in
# 2.0). This preinit script emulates it: the target's own methods are moved into
# a hidden "origin" module, then the origin and the patch module are re-included
# so the patch ends up ABOVE the originals in the ancestor chain. As a result
# the patch's methods win method lookup and `super` from them falls through to
# the original implementation - the same ergonomics as a real prepend, with no
# alias-name pollution.
#
# Usage:
#   module CacheFix
#     def normal_bitmap(path)
#       return @cache[path] if include?(path)
#       super                       # reaches the original Cache.normal_bitmap
#     end
#   end
#   ModLoader.prepend_module(Cache.singleton_class, CacheFix)  # for self.* methods
#   ModLoader.prepend_module(Window_Base, SomeFix)             # for instance methods
#
# Caveat vs. real prepend: methods (re)defined on the target AFTER the call land
# directly on the class, which sits below the patch in the chain, so they would
# shadow it. Prepend already fully-defined classes - the usual case for engine
# patches - and this matches real prepend behaviour.
#
# Version gate: ModLoader.version != "2.4"
#==============================================================================

if ModLoader.version != "2.4"

module ModLoader
  module_function

  # Weave +patch+'s instance methods above +target+'s own methods so that the
  # patch wins method lookup and `super` falls through to the original.
  #
  # @param target [Module] class/module to patch (use .singleton_class for self.* methods)
  # @param patch  [Module] module whose instance methods override target's
  # @return [Module] target
  def prepend_module(target, patch)
    origin = Module.new

    # Move target's OWN methods (every visibility) into the origin module,
    # preserving their visibility, and strip them off the target.
    move = lambda do |names, visibility|
      names.each do |name|
        origin.send(:define_method, name, target.instance_method(name))
        origin.send(visibility, name) unless visibility == :public
        target.send(:remove_method, name)
      end
    end
    move.call(target.public_instance_methods(false),    :public)
    move.call(target.protected_instance_methods(false), :protected)
    move.call(target.private_instance_methods(false),   :private)

    # Re-include: origin first (carries the originals, lower in the chain), then
    # the patch on top. Ancestors become [target, patch, origin, super...].
    target.send(:include, origin)
    target.send(:include, patch)
    target
  end
end

end # ModLoader.version != "2.4"
