#define main old_overlay_raster_main
#include "steam_overlay_raster_test.cpp"
#undef main
int main() {
    using namespace rm_modloader::renderer;
    test_threads=1;Tex_SetParallel(false);
    std::vector<uint32_t> texture(4*4);
    for(int i=0;i<16;++i)texture[i]=0x80000000u|uint32_t(i*0x0a0503);
    Tex_LoadOrUpdate(17,0,0,4,4,texture.data());
    g_back_w=g_back_h=16;
    unsigned checks=0;
    for(bool bottom:{false,true})for(uint32_t color:{0u,0xffffffffu,0x80808080u}) {
        g_back_bottom_up=bottom;
        std::vector<uint32_t> expected(256,0xff345678),actual=expected;
        g_back_pixels=expected.data();reference_draw(17,-2,3,12,10,-.25f,1.2f,1.25f,-.2f,color);
        const OverlayVertex vertices[]={{-2,3,-.25f,1.2f,color},{10,3,1.25f,1.2f,color},
            {10,13,1.25f,-.2f,color},{-2,13,-.25f,-.2f,color}};
        g_back_pixels=actual.data();Tex_DrawQuad(17,vertices);
        require(actual==expected);++checks;
    }
    for(bool bottom:{false,true})for(bool reverse:{false,true}) {
        g_back_bottom_up=bottom;
        std::vector<uint32_t> actual(256,0xff000000);
        OverlayVertex vertices[]={{.25f,.25f,0,0,0x80ffffff},{4.25f,.25f,1,0,0x80ffffff},
            {4.25f,4.25f,1,1,0x80ffffff},{.25f,4.25f,0,1,0x80ffffff}};
        if(reverse)std::swap(vertices[1],vertices[3]);
        g_back_pixels=actual.data();Tex_DrawQuad(999,vertices);
        for(int y=0;y<16;++y)for(int x=0;x<16;++x)
            require(actual[(bottom?15-y:y)*16+x]==(x<4 && y<4?0xff808080u:0xff000000u));
        ++checks; // no double alpha blend along shared diagonal
        unsigned copies=0;
        Tex_SetWriteCallback(+[](void* p) noexcept -> uint32_t* { ++*static_cast<unsigned*>(p);return g_back_pixels; },&copies);
        for(auto& vertex:vertices)vertex.color=0;
        Tex_DrawQuad(999,vertices);require(copies==0);
        for(auto& vertex:vertices)vertex.color=0xffffffff;
        Tex_DrawQuad(999,vertices);Tex_DrawQuad(999,vertices);require(copies==1);
        Tex_SetWriteCallback(nullptr,nullptr);++checks;
    }
    OverlayVertex gradient[]={{.25f,.25f,0,0,0xff000000},{4.25f,.25f,1,0,0xffff0000},
        {4.25f,4.25f,1,1,0xffff0000},{.25f,4.25f,0,1,0xff000000}};
    std::vector<uint32_t> actual(256,0xff000000);g_back_pixels=actual.data();g_back_bottom_up=false;
    Tex_DrawQuad(999,gradient);
    for(int y=0;y<4;++y)for(int x=0;x<4;++x)
        require(actual[y*16+x]==(0xff000000u|uint32_t(int((x+.25f)*255/4+.5f))<<16));
    ++checks;Tex_Delete(17);
    std::cout<<"Quad pixel checks="<<checks<<" PASS: rectangle reference, fractional coordinates, both windings/orientations, diagonal alpha, gradient, COW\n";
}
