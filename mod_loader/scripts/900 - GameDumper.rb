if ModLoader.version_major > 2 or ModLoader.version_minor >= 7

module GameDumper

	def self.mkdir_p(path)
		part_path = ""
		path.split(/[\/\\]/).each do |directory|
			part_path = File.join(part_path, directory) unless part_path.empty?
			part_path = directory if part_path.empty?
			Dir.mkdir(part_path) unless Dir.exists?(part_path)
		end
	end

	def self.dump_all(folder)
		ModLoader.list_files.each do |file_path|
			file_path.force_encoding("UTF-8")
			p "Dumping #{file_path}..."
			
			output_path = File.join(folder, file_path)
			mkdir_p(File.dirname(output_path)) unless Dir.exists?(File.dirname(output_path))
			
			data = ModLoader.read_file(file_path)
			File.open(output_path, 'wb') { |f| f.write(data) }
		end
	end

end

if ExecutorModule::ENABLED

module ExecutorEnvironment

	def self.dump_rvdata(folder)
		GameDumper.dump_all(folder)
	end

end

end # ExecutorModule::ENABLED

def t1
	GameDumper.mkdir_p("dumped/Graphics\\Animations")
end

def t2
	GameDumper.dump_all("dumped")
end

end # ModLoader.version_major > 2 or ModLoader.version_minor >= 7