#define NOMINMAX
#include "../src/ModLoader/DisplayFilter.hpp"
#include <cstdio>
#include <stdexcept>
#include <vector>
#include <chrono>
using namespace rm_modloader;
static void check(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }
struct Dib {
    HDC dc = CreateCompatibleDC(nullptr);
    HBITMAP bitmap = nullptr; HGDIOBJ previous = nullptr;
    Dib(int width, int height) {
        BITMAPINFO info = {}; info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
        info.bmiHeader.biWidth=width; info.bmiHeader.biHeight=-height;
        info.bmiHeader.biPlanes=1; info.bmiHeader.biBitCount=32;
        void* data = nullptr;
        bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&data,nullptr,0);
        check(dc && bitmap,"DIB allocation"); previous=SelectObject(dc,bitmap);
    }
    ~Dib() { SelectObject(dc,previous); DeleteObject(bitmap); DeleteDC(dc); }
};
static void pattern(HDC dc) {
    for (int y=0;y<40;++y) for (int x=0;x<40;++x)
        SetPixel(dc,x,y,((x+y)&1) ? RGB(255,255,255) : RGB(0,0,0));
}
static int intermediate(HDC dc) {
    int count=0;
    for (int y=0;y<27;++y) for (int x=0;x<27;++x) {
        const COLORREF c=GetPixel(dc,x,y);
        check(c!=CLR_INVALID,"Read output");
        if (c!=RGB(0,0,0) && c!=RGB(255,255,255)) ++count;
    }
    return count;
}
int main() {
    IDirectDraw* dd=nullptr; IDirectDrawSurface *from=nullptr,*to=nullptr;
    HWND window=nullptr;
    try {
        Dib src(40,40),dst(60,60); pattern(src.dc);
        RECT input={0,0,40,40}, output={0,0,27,27};
        SetStretchBltMode(dst.dc,BLACKONWHITE); SetBrushOrgEx(dst.dc,7,9,nullptr);
        check(stretch_display(dst.dc,output,src.dc,input,SRCCOPY,false),"GDI pixelated");
        check(intermediate(dst.dc)==0,"Pixelated introduces colors");
        check(stretch_display(dst.dc,output,src.dc,input,SRCCOPY,true),"GDI smooth");
        const int smooth_colors=intermediate(dst.dc);
        check(smooth_colors>0,"Smooth did not filter checkerboard");
        POINT brush; GetBrushOrgEx(dst.dc,&brush);
        check(GetStretchBltMode(dst.dc)==BLACKONWHITE && brush.x==7 && brush.y==9,"Caller DC state changed");
        output={0,0,60,60};
        check(stretch_display(dst.dc,output,src.dc,input,SRCCOPY,true),"GDI fractional enlargement");
        check(intermediate(dst.dc)>0,"Smooth enlargement did not interpolate");
        window=CreateWindowExW(0,L"STATIC",L"DisplayFilterTest",WS_POPUP,0,0,64,64,nullptr,nullptr,GetModuleHandleW(nullptr),nullptr);
        check(window!=nullptr,"Hidden window");
        check(SUCCEEDED(DirectDrawCreate(nullptr,&dd,nullptr)),"DirectDrawCreate");
        check(SUCCEEDED(dd->SetCooperativeLevel(window,DDSCL_NORMAL)),"Cooperative level");
        DDSURFACEDESC desc={}; desc.dwSize=sizeof(desc);
        desc.dwFlags=DDSD_CAPS|DDSD_WIDTH|DDSD_HEIGHT|DDSD_PIXELFORMAT;
        desc.dwWidth=40; desc.dwHeight=40;
        desc.ddsCaps.dwCaps=DDSCAPS_OFFSCREENPLAIN|DDSCAPS_SYSTEMMEMORY;
        desc.ddpfPixelFormat.dwSize=sizeof(DDPIXELFORMAT);desc.ddpfPixelFormat.dwFlags=DDPF_RGB;
        desc.ddpfPixelFormat.dwRGBBitCount=32;desc.ddpfPixelFormat.dwRBitMask=0xff0000;
        desc.ddpfPixelFormat.dwGBitMask=0xff00;desc.ddpfPixelFormat.dwBBitMask=0xff;
        check(SUCCEEDED(dd->CreateSurface(&desc,&from,nullptr)),"Source DD surface");
        desc.dwWidth=60;desc.dwHeight=60;
        check(SUCCEEDED(dd->CreateSurface(&desc,&to,nullptr)),"Target DD surface");
        HDC dc;check(SUCCEEDED(from->GetDC(&dc)),"Source DD DC");pattern(dc);from->ReleaseDC(dc);
        output={0,0,27,27};
        check(SUCCEEDED(stretch_display_surface(to,output,from,&input,false)),"DD pixelated");
        check(SUCCEEDED(to->GetDC(&dc)),"Output DD DC");const int dd_pixels=intermediate(dc);to->ReleaseDC(dc);
        check(dd_pixels==0,"DD pixelated introduces colors");
        check(SUCCEEDED(stretch_display_surface(to,output,from,nullptr,true)),"DD smooth full source");
        check(SUCCEEDED(to->GetDC(&dc)),"Smooth DD DC");const int dd_smooth=intermediate(dc);to->ReleaseDC(dc);
        check(dd_smooth>0,"DD smooth did not filter");
        std::printf("GDI mixed=%d DD mixed=%d PASS\n",smooth_colors,dd_smooth);
        Dib large(1400,800),screen(2560,1800);
        RECT render={0,0,1400,800}, monitor={0,0,2560,1800};
        for (bool smooth : {false,true}) for (int run=0;run<3;++run) {
            GdiFlush();const auto begin=std::chrono::steady_clock::now();
            for (int i=0;i<60;++i) check(stretch_display(screen.dc,monitor,large.dc,render,SRCCOPY,smooth),"Benchmark copy");
            GdiFlush();const double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count()/60;
            std::printf("BENCH filter=%s run=%d input=1400x800 output=2560x1800 calls=60 ms_per_call=%.6f\n",smooth?"smooth":"pixelated",run,ms);
        }
    } catch (const std::exception& e) {
        std::fprintf(stderr,"FAIL %s\n",e.what());
        if(to)to->Release();if(from)from->Release();if(dd)dd->Release();if(window)DestroyWindow(window);
        return 1;
    }
    to->Release();from->Release();dd->Release();DestroyWindow(window);return 0;
}
