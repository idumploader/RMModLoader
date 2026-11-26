#include "../src/ModLoader/SteamOverlay/FakeRenderer.cpp"
#include "../src/ModLoader/SteamOverlay/DllResolver.cpp"
#include "../src/ModLoader/SteamOverlay/RendererAbi.hpp"
#include "../src/ModLoader/SteamOverlay/SavedRenderStream.hpp"
#include <iostream>
#include <stdexcept>
#include <vector>
#include <random>
#include <chrono>

// ABI test uses the production resolver/factory, without Steam IPC or graphics.
uint32_t* g_back_pixels=nullptr;
int g_back_w=640,g_back_h=480;
bool g_back_bottom_up=false,g_drew_this_frame=false;
unsigned loads=0;bool texture_cached=false;uint32_t loaded_pixel=0;
void Tex_LoadOrUpdate(uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,const void* pixels) {
    ++loads;texture_cached=true;loaded_pixel=*static_cast<const uint32_t*>(pixels);
}
void Tex_Delete(uint32_t) {}
bool Tex_Has(uint32_t) { return texture_cached; }
unsigned quad_calls=0,rect_calls=0;
void Tex_DrawQuad(uint32_t texture,const OverlayVertex* v) {
    if(texture==17 && v[0].x==1 && v[2].y==5)++quad_calls;
}
void Tex_DrawRect(uint32_t,int,int,int,int,float,float,float,float,uint32_t) { ++rect_calls; }
void Tex_SaveToBMP(const char*,const uint32_t*,int,int) {}
const SteamFns& GetSteamFns() { static SteamFns f;return f; }
ISteamScreenshots* GetSteamScreenshots(const SteamFns&) { return nullptr; }
namespace rm_modloader {
RECT display_output_bounds(HWND) { return {0,0,640,480}; }
void Logger::info(std::string_view s) { std::cout<<s; }
void Logger::warning(std::string_view s) { std::cout<<s; }
void Logger::error(std::string_view s) { std::cerr<<s; }
}
static void require(bool b,const char* s) { if(!b)throw std::runtime_error(s); }
int main(int argc,char** argv) {
    try {
        require(argc==2,"Pass gameoverlayrenderer.dll path");
        HMODULE module=LoadLibraryExA(argv[1],nullptr,DONT_RESOLVE_DLL_REFERENCES);
        require(module!=nullptr,"Steam DLL mapping failed");
        ResolvedRenderer resolved;
        require(ResolveRenderer(resolved),"Production resolver failed");
        SavedRenderStream saved;
        using Rewind=uint32_t (__thiscall*)(SavedRenderStream*);
        auto rewind=reinterpret_cast<Rewind>(resolved.layout.saved_stream_rewind);
        const std::vector<uint32_t> commands={0,71,0,4};
        require(SavedRenderStream::write(&saved,nullptr,commands.data(),16)==16,"Saved frame write failed");
        for(unsigned trial=0;trial<10000;++trial) {
            uint32_t frame[4]{};
            require(SavedRenderStream::available(&saved,nullptr)==16,"Saved frame pending mismatch");
            require(SavedRenderStream::read(&saved,nullptr,frame,16)==16 &&
                std::equal(commands.begin(),commands.end(),frame),"Saved frame replay corruption");
            require(SavedRenderStream::read(&saved,nullptr,frame,4)==0,"Saved frame read overflow");
            rewind(&saved); // real Steam code, no imported functions or IPC
        }
        require(!SavedRenderStream::clear(&saved,nullptr,17),"Wrong saved frame length accepted");
        require(SavedRenderStream::clear(&saved,nullptr,16),"Saved frame reset failed");
        std::vector<uint8_t> large(4097,0x61),copy(4097);
        require(SavedRenderStream::write(&saved,nullptr,large.data(),4097)==4097 &&
            SavedRenderStream::read(&saved,nullptr,copy.data(),4097)==4097 && copy==large,"Saved growth failed");
        saved.reset();
        require(resolved.layout.discovered && resolved.layout.total_slots==31,"Actual Steam vtable not discovered");
        require(resolved.layout.slot_LoadTexture==5 && resolved.layout.slot_DrawTexturedRect==3 &&
                resolved.layout.slot_SetChromePaintSource==6 && resolved.layout.slot_SharedTexA==7 &&
                resolved.layout.slot_SharedTexB==9 && resolved.layout.slot_ScreenSize==12 &&
                resolved.layout.slot_GetHWND==22 && resolved.layout.slot_GetOutputBounds==29 &&
                resolved.layout.slot_GetClassName==30 && resolved.layout.slot_DeleteTexture==13 &&
                resolved.layout.slot_CaptureScreenshot==15,"Mapping differs from independent IDA audit");
        require(resolved.layout.slot_FrameInfo==25,"Frame-info role differs from IDA audit");
        require(resolved.layout.slot_DrawTexturedQuad==4 && resolved.layout.returns_one[20] &&
            resolved.layout.returns_one[23],"Quad/platform mapping differs from IDA");
        require(resolved.layout.slot_RendererKind==21,"Renderer protocol kind not recognized");
        const uint8_t fixture[]={0xff,0x50,0x50,0x89,0x45,0x98,0x8b,0xcb,0x8b,0x03,0x8b,0x40,0x20,0xff,0xd0,0x88,0x45,0xa4};
        require(has_slot8_capability_query(fixture,sizeof(fixture)),"Dump fixture not recognized");
        for(size_t size=0;size<sizeof(fixture);++size)
            require(!has_slot8_capability_query(fixture,size),"Truncated fixture accepted");
        auto different=std::vector<uint8_t>(fixture,fixture+sizeof(fixture));
        different[12]=0x24;
        require(!has_slot8_capability_query(different.data(),different.size()),"Other vtable slot accepted");
        GDIFakeRenderer dev;
        InitGDIFakeRenderer(&dev,resolved.layout,nullptr);
        std::array<uint32_t,25> chrome{};chrome[4]=0xffabcdef;chrome[24]=4;
        ChromePaintBufDesc descriptor{chrome.data(),nullptr,0,0,-1,2,2};
        Handler_SetChromePaintSource(&dev,nullptr,uint32_t(uintptr_t(&descriptor)),17);
        require(loads==1 && loaded_pixel==0xffabcdef && descriptor.state==1 && chrome[24]==20,"Chrome reader acknowledgement failed");
        Handler_SetChromePaintSource(&dev,nullptr,uint32_t(uintptr_t(&descriptor)),17);
        require(loads==1,"Unchanged Chrome frame copied again");
        chrome[8]=0xff123456;chrome[24]=(chrome[24]&~12u)|8;
        Handler_SetChromePaintSource(&dev,nullptr,uint32_t(uintptr_t(&descriptor)),17);
        require(loads==2 && loaded_pixel==0xff123456 && descriptor.state==2 && chrome[24]==40,"New Chrome producer slot not consumed");
        descriptor.state=-1;
        Handler_SetChromePaintSource(&dev,nullptr,uint32_t(uintptr_t(&descriptor)),17);
        require(loads==3,"New Chrome source reused stale cached texture");
        using Kind=uint32_t (__thiscall*)(GDIFakeRenderer*);
        require(reinterpret_cast<Kind>(dev.vtable[resolved.layout.slot_RendererKind])(&dev)==10 &&
            reinterpret_cast<Kind>(dev.vtable[20])(&dev)==1 && reinterpret_cast<Kind>(dev.vtable[23])(&dev)==1,
            "Renderer protocol getters not preserved");
        dev.secondary_stream=&saved;
        const uint32_t rect_command=3,quad_command=34,end_command=4;
        uint32_t rect_packet[13]{};rect_packet[2]=rect_packet[3]=5;rect_packet[9]=0xffffffff;
        struct QuadPacket { OverlayVertex vertices[4];float depth;uint32_t texture; };
        const QuadPacket quad_packet={{{1,1,0,0,0xffffffff},{5,1,1,0,0xffffffff},
            {5,5,1,1,0xffffffff},{1,5,0,1,0xffffffff}},0,17};
        static_assert(sizeof(QuadPacket)==88);
        SavedRenderStream::write(&saved,nullptr,&rect_command,4);
        SavedRenderStream::write(&saved,nullptr,rect_packet,52);
        SavedRenderStream::write(&saved,nullptr,&quad_command,4);
        SavedRenderStream::write(&saved,nullptr,&quad_packet,88);
        SavedRenderStream::write(&saved,nullptr,&end_command,4);
        using Dispatch=bool (__fastcall*)(GDIFakeRenderer*,void*,SavedRenderStream*);
        auto dispatch=reinterpret_cast<Dispatch>(resolved.M_ProcessPaintStream);
        for(int frame=0;frame<1000;++frame)require(dispatch(&dev,nullptr,&saved),"Actual saved-stream dispatcher failed");
        require(rect_calls==1000 && quad_calls==1000,"Actual Steam packet callback mapping failed");
        saved.reset();dev.secondary_stream=nullptr;
        using Query=bool (__thiscall*)(GDIFakeRenderer*);
        const auto query=reinterpret_cast<Query>(dev.vtable[8]);
        DWORD before,after;
        __asm mov before,esp
        for(int i=0;i<10000;++i)require(!query(&dev),"CPU renderer advertised GPU capability");
        __asm mov after,esp
        require(before==after,"Zero-argument call damaged stack");
        using Adapter=uint64_t (__thiscall*)(GDIFakeRenderer*);
        require(reinterpret_cast<Adapter>(dev.vtable[24])(&dev)==0,"Default callback left adapter LUID uninitialized");
        using FrameInfo=void (__thiscall*)(GDIFakeRenderer*,void*);
        std::array<uint8_t,44> info;info.fill(0xff);
        reinterpret_cast<FrameInfo>(dev.vtable[resolved.layout.slot_FrameInfo])(&dev,info.data());
        require(std::all_of(info.begin(),info.end(),[](uint8_t byte){return byte==0;}),"Frame info not initialized");
        using Bounds=void (__thiscall*)(GDIFakeRenderer*,int*,int*,int*,int*);
        using Window=HWND (__thiscall*)(GDIFakeRenderer*);
        int x=-1,y=-1,w=-1,h=-1;
        auto bounds=reinterpret_cast<Bounds>(dev.vtable[resolved.layout.slot_GetOutputBounds]);
        __asm mov before,esp
        bounds(&dev,&x,&y,&w,&h);
        __asm mov after,esp
        require(before==after && x==0 && y==0 && w==640 && h==480,"Discovered bounds ABI failed");
        delete dev.shared_tex_obj_98;dev.shared_tex_obj_98=nullptr;

        auto* table=reinterpret_cast<uint32_t*>(resolved.layout.source_vtable);
        const std::vector<uint32_t> original(table,table+resolved.layout.total_slots);
        DWORD protection;
        require(VirtualProtect(table,original.size()*4,PAGE_READWRITE,&protection)!=0,"Fixture vtable not writable");
        struct Restore {
            uint32_t* table;const std::vector<uint32_t>& original;DWORD protection;
            ~Restore(){std::copy(original.begin(),original.end(),table);DWORD ignored;VirtualProtect(table,original.size()*4,protection,&ignored);}
        } restore{table,original,protection};
        std::mt19937 random(714);
        const auto started=std::chrono::steady_clock::now();
        for(unsigned trial=0;trial<32;++trial) {
            auto shuffled=original;std::shuffle(shuffled.begin(),shuffled.end(),random);
            std::copy(shuffled.begin(),shuffled.end(),table);
            VtableLayout layout;std::string error;
            require(discover_renderer_layout(module,layout,error),error.c_str());
            auto moved=[&](int old_slot,int new_slot){return shuffled[new_slot]==original[old_slot];};
            require(moved(resolved.layout.slot_DrawTexturedRect,layout.slot_DrawTexturedRect) &&
                    moved(resolved.layout.slot_LoadTexture,layout.slot_LoadTexture) &&
                    moved(resolved.layout.slot_SharedTexA,layout.slot_SharedTexA) &&
                    moved(resolved.layout.slot_SharedTexB,layout.slot_SharedTexB) &&
                    moved(resolved.layout.slot_ScreenSize,layout.slot_ScreenSize) &&
                    moved(resolved.layout.slot_CaptureScreenshot,layout.slot_CaptureScreenshot) &&
                    moved(resolved.layout.slot_DeleteTexture,layout.slot_DeleteTexture) &&
                    moved(resolved.layout.slot_GetClassName,layout.slot_GetClassName) &&
                    moved(resolved.layout.slot_FrameInfo,layout.slot_FrameInfo) &&
                    moved(resolved.layout.slot_DrawTexturedQuad,layout.slot_DrawTexturedQuad) &&
                    moved(resolved.layout.slot_RendererKind,layout.slot_RendererKind) &&
                    moved(resolved.layout.slot_GetHWND,layout.slot_GetHWND) &&
                    moved(resolved.layout.slot_GetOutputBounds,layout.slot_GetOutputBounds) &&
                    moved(resolved.layout.slot_SetChromePaintSource,layout.slot_SetChromePaintSource),"Shuffled role mapping failed");
            InitGDIFakeRenderer(&dev,layout,reinterpret_cast<HWND>(0x12345));
            auto get_window=reinterpret_cast<Window>(dev.vtable[layout.slot_GetHWND]);
            require(get_window(&dev)==reinterpret_cast<HWND>(0x12345),"Shuffled HWND binding failed");
            bounds=reinterpret_cast<Bounds>(dev.vtable[layout.slot_GetOutputBounds]);
            __asm mov before,esp
            bounds(&dev,&x,&y,&w,&h);
            __asm mov after,esp
            require(before==after && w==640 && h==480,"Shuffled bounds binding failed");
            delete dev.shared_tex_obj_98;dev.shared_tex_obj_98=nullptr;
        }
        std::copy(original.begin(),original.end(),table);
        table[resolved.layout.slot_LoadTexture]=table[resolved.layout.slot_DrawTexturedRect];
        VtableLayout rejected;std::string error;
        require(!discover_renderer_layout(module,rejected,error),"Ambiguous/missing method did not disable overlay");
        ResolvedRenderer failed;
        require(!ResolveRenderer(failed),"Production initialization accepted ambiguous ABI");
        std::copy(original.begin(),original.end(),table);
        const auto ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-started).count()/33;
        std::cout<<"Discovery mean "<<ms<<" ms (32 permutations + rejection), no frame-loop decoding\n";
        InitGDIFakeRenderer(&dev,kLayout_2026_05,nullptr,false);
        char owns=1;
        __asm mov before,esp
        Handler_SharedTexB(&dev,nullptr,0,0,0,0,0,0,0,0,0,0,0,nullptr,0,0,0,0,&owns);
        __asm mov after,esp
        require(before==after && owns==0,"Legacy 17-argument ABI changed");
        delete dev.shared_tex_obj_98;
        // Restore owns mapped table memory until function exit.
        std::cout<<"PASS actual Steam resolver / 32 real-vtable permutations / bounds + HWND / fail-closed rejection / 10000 zero-arg calls / legacy stack cleanup / 10000 native saved rewinds / 1000 actual Steam rect+quad dispatcher replays\n";
        return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<'\n';return 1; }
}
