
$imported ||= {}

if not $imported["IDL-ModResetter"]

$imported["IDL-ModResetter"] = "1.0"

module ModResetter

	class ClassMethodSnapshot
		attr_accessor :msymbol
		attr_accessor :orig_object
	end

	class ClassSnapshot
		attr_accessor :object_symbol
		attr_accessor :singletons
		attr_accessor :methods
		attr_accessor :orig_object
	end

	BLACKLIST_CLASSES = [
		:Object,
		:Kernel,
		:Module,
		:Class,
		:Symbol,
		:Exception,
		:TRUE,
		:FALSE,
		:TrueClass,
		:NIL,
		:StringClass,
		:FalseClass,
		:String,
		:Numeric,
		:Marshal,
		:Enumerable,
		:Range,
		:Fixnum,
		:Integer,
		:Float,
		:Bignum,
		:Array,
		:Hash,
		
		:ModResetter
	]
	
	@initted = false
	@classes_snapshot = nil
	
	def self.snapshot_for_class(cls, cls_symbol)
		class_snapshot = ClassSnapshot.new
		class_snapshot.object_symbol = cls_symbol
		class_snapshot.orig_object = cls
		
		class_snapshot.singletons = cls.methods(false).collect do |method_symbol|
			method_snapshot = ClassMethodSnapshot.new
			method_snapshot.msymbol = method_symbol
			method_snapshot.orig_object = cls.method(method_symbol).unbind
			
			method_snapshot
		end
		
		class_snapshot.methods = cls.instance_methods(false).collect do |method_symbol|
			method_snapshot = ClassMethodSnapshot.new
			method_snapshot.msymbol = method_symbol
			method_snapshot.orig_object = cls.instance_method(method_symbol)
			
			method_snapshot
		end
		
		return class_snapshot
	end
	
	def self.snapshot_all_classes
		@classes_snapshot = []
		Object.constants.each do |constant_symbol|
			next if BLACKLIST_CLASSES.include?(constant_symbol)
			# p "#{constant_symbol}"
			constant = Object.const_get(constant_symbol)
			next unless [Module, Class].include?(constant.class)
			
			# p "Snapshotting... #{constant}"
			@classes_snapshot.push(snapshot_for_class(constant, constant_symbol))
		end
	end
	
	def self.snapshot_all
		snapshot_all_classes
	end
	
	def self.snapshot_all_if_needed
		return if @initted
		snapshot_all
		@initted = true
		
		# p @classes_snapshot
	end
	
	
	def self.inject_into(cls)
		return cls.method(:instance_eval)
	end
	
	def self.restore_classes_snapshot
		@classes_snapshot.each do |snapshot|
			# remove excess singletons
			all_methods = snapshot.singletons.collect do |method_snapshot|
				method_snapshot.msymbol
			end
			snapshot.orig_object.methods(false).each do |method_symbol|
				next if all_methods.include?(method_symbol)
				# p "excess symbol: #{method_symbol} for #{snapshot.object_symbol}"
				
				snapshot.orig_object.singleton_class.instance_eval do
					remove_method(method_symbol)
				end
			end
			
			# remove excess methods
			all_methods = snapshot.methods.collect do |method_snapshot|
				method_snapshot.msymbol
			end
			snapshot.orig_object.instance_methods(false).each do |method_symbol|
				next if all_methods.include?(method_symbol)
				# p "excess symbol: #{method_symbol} for #{snapshot.object_symbol}"
				
				snapshot.orig_object.instance_eval do
					remove_method(method_symbol)
				end
			end
		
			# Restore all singletons
			snapshot.singletons.each do |singleton_snapshot|
				snapshot.orig_object.instance_eval do
					define_singleton_method(
						singleton_snapshot.msymbol,
						singleton_snapshot.orig_object)
				end
			end
			
			# Restore all methods
			snapshot.methods.each do |method_snapshot|
				snapshot.orig_object.instance_eval do
					define_method(
						method_snapshot.msymbol,
						method_snapshot.orig_object)
				end
			end
		end
	end
	
	def self.restore_snapshot
		restore_classes_snapshot
	end
end

# ---- Test zone -----------
# class TestClass
	# def self.foo_singleton
		# return "foo"
	# end
	
	# def foo_method
		# return "foo"
	# end
# end

# ModResetter.snapshot_all_if_needed

# $test_class = TestClass.new
# $test_singleton = TestClass.method(:foo_singleton)
# $test_method = $test_class.method(:foo_method)

# p "TestClass before hook: (singleton) #{TestClass.foo_singleton}, (method) #{$test_class.foo_method}"

# class TestClass
	# def self.foo_singleton
		# return "bar"
	# end
	
	# def foo_method
		# return "bar"
	# end
# end

# p "TestClass hooked"
# p "TestClass bound method: (singleton) #{$test_singleton.call}, (method) #{$test_method.call}"
# p "TestClass after hook: (singleton) #{TestClass.foo_singleton}, (method) #{$test_class.foo_method}"

# ModResetter.restore_snapshot

# p "TestClass after restore: (singleton) #{TestClass.foo_singleton}, (method) #{$test_class.foo_method}"

# ---- Helper function -------

ModResetter.snapshot_all_if_needed

def mod_reset
	ModResetter.restore_snapshot
	files_match_re = /(\d+) ?- ?\w+\.rb/
	
	scripts_dir = File.join(ModLoader.data_directory, "scripts")
	scripts_files = Dir.entries(scripts_dir)
	scripts_files.reject! do |file|
		not file.end_with?(".rb")
	end
	
	scripts_files.sort! do |left, right|
		left_number = right_number = 0
	
		left_number = $1.to_i if left =~ files_match_re
		right_number = $1.to_i if right =~ files_match_re
		
		left_number <=> right_number
	end
	
	scripts_files.select do |filename|
		filepath = File.join(scripts_dir, filename)
		next if File.directory?(filepath)
		begin
			# load(filepath, encoding: 'UTF-8')
			content = File.read(filepath, encoding: 'UTF-8')
			eval(content, TOPLEVEL_BINDING, filepath)
		rescue Exception => err
			p "Failed to execute script: #{filepath}. #{err}"
		end
	end
end

module ExecutorEnvironment
	def self.reset
		mod_reset
	end
end

end # not $imported["IDL-ModResetter"]