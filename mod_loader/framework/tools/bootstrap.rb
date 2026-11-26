# Snapshot tools retain their own reload guards; install the fix after the tool.
ModLoader::Framework.load('tools/map_snapshotter.rb')
ModLoader::Framework.load('tools/map_snapshotter_viewport_fix.rb')
