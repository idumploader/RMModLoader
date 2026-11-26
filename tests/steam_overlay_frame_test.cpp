#include "../src/ModLoader/SteamOverlay/FrameBuffer.hpp"
#include <algorithm>
#include <iostream>
#include <random>
#include <stdexcept>

using rm_modloader::steam_overlay::FrameBuffer;
static void require(bool value) { if (!value) throw std::runtime_error("overlay frame check failed"); }
int main() {
    std::mt19937 random(19201080);
    for (auto [width,height] : {std::pair{640,480},std::pair{1920,1080},std::pair{65,83},std::pair{1,1}}) {
        std::vector<uint32_t> reference(size_t(width)*height);
        for (auto& pixel:reference) pixel=random();
        for (const int strip_height:{1,41,height}) {
            for (const bool bottom_up:{false,true}) {
                FrameBuffer frame; frame.begin(width,height);
                for (int top=0;top<height;top+=strip_height) {
                    const int rows=std::min(strip_height,height-top);
                    // Reuse one strip after capture, as native RGSS does.
                    const int pitch=width+3;
                    std::vector<uint32_t> strip(size_t(pitch)*rows,0xdeadbeef);
                    for (int row=0;row<rows;++row)
                        std::copy_n(reference.data()+size_t(top+row)*width,width,
                                    strip.data()+size_t(bottom_up?rows-row-1:row)*pitch);
                    require(frame.append(0,top,width,rows,
                        strip.data()+(bottom_up?size_t(rows-1)*pitch:0),ptrdiff_t(pitch)*4*(bottom_up?-1:1)));
                    std::fill(strip.begin(),strip.end(),0);
                }
                require(frame.complete());
                require(std::equal(reference.begin(),reference.end(),frame.data()));
                // UI writes cannot mutate the source frame.
                frame.data()[0]^=0xffffffff;
                require(reference[0]!=frame.data()[0]);
                frame.clear(); require(!frame.complete());
            }
        }
        FrameBuffer tiled; tiled.begin(width,height);
        for (int top=0;top<height;top+=41) for (int left=0;left<width;left+=37) {
            const int w=std::min(37,width-left),h=std::min(41,height-top);
            require(tiled.append(left,top,w,h,reference.data()+size_t(top)*width+left,ptrdiff_t(width)*4));
        }
        require(tiled.complete()); require(std::equal(reference.begin(),reference.end(),tiled.data()));
        tiled.begin(width,height);
        require(!tiled.complete());
        require(!tiled.append(0,1,width,height,reference.data(),ptrdiff_t(width)*4));
        require(!tiled.complete());
        tiled.begin(width,height);
        require(!tiled.append(0,0,width,height,reference.data(),ptrdiff_t(width)*4-1));
        auto owned=std::make_shared<std::vector<uint32_t>>(reference);
        std::weak_ptr<std::vector<uint32_t>> weak=owned;
        FrameBuffer borrowed; borrowed.begin(width,height);
        require(!borrowed.borrow(owned->data(),ptrdiff_t(width)*4+4,owned));
        require(borrowed.borrow(owned->data(),ptrdiff_t(width)*4,owned));
        const auto* source=owned->data(); owned.reset();
        require(!weak.expired() && borrowed.complete() && borrowed.borrowed());
        require(borrowed.read_data()==source);
        auto source_owner=weak.lock();
        auto* writable=borrowed.data();
        require(writable!=source && !borrowed.borrowed());
        require(std::equal(reference.begin(),reference.end(),writable));
        writable[0]^=0xffffffff;
        require(source_owner->at(0)==reference[0]);
        source_owner.reset(); require(weak.expired());
        owned=std::make_shared<std::vector<uint32_t>>(reference); weak=owned;
        borrowed.begin(width,height);
        require(borrowed.borrow(owned->data(),ptrdiff_t(width)*4,owned));
        owned.reset(); borrowed.clear(); require(weak.expired());
        owned=std::make_shared<std::vector<uint32_t>>(reference.size());
        for (int row=0;row<height;++row)
            std::copy_n(reference.data()+size_t(row)*width,width,owned->data()+size_t(height-row-1)*width);
        borrowed.begin(width,height);
        require(borrowed.borrow(owned->data()+size_t(height-1)*width,-ptrdiff_t(width)*4,owned));
        require(borrowed.read_data()==owned->data() && borrowed.read_bottom_up());
        require(std::equal(reference.begin(),reference.end(),borrowed.data()));
        require(!borrowed.read_bottom_up());
    }
    std::cout << "Steam overlay full RGBA / strips / tiles / negative pitch / isolation / invalid frame PASS\n";
}
