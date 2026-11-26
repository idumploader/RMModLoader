#include "../src/ModLoader/DisplayGeometry.hpp"
#include <cassert>
#include <initializer_list>

int main() {
    using rm_modloader::display::fit;
    auto a = fit(1920, 1080, 640, 480);
    assert(a.x == 240 && a.y == 0 && a.width == 1440 && a.height == 1080);
    auto b = fit(1280, 1024, 1920, 1080);
    assert(b.x == 0 && b.y == 152 && b.width == 1280 && b.height == 720);
    auto c = fit(640, 480, 640, 480);
    assert(c.x == 0 && c.y == 0 && c.width == 640 && c.height == 480);
    auto d = fit(1001, 701, 640, 480);
    assert(d.x == 33 && d.y == 0 && d.width == 934 && d.height == 701);
    auto e = fit(320, 200, 640, 480);
    assert(e.x == 27 && e.y == 0 && e.width == 266 && e.height == 200);
    assert(fit(0, 480, 640, 480).width == 0);
    assert(fit(640, 480, 640, 0).height == 0);
    for (auto size : {rm_modloader::display::Rect{0, 0, 1920, 1080},
                      rm_modloader::display::Rect{0, 0, 1001, 701},
                      rm_modloader::display::Rect{0, 0, 320, 200}}) {
        auto stretched = fit(size.width, size.height, 640, 480, false);
        assert(stretched.x == 0 && stretched.y == 0);
        assert(stretched.width == size.width && stretched.height == size.height);
    }
    assert(fit(0, 480, 640, 480, false).width == 0);
}
