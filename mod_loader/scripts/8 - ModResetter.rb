
$imported ||= {}

if not $imported["IDL-ModResetter"]

$imported["IDL-ModResetter"] = "1.0"

module ModResetter

	ClassMethodSnapshot = Struct.new(:msymbol, :orig_object)

	ClassSnapshot = Struct.new(:object_symbol, :singletons, :methods, :orig_object)

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

	def self.execute_all_scripts

		# Clear the bundled scripts' IDL- $imported guards so they re-run on reload
		# (keep our own, or ModResetter would re-snapshot itself). Without this the
		# version guards on every script would skip re-execution after a reset.
		$imported.delete_if { |key, _| key.is_a?(String) && key.start_with?("IDL-") && key != "IDL-ModResetter" } if $imported

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

		scripts_files.each do |filename|
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
end

ModResetter.snapshot_all_if_needed

def mod_reset
	ModResetter.restore_snapshot
	ModResetter.execute_all_scripts
end

module ExecutorEnvironment
	def self.reset
		mod_reset
	end
end

end # not $imported["IDL-ModResetter"]