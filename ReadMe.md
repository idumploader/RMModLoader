The modification allows user to execute custom ruby script in RPG Maker VX Ace.
Custom scripts are located at "mod_loader\scripts".
Also mod loader has built-in feature to change game resolution (HRFix). If you want to disable this, change "hrfix_enable" to false in config and delete "mod_loader\scripts\400 - HRFix.rb".
\*CURRENT ONLY SUPPORTED RGSS VERSION IS 3.0.1.1\*

Usage:
1. Download the mod from "Download" tab
2. Extract all files to game folder
3. Run "Loader.exe"

Built-in custom scripts:
* GraphicsReplace: Can be used to replace some in-game assets at runtime. The script searches at "mod_loader" folder. For example, placing file "my_game_title.png" at "mod_loader\Graphics\Pictures" replaces  in-game "Graphics\Pictures\my_game_title.png"
* HRFix: Fixes some problems when getting higher resolution than 640x480. Works only with "hrfix_enable"=true in config

Known problems:
* HRFix can significantly lower the FPS

Used Libraries:
* [nlohmann json](github.com/nlohmann/json)