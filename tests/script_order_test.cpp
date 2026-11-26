#include "../src/ModLoader/ScriptOrder.hpp"
#include <cassert>
#include <fstream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
    assert(argc == 2);
    // The test directory is supplied by the runner within its workspace.
    const std::filesystem::path root(argv[1]);
    std::filesystem::create_directories(root / "3 - Directory.rb");
    for (const auto* name : {"13 - ViewportEffects.rb", "9 - ModLoaderNVRAM.rb",
                            "13 - ModLoaderDisplay.rb", "9 - ModLoaderLifecycle.rb",
                            "bad.rb", "x - Invalid.rb", "2 - Ignored.txt"})
        std::ofstream(root / name) << "# test\n";
    int invalid = 0;
    const auto entries = rm_modloader::scripts::ordered_entries(root, [&](const auto&) { ++invalid; });
    std::vector<std::string> names;
    for (const auto& [priority, entry] : entries) names.push_back(entry.path().filename().string());
    assert((names == std::vector<std::string>{"9 - ModLoaderLifecycle.rb", "9 - ModLoaderNVRAM.rb",
        "13 - ModLoaderDisplay.rb", "13 - ViewportEffects.rb", "bad.rb", "x - Invalid.rb"}));
    assert(invalid == 2);
    // Identical results on repeated enumeration, including invalid-name ties.
    const auto again = rm_modloader::scripts::ordered_entries(root, [](const auto&) {});
    for (size_t i = 0; i < again.size(); ++i)
        assert(again[i].second.path().filename().string() == names[i]);
}
