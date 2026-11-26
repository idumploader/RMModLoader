#pragma once
#include <cstdint>
#include <cstddef>
#include <cstring>
#include <vector>
#include <algorithm>

// CSavedMemStream ABI, verified against the dispatcher's direct rewind:
// read_cursor=0; pending=length. This is a local replay buffer, not IPC.
struct SavedRenderStream {
    void** vtable;
    uint32_t capacity=0;
    uint8_t* data=nullptr;
    uint32_t read_cursor=0,write_cursor=0,length=0,pending=0;
    std::vector<uint8_t> storage;
    static void __fastcall destroy(SavedRenderStream* s,void*,uint32_t) { s->reset(); }
    static uint32_t __fastcall available(SavedRenderStream* s,void*) { return s->pending; }
    static uint32_t __fastcall room(SavedRenderStream*,void*) { return 0x7fffffff; }
    static uint32_t __fastcall write(SavedRenderStream* s,void*,const void* data,uint32_t size) {
        constexpr uint32_t limit=128*1024*1024;
        if(size>limit-s->length || (!data && size))return 0;
        const auto needed=s->length+size;
        try {
            if(needed>s->capacity) {
                s->storage.resize((std::max)(needed,(std::min)(limit,(std::max)(256u,s->capacity*2))));
                s->capacity=static_cast<uint32_t>(s->storage.size());s->data=s->storage.data();
            }
        } catch(...) { return 0; }
        if(size)std::memcpy(s->data+s->write_cursor,data,size);
        s->write_cursor+=size;s->length+=size;s->pending+=size;
        return size;
    }
    static uint32_t __fastcall read(SavedRenderStream* s,void*,void* out,uint32_t size) {
        if(size>s->pending || (!out && size))return 0;
        if(size)std::memcpy(out,s->data+s->read_cursor,size);
        s->read_cursor+=size;s->pending-=size;return size;
    }
    static bool __fastcall clear(SavedRenderStream* s,void*,uint32_t expected) {
        if(expected && expected!=s->length)return false;
        s->read_cursor=s->write_cursor=s->length=s->pending=0;return true;
    }
    static bool __fastcall wait(SavedRenderStream* s,void*,uint32_t,uint32_t) { return s->pending!=0; }
    SavedRenderStream() {
        static void* table[]={reinterpret_cast<void*>(&destroy),reinterpret_cast<void*>(&available),
            reinterpret_cast<void*>(&room),reinterpret_cast<void*>(&write),reinterpret_cast<void*>(&read),
            reinterpret_cast<void*>(&clear),reinterpret_cast<void*>(&wait)};
        vtable=table;
    }
    void reset() { clear(this,nullptr,0);std::vector<uint8_t>().swap(storage);capacity=0;data=nullptr; }
};
static_assert(offsetof(SavedRenderStream,read_cursor)==12);
static_assert(offsetof(SavedRenderStream,length)==20);
static_assert(offsetof(SavedRenderStream,pending)==24);
