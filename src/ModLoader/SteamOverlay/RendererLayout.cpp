#include "RendererLayout.hpp"
#include "hde/hde32.h"
#include <cstring>
#include <algorithm>
#include <unordered_set>
#include <stdexcept>

namespace {
struct Range {
    uintptr_t begin=0,end=0;
    bool has(uintptr_t p,size_t n=1) const { return p>=begin && p<=end && n<=end-p; }
};
struct Image {
    uintptr_t base;
    Range text,data,whole;
    explicit Image(HMODULE module):base(reinterpret_cast<uintptr_t>(module)) {
        const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        if(dos->e_magic!=IMAGE_DOS_SIGNATURE)throw std::runtime_error("Not a PE image");
        const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS32*>(base+dos->e_lfanew);
        if(nt->Signature!=IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR32_MAGIC)
            throw std::runtime_error("Expected PE32 renderer");
        whole={base,base+nt->OptionalHeader.SizeOfImage};
        const auto* sections=IMAGE_FIRST_SECTION(nt);
        for(unsigned i=0;i<nt->FileHeader.NumberOfSections;++i) {
            Range r{base+sections[i].VirtualAddress,base+sections[i].VirtualAddress+sections[i].Misc.VirtualSize};
            if(!whole.has(r.begin,r.end-r.begin))throw std::runtime_error("Invalid section range");
            if(!std::memcmp(sections[i].Name,".text",5))text=r;
            if(!std::memcmp(sections[i].Name,".rdata",6))data=r;
        }
        if(!text.begin || !data.begin)throw std::runtime_error("Missing code/data sections");
    }
    uintptr_t import_slot(const char* name) const {
        const auto* dos=reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
        const auto* nt=reinterpret_cast<const IMAGE_NT_HEADERS32*>(base+dos->e_lfanew);
        auto addr=base+nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
        for(unsigned d=0;d<256 && whole.has(addr,sizeof(IMAGE_IMPORT_DESCRIPTOR));++d,addr+=sizeof(IMAGE_IMPORT_DESCRIPTOR)) {
            const auto* desc=reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(addr);
            if(!desc->Name)break;
            if(!desc->OriginalFirstThunk)continue;
            for(unsigned i=0;i<4096;++i) {
                const auto a=base+desc->OriginalFirstThunk+i*4;
                if(!whole.has(a,4))break;
                const auto value=*reinterpret_cast<const uint32_t*>(a);
                if(!value)break;
                if(IMAGE_SNAP_BY_ORDINAL32(value))continue;
                const auto n=base+value+2;
                const size_t length=std::strlen(name)+1;
                if(whole.has(n,length) && !std::memcmp(reinterpret_cast<const void*>(n),name,length))
                    return base+desc->FirstThunk+i*4;
            }
        }
        // OpenGL is delay-loaded by Steam, so its named thunks are in the
        // delay-import directory rather than the ordinary import descriptors.
        auto delay=base+nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].VirtualAddress;
        for(unsigned d=0;d<256 && whole.has(delay,32);++d,delay+=32) {
            const auto* fields=reinterpret_cast<const uint32_t*>(delay);
            if(!fields[1])break;
            auto address=[&](uint32_t value){return fields[0]&1?base+value:uintptr_t(value);};
            const auto names=address(fields[4]),iat=address(fields[3]);
            for(unsigned i=0;i<4096 && whole.has(names+i*4,4);++i) {
                const auto value=*reinterpret_cast<const uint32_t*>(names+i*4);
                if(!value)break;
                if(IMAGE_SNAP_BY_ORDINAL32(value))continue;
                const auto n=address(value)+2;
                const auto length=std::strlen(name)+1;
                if(whole.has(n,length) && !std::memcmp(reinterpret_cast<const void*>(n),name,length))return iat+i*4;
            }
        }
        return 0;
    }
};

