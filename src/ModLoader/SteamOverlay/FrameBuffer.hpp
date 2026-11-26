#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <vector>
#include <memory>

namespace rm_modloader::steam_overlay {
// Retain immutable completed frames for reads; materialize before Steam paints.
// Reusable native strips always need a private composition copy.
class FrameBuffer {
    std::vector<uint32_t> pixels_;
    int width_=0, height_=0, next_x_=0, next_y_=0, band_height_=0;
    bool valid_=false;
    const uint32_t* borrowed_=nullptr;
    ptrdiff_t borrowed_pitch_=0;
    std::shared_ptr<void> source_owner_;
public:
    void clear() noexcept {
        borrowed_=nullptr; source_owner_.reset();
        std::vector<uint32_t>().swap(pixels_);
        width_=height_=next_x_=next_y_=band_height_=0;
        valid_=false;
    }
    void begin(int width,int height) {
        borrowed_=nullptr; source_owner_.reset();
        valid_=false;
        if (width<=0 || height<=0 || size_t(width)>pixels_.max_size()/size_t(height))
            throw std::length_error("Invalid Steam overlay frame size");
        const auto count=size_t(width)*size_t(height);
        if (pixels_.size()!=count) {
            std::vector<uint32_t> replacement(count);
            pixels_.swap(replacement);
        }
        width_=width; height_=height;
        next_x_=next_y_=band_height_=0;
        valid_=true;
    }
    // Source is its logical top row; signed pitch handles RGSS DIB orientation.
    bool append(int left,int top,int width,int height,const void* source,ptrdiff_t pitch) noexcept {
        if (!valid_) return false;
        if (!source || width<=0 || height<=0 || left!=next_x_ || top!=next_y_ ||
            left<0 || top<0 || left>width_-width || top>height_-height ||
            (pitch>-ptrdiff_t(width)*4 && pitch<ptrdiff_t(width)*4) ||
            (band_height_ && height!=band_height_)) {
            valid_=false;
            return false;
        }
        auto* input=static_cast<const unsigned char*>(source);
        for (int row=0;row<height;++row)
            std::memcpy(pixels_.data()+size_t(top+row)*width_+left,
                        input+ptrdiff_t(row)*pitch,size_t(width)*4);
        band_height_=height;
        next_x_+=width;
        if (next_x_==width_) { next_x_=0; next_y_+=band_height_; band_height_=0; }
        return true;
    }
    bool complete() const noexcept { return valid_ && next_x_==0 && next_y_==height_; }
    bool borrow(const void* source,ptrdiff_t pitch,std::shared_ptr<void> owner) noexcept {
        if (!valid_ || next_x_ || next_y_ || !source || !owner ||
            (pitch!=ptrdiff_t(width_)*4 && pitch!=-ptrdiff_t(width_)*4)) return false;
        borrowed_=static_cast<const uint32_t*>(source);source_owner_=std::move(owner);
        borrowed_pitch_=pitch;
        next_y_=height_;
        return true;
    }
    bool borrowed() const noexcept { return borrowed_!=nullptr; }
    bool read_bottom_up() const noexcept { return borrowed_ && borrowed_pitch_<0; }
    const uint32_t* read_data() const noexcept {
        return borrowed_ ? (borrowed_pitch_<0 ? borrowed_-size_t(height_-1)*width_ : borrowed_) : pixels_.data();
    }
    uint32_t* data() noexcept {
        if (borrowed_) {
            for (int row=0;row<height_;++row)
                std::memcpy(pixels_.data()+size_t(row)*width_,
                    reinterpret_cast<const unsigned char*>(borrowed_)+ptrdiff_t(row)*borrowed_pitch_,size_t(width_)*4);
            borrowed_=nullptr;source_owner_.reset();
        }
        return pixels_.data();
    }
};
}