RendererMethodInfo analyze(const Image& image,uintptr_t entry,uintptr_t name_getter) {
    RendererMethodInfo result;result.address=entry;result.class_name=entry==name_getter;
    const uint8_t one[]={0xb8,1,0,0,0,0xc3};
    result.returns_one=image.text.has(entry,sizeof(one)) && !std::memcmp(reinterpret_cast<const void*>(entry),one,sizeof(one));
    const uint8_t kind[]={0x33,0xd2,0xb8,10,0,0,0,0x38,0x91,0x30,1,0,0,0x0f,0x45,0xc2,0xc3};
    result.renderer_kind=image.text.has(entry,sizeof(kind)) && !std::memcmp(reinterpret_cast<const void*>(entry),kind,sizeof(kind));
    const auto del=image.import_slot("glDeleteTextures"), wnd=image.import_slot("WindowFromDC");
    const auto rect=image.import_slot("GetClientRect"), screen=image.import_slot("ClientToScreen");
    const auto gl_error=image.import_slot("glGetError");
    std::vector<uintptr_t> pending{entry};std::unordered_set<uintptr_t> visited;
    int cleanup=-1;bool calls=false;size_t count=0;
    auto decode=[&](uintptr_t p,hde32s& h) {
        if(!image.text.has(p))throw std::runtime_error("Branch outside executable section");
        uint8_t safe[16]{};
        std::memcpy(safe,reinterpret_cast<const void*>(p),std::min<size_t>(15,image.text.end-p));
        hde32_disasm(safe,&h);
        if(!h.len || (h.flags&F_ERROR) || !image.text.has(p,h.len))throw std::runtime_error("Unsupported x86 instruction");
    };
    while(!pending.empty()) {
        auto p=pending.back();pending.pop_back();
        while(visited.insert(p).second) {
            if(++count>12000)throw std::runtime_error("Method analysis budget exceeded");
            hde32s h{};decode(p,h);const auto next=p+h.len;
            if(h.opcode==0xc3 || h.opcode==0xc2) {
                const int bytes=h.opcode==0xc3?0:h.imm.imm16;
                if(cleanup!=-1 && cleanup!=bytes)throw std::runtime_error("Inconsistent stack cleanup");
                cleanup=bytes;break;
            }
            if(h.opcode==0xcc || (h.opcode==0xcd && h.imm.imm8==0x29) || (h.opcode==0x0f && h.opcode2==0x0b))break;
            if(h.opcode==0xe8 || (h.opcode==0xff && h.modrm_reg==2)) {
                calls=true;
                if(h.opcode==0xe8 && p>=image.text.begin+5) {
                    const auto* setup=reinterpret_cast<const uint8_t*>(p-5);
                    result.frame_info|=setup[0]==0x6a && setup[1]==44 && setup[2]==0x6a && setup[3]==0 && setup[4]>=0x50 && setup[4]<=0x57;
                }
                uintptr_t import=0;
                if(h.opcode==0xff && h.modrm==0x15)import=h.disp.disp32;
                if(h.opcode==0xe8) {
                    const auto target=next+static_cast<int32_t>(h.imm.imm32);
                    if(image.text.has(target,6) && *reinterpret_cast<const uint16_t*>(target)==0x25ff)
                        import=*reinterpret_cast<const uint32_t*>(target+2);
                }
                result.deletes_texture|=del && import==del;
                result.gets_hwnd|=wnd && import==wnd;
                result.output_bounds|=(rect && import==rect)||(screen && import==screen);
            }
            result.chrome_sync|=h.opcode==0x0f && h.opcode2==0xb1 && h.p_lock;
            if(h.opcode==0xe9 || h.opcode==0xeb || (h.opcode>=0x70 && h.opcode<=0x7f) || (h.opcode==0x0f && h.opcode2>=0x80 && h.opcode2<=0x8f)) {
                const intptr_t displacement=h.flags&F_IMM8?static_cast<int8_t>(h.imm.imm8):static_cast<int32_t>(h.imm.imm32);
                pending.push_back(next+displacement);
                if(h.opcode==0xe9 || h.opcode==0xeb)break;
            }
            if(h.opcode==0xff && h.modrm_reg==4) {
                if(h.modrm==0x25 && gl_error && h.disp.disp32==gl_error) {
                    if(cleanup!=-1 && cleanup!=0)throw std::runtime_error("Inconsistent imported tail cleanup");
                    cleanup=0;break; // proven zero-argument stdcall tail
                }
                // Bounded switch table; unresolved indirect tails fail closed.
                if(!(h.flags&F_SIB) || h.sib_scale!=2 || h.sib_base!=5 || !image.data.has(h.disp.disp32,4))
                    throw std::runtime_error("Unresolved indirect branch");
                unsigned added=0;
                for(unsigned i=0;i<128 && image.data.has(h.disp.disp32+i*4,4);++i) {
                    const auto target=*reinterpret_cast<const uint32_t*>(h.disp.disp32+i*4);
                    if(!image.text.has(target))break;
                    pending.push_back(target);++added;
                }
                if(!added)throw std::runtime_error("Empty switch table");
                break;
            }
            p=next;
        }
    }
    if(cleanup<0 || cleanup>68 || cleanup%4)throw std::runtime_error("Unknown method calling convention");
    result.argument_bytes=cleanup;
    result.short_getter=!calls && count<=20 && cleanup==8;
    return result;
}
}

bool classify_renderer_methods(const std::vector<RendererMethodInfo>& methods,VtableLayout& layout,std::string& error) {
    try {
        if(methods.size()<16 || methods.size()>64)throw std::runtime_error("Invalid vtable size");
        VtableLayout found{};found.total_slots=static_cast<int>(methods.size());found.discovered=true;
        found.slot_dtor=found.slot_FrameStart=found.slot_PostFrame=found.slot_ScreenshotComplete=found.slot_RetFour=-1;
        auto unique=[&](auto predicate,const char* role) {
            int index=-1;
            for(size_t i=0;i<methods.size();++i)if(predicate(methods[i])) {
                if(index!=-1)throw std::runtime_error(std::string("Ambiguous role: ")+role);
                index=static_cast<int>(i);
            }
            if(index<0)throw std::runtime_error(std::string("Missing role: ")+role);
            return index;
        };
        found.slot_DrawTexturedRect=unique([](auto& m){return m.argument_bytes==52;},"DrawTexturedRect");
        found.slot_LoadTexture=unique([](auto& m){return m.argument_bytes==44;},"LoadTexture");
        found.slot_SharedTexA=unique([](auto& m){return m.argument_bytes==60;},"SharedTextureA");
        found.slot_SharedTexB=unique([](auto& m){return m.argument_bytes==68;},"SharedTextureB");
        found.slot_ScreenSize=unique([](auto& m){return m.argument_bytes==8 && m.short_getter;},"ScreenSize");
        found.slot_SetChromePaintSource=unique([](auto& m){return m.argument_bytes==8 && m.chrome_sync;},"ChromePaintSource");
        found.slot_CaptureScreenshot=unique([](auto& m){return m.argument_bytes==8 && !m.short_getter && !m.chrome_sync;},"CaptureScreenshot");
        found.slot_DeleteTexture=unique([](auto& m){return m.argument_bytes==4 && m.deletes_texture;},"DeleteTexture");
        found.slot_GetHWND=unique([](auto& m){return m.argument_bytes==0 && m.gets_hwnd;},"GetHWND");
        found.slot_GetOutputBounds=unique([](auto& m){return m.argument_bytes==16 && m.output_bounds;},"OutputBounds");
        found.slot_GetClassName=unique([](auto& m){return m.argument_bytes==0 && m.class_name;},"ClassName");
        found.slot_FrameInfo=unique([](auto& m){return m.argument_bytes==4 && m.frame_info;},"FrameInfo");
        found.slot_DrawTexturedQuad=unique([](auto& m){return m.argument_bytes==12;},"DrawTexturedQuad");
        found.slot_RendererKind=unique([](auto& m){return m.argument_bytes==0 && m.renderer_kind;},"RendererKind");
        for(size_t i=0;i<methods.size();++i) {
            if(methods[i].argument_bytes>68 || methods[i].argument_bytes%4)throw std::runtime_error("Invalid argument size");
            found.argument_bytes[i]=static_cast<uint8_t>(methods[i].argument_bytes);
            found.returns_one[i]=methods[i].returns_one;
        }
        layout=found;error.clear();return true;
    } catch(const std::exception& e) { error=e.what();return false; }
}

bool discover_renderer_layout(HMODULE module,VtableLayout& layout,std::string& error) {
    try {
        Image image(module);
        const char name[]="COverlayGLRenderer";
        uintptr_t string=0,getter=0,reference=0;
        for(auto p=image.data.begin;p+sizeof(name)<=image.data.end;++p)
            if(!std::memcmp(reinterpret_cast<const void*>(p),name,sizeof(name))) { if(string)throw std::runtime_error("Ambiguous renderer name");string=p; }
        if(!string)throw std::runtime_error("GL renderer name not found");
        for(auto p=image.text.begin;p+6<=image.text.end;++p)
            if(*reinterpret_cast<const uint8_t*>(p)==0xb8 && *reinterpret_cast<const uint32_t*>(p+1)==string && *reinterpret_cast<const uint8_t*>(p+5)==0xc3) {
                if(getter)throw std::runtime_error("Ambiguous class-name getter");getter=p;
            }
        if(!getter)throw std::runtime_error("Class-name getter not recognized");
        for(auto p=image.data.begin;p+4<=image.data.end;p+=4)
            if(*reinterpret_cast<const uint32_t*>(p)==getter) { if(reference)throw std::runtime_error("Ambiguous class-name slot");reference=p; }
        if(!reference)throw std::runtime_error("Renderer vtable not found");
        auto first=reference,last=reference+4;
        while(first>=image.data.begin+4 && image.text.has(*reinterpret_cast<const uint32_t*>(first-4)))first-=4;
        while(image.data.has(last,4) && image.text.has(*reinterpret_cast<const uint32_t*>(last)))last+=4;
        if((last-first)/4>64)throw std::runtime_error("Vtable exceeds slot budget");
        std::vector<RendererMethodInfo> methods;
        for(auto p=first;p<last;p+=4) {
            const auto address=*reinterpret_cast<const uint32_t*>(p);
            try { methods.push_back(analyze(image,address,getter)); }
            catch(const std::exception& e) { throw std::runtime_error("Slot "+std::to_string(methods.size())+": "+e.what()); }
        }
        if(!classify_renderer_methods(methods,layout,error))return false;
        layout.source_vtable=first;
        // The dispatcher calls this non-virtual method on the saved stream.
        // Reject a changed field layout before exposing our local replay buffer.
        const uint8_t rewind[]={0x8b,0x41,0x14,0xc7,0x41,0x0c,0,0,0,0,0x89,0x41,0x18,0xc3};
        uintptr_t rewind_address=0;
        for(auto p=image.text.begin;p+sizeof(rewind)<=image.text.end;++p)
            if(!std::memcmp(reinterpret_cast<const void*>(p),rewind,sizeof(rewind))) {
                if(rewind_address)throw std::runtime_error("Ambiguous saved-stream rewind");rewind_address=p;
            }
        if(!rewind_address)throw std::runtime_error("Saved-stream field layout changed");
        layout.saved_stream_rewind=rewind_address;
        return true;
    } catch(const std::exception& e) { error=e.what();return false; }
}
