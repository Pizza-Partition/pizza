#include "renderer.hpp"
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
using Clock=std::chrono::steady_clock;
struct Options {
    int width=1440,height=1000,frames=240;
    unsigned threads=std::min(4u,std::max(1u,std::thread::hardware_concurrency()));
    double time=0;
    bool paused=false,benchmark=false,smoke=false,help=false,ingredients=false,toppingsDetail=false;
    std::string render,dump,report,assets;
};
Options options(int argc,char** argv) {
    Options o;
    for(int i=1;i<argc;++i) {
        std::string arg=argv[i];
        auto value=[&]() -> std::string { if(++i>=argc) throw std::runtime_error("Missing value for "+arg); return argv[i]; };
        if(arg=="--width") o.width=std::stoi(value()); else if(arg=="--height") o.height=std::stoi(value());
        else if(arg=="--frames") o.frames=std::stoi(value()); else if(arg=="--threads") o.threads=unsigned(std::stoi(value()));
        else if(arg=="--time") o.time=std::stod(value()); else if(arg=="--render") o.render=value();
        else if(arg=="--dump-timeline") o.dump=value(); else if(arg=="--report") o.report=value();
        else if(arg=="--assets") o.assets=value(); else if(arg=="--paused") o.paused=true;
        else if(arg=="--ingredients") o.ingredients=true;
        else if(arg=="--toppings-detail") o.toppingsDetail=true;
        else if(arg=="--benchmark") o.benchmark=true; else if(arg=="--smoke-test") o.smoke=true;
        else if(arg=="--help" || arg=="-h") o.help=true; else throw std::runtime_error("Unknown option: "+arg);
    }
    if(o.width<320 || o.height<480 || o.width>7680 || o.height>4320) throw std::runtime_error("Image size must be within 320..7680 x 480..4320");
    if(o.threads>32 || o.frames<1 || o.frames>100000 || !std::isfinite(o.time)) throw std::runtime_error("Invalid threads, frames or time");
    return o;
}
void parentDirectory(const std::filesystem::path& path) {
    if(!path.parent_path().empty()) std::filesystem::create_directories(path.parent_path());
}
std::filesystem::path assets(const Options& o,const char* executable) {
    if(!o.assets.empty()) return std::filesystem::absolute(o.assets);
    std::vector<std::filesystem::path> roots;
    if(const char* base=SDL_GetBasePath()) roots.emplace_back(base);
    roots.push_back(std::filesystem::absolute(executable).parent_path());
    roots.push_back(std::filesystem::current_path());
    for(const auto& root:roots) if(std::filesystem::exists(root/"assets/fonts/DMSans.ttf")) return root/"assets";
    throw std::runtime_error("Cannot locate assets/fonts; use --assets PATH or run xmake to copy the assets");
}
void dumpTimeline(const std::string& path) {
    parentDirectory(path); std::ofstream out(path); if(!out) throw std::runtime_error("Cannot write timeline dump");
    out<<std::setprecision(17);
    for(int i=0;i<=3480;++i) {
        double t=i*.01; auto f=otto::frameAt(t);
        out<<t<<','<<f.index<<','<<f.local<<','<<f.reveal<<','<<f.lift<<','<<f.rotation<<','<<f.unfolded<<','<<f.offset<<','<<f.wheelOpacity<<','<<f.wheelPosition<<','<<f.completed<<','<<f.phase<<'\n';
    }
    if(!out) throw std::runtime_error("Timeline dump write failed");
}
void benchmark(otto::Renderer& renderer,const Options& o,double startupMs) {
    otto::Playback playback; playback.playing=false;
    // Warm up Blend2D pipelines and shaped glyphs before timing steady-state work.
    for(int i=0;i<40;++i) { playback.seek(otto::duration*i/39); renderer.draw(playback); }
    std::vector<double> times; times.reserve(o.frames);
    for(int i=0;i<o.frames;++i) {
        playback.seek(otto::duration*(i+.5)/o.frames); renderer.draw(playback); times.push_back(renderer.renderMilliseconds());
    }
    double mean=std::accumulate(times.begin(),times.end(),0.)/times.size(); std::sort(times.begin(),times.end());
    auto percentile=[&](double p) { return times[std::min(times.size()-1,size_t(std::ceil(p*times.size())-1))]; };
    std::ostringstream result;
    result<<std::fixed<<std::setprecision(3)<<"{\n  \"width\": "<<o.width<<", \"height\": "<<o.height<<", \"threads\": "<<o.threads
        <<", \"frames\": "<<o.frames<<",\n  \"startup_ms\": "<<startupMs<<", \"render_mean_ms\": "<<mean
        <<", \"render_p50_ms\": "<<percentile(.5)<<",\n  \"render_p95_ms\": "<<percentile(.95)<<", \"render_max_ms\": "<<times.back()
        <<", \"render_capacity_fps\": "<<1000/mean<<",\n  \"scope\": \"CPU render and synchronization; excludes window upload, present and vsync\"\n}\n";
    std::cout<<result.str();
    if(!o.report.empty()) { parentDirectory(o.report); std::ofstream out(o.report); out<<result.str(); if(!out) throw std::runtime_error("Cannot write benchmark report"); }
}
void require(bool condition,const char* message) {
    if(!condition) throw std::runtime_error(message && *message ? message : SDL_GetError());
}
struct SDLResources {
    SDL_Window* window=nullptr;
    SDL_Renderer* renderer=nullptr;
    SDL_Texture* texture=nullptr;
    ~SDLResources() { SDL_DestroyTexture(texture); SDL_DestroyRenderer(renderer); SDL_DestroyWindow(window); SDL_Quit(); }
};
int windowLoop(otto::Renderer& painter,otto::Playback& playback,const Options& o) {
    SDLResources s;
    if(o.smoke) { playback.closeDialog(); playback.replay(); playback.speed=1; }
    require(SDL_Init(SDL_INIT_VIDEO),SDL_GetError());
    SDL_WindowFlags flags=SDL_WINDOW_RESIZABLE|SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if(o.smoke) flags|=SDL_WINDOW_HIDDEN;
    require(SDL_CreateWindowAndRenderer("otto / Pizza in motion",o.width,o.height,flags,&s.window,&s.renderer),SDL_GetError());
    require(SDL_SetWindowMinimumSize(s.window,360,600),SDL_GetError());
    // A software backend or headless driver may not support vsync. The loop has
    // a frame limiter as a fallback, and waits for events while paused.
    bool vsync=SDL_SetRenderVSync(s.renderer,1);
    int width=0,height=0; bool dirty=true,running=true;
    auto rebuild=[&] {
        int w=0,h=0; require(SDL_GetRenderOutputSize(s.renderer,&w,&h),SDL_GetError());
        if(w<=0 || h<=0) return;
        if(w!=width || h!=height) {
            width=w; height=h; painter.resize(w,h); SDL_DestroyTexture(s.texture);
            s.texture=SDL_CreateTexture(s.renderer,SDL_PIXELFORMAT_ARGB8888,SDL_TEXTUREACCESS_STREAMING,w,h);
            require(s.texture!=nullptr,SDL_GetError());
            require(SDL_SetTextureBlendMode(s.texture,SDL_BLENDMODE_NONE),SDL_GetError());
            require(SDL_SetTextureScaleMode(s.texture,SDL_SCALEMODE_LINEAR),SDL_GetError());
        }
        dirty=true;
    };
    rebuild();
    auto dispatch=[&](SDL_Event& e) {
        require(SDL_ConvertEventToRenderCoordinates(s.renderer,&e),SDL_GetError());
        if(e.type==SDL_EVENT_QUIT) running=false;
        else if(e.type==SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) rebuild();
        else if(e.type==SDL_EVENT_WINDOW_EXPOSED || e.type==SDL_EVENT_WINDOW_RESTORED) dirty=true;
        else if(e.type==SDL_EVENT_WINDOW_FOCUS_LOST) painter.release(playback);
        else if(e.type==SDL_EVENT_MOUSE_MOTION) { painter.drag(playback,e.motion.x,e.motion.y); dirty=true; }
        else if(e.type==SDL_EVENT_MOUSE_BUTTON_DOWN && e.button.button==SDL_BUTTON_LEFT) {
            painter.press(playback,e.button.x,e.button.y); if(painter.dragging()) SDL_CaptureMouse(true); dirty=true;
        } else if(e.type==SDL_EVENT_MOUSE_BUTTON_UP && e.button.button==SDL_BUTTON_LEFT) {
            painter.release(playback); SDL_CaptureMouse(false); dirty=true;
        } else if(e.type==SDL_EVENT_KEY_DOWN && !e.key.repeat) {
            auto key=e.key.key;
            if(key==SDLK_ESCAPE) { if(playback.dialog) playback.closeDialog(); }
            else if(key==SDLK_TAB) painter.focusNext((e.key.mod&SDL_KMOD_SHIFT)!=0,playback.dialog);
            else if(key==SDLK_RETURN || key==SDLK_KP_ENTER) painter.activateFocus(playback);
            else if(!playback.dialog) {
                if(key==SDLK_SPACE) playback.toggle(); else if(key==SDLK_R) playback.replay();
                else if(key==SDLK_S) playback.nextSpeed(); else if(key==SDLK_I) playback.openDialog();
                else if(key==SDLK_LEFT) playback.seek(playback.time-1); else if(key==SDLK_RIGHT) playback.seek(playback.time+1);
                else if(key==SDLK_HOME || key==SDLK_1) { playback.seek(0); playback.playing=true; }
                else if(key==SDLK_2) { playback.seek(otto::assemble); playback.playing=true; }
                else if(key==SDLK_END || key==SDLK_3) { playback.seek(otto::duration); playback.playing=false; }
            }
            dirty=true;
        }
    };
    auto previous=Clock::now(),stats=previous; int frameCount=0,drawCount=0;
    for(;running;++frameCount) {
        auto frameStart=Clock::now();
        if(o.smoke) {
            // Exercise the real SDL event queue and the shared production handler.
            const SDL_Keycode keys[]={SDLK_SPACE,SDLK_R,SDLK_S,SDLK_I,SDLK_ESCAPE,SDLK_3,SDLK_HOME};
            if(frameCount<7) { SDL_Event e{}; e.type=SDL_EVENT_KEY_DOWN; e.key.key=keys[frameCount]; require(SDL_PushEvent(&e),SDL_GetError()); }
        }
        SDL_Event event{};
        if(!o.smoke && (!playback.playing || playback.dialog) && !dirty && !painter.dragging()) {
            if(SDL_WaitEventTimeout(&event,250)) dispatch(event);
        }
        while(SDL_PollEvent(&event)) dispatch(event);
        if(o.smoke && frameCount<7) {
            if(frameCount==0) require(!playback.playing,"SDL pause event failed");
            if(frameCount==1) require(playback.playing && playback.time==0,"SDL replay event failed");
            if(frameCount==2) require(playback.speed==1.5,"SDL speed event failed");
            if(frameCount==3) require(playback.dialog && !playback.playing,"SDL ingredients event failed");
            if(frameCount==4) require(!playback.dialog && playback.playing,"SDL dialog resume failed");
            if(frameCount==5) require(playback.time==otto::duration && !playback.playing,"SDL chapter event failed");
            if(frameCount==6) require(playback.time==0 && playback.playing,"SDL home event failed");
        }
        auto now=Clock::now(); double delta=std::chrono::duration<double>(now-previous).count(); previous=now;
        double old=playback.time; playback.tick(delta); dirty|=old!=playback.time;
        if(dirty) {
            const auto& frame=painter.draw(playback); BLImageData pixels{}; otto::check(frame.getData(&pixels),"get framebuffer");
            require(SDL_UpdateTexture(s.texture,nullptr,pixels.pixelData,int(pixels.stride)),SDL_GetError());
            require(SDL_SetRenderDrawColor(s.renderer,247,245,238,255),SDL_GetError()); require(SDL_RenderClear(s.renderer),SDL_GetError());
            require(SDL_RenderTexture(s.renderer,s.texture,nullptr,nullptr),SDL_GetError()); require(SDL_RenderPresent(s.renderer),SDL_GetError());
            dirty=false;++drawCount;
        }
        if(std::chrono::duration<double>(now-stats).count()>=1) {
            std::string title="otto / "+std::to_string(drawCount)+" fps / Blend2D "+std::to_string(painter.renderMilliseconds()).substr(0,4)+" ms / SDL3";
            SDL_SetWindowTitle(s.window,title.c_str()); stats=now; drawCount=0;
        }
        if(o.smoke && frameCount>=11) break;
        if(!vsync && !o.smoke && playback.playing) {
            double remaining=1./120-std::chrono::duration<double>(Clock::now()-frameStart).count();
            if(remaining>0) SDL_DelayNS(Uint64(remaining*1e9));
        }
    }
    if(o.smoke) {
        // Hit testing shares the exact responsive layout used by drawing.
        otto::Layout l(width,height); auto click=[&](const otto::Rect& r) { painter.press(playback,l.ox+(r.x+r.w/2)*l.scale,l.oy+(r.y+r.h/2)*l.scale); painter.release(playback); };
        click(l.ingredients); require(playback.dialog,"Ingredients hit test failed");
        click(l.back); require(!playback.dialog,"Dialog back hit test failed");
        click(l.chapters[2]); require(playback.time==otto::duration,"Chapter hit test failed");
        click(l.seek); require(std::abs(playback.time-otto::duration/2)<1e-8,"Timeline hit test failed");
        painter.resize(480,1100); painter.draw(playback); painter.resize(width,height); painter.draw(playback);
        std::cout<<"PASS: SDL3 key events, pause/replay/speed/dialog/chapters, pointer seeking, resize and framebuffer upload/present\n";
    }
    return 0;
}
} // namespace
int main(int argc,char** argv) {
    try {
        auto o=options(argc,argv);
        if(o.help) {
            std::cout<<"otto - Blend2D + SDL3\n"
                "  --time SECONDS --paused --ingredients --width 1440 --height 1000 --threads 4\n"
                "  --render output/frame.png       Render without a window\n"
                "  --render output/detail.png --toppings-detail\n"
                "  --benchmark --frames 240 --report output/benchmark.json\n"
                "  --smoke-test                    Test SDL events and presentation\n"
                "  --dump-timeline output/timeline.csv\n"
                "Keys: Space play/pause, R replay, S speed, I ingredients, Esc close,\n"
                "      Left/Right seek, 1/2/3 chapters, Home/End, Tab/Enter controls.\n";
            return 0;
        }
        if(!o.dump.empty()) { dumpTimeline(o.dump); return 0; }
        auto start=Clock::now(); otto::Renderer renderer(o.width,o.height,o.threads,assets(o,argv[0]));
        double startup=std::chrono::duration<double,std::milli>(Clock::now()-start).count();
        otto::Playback playback; playback.seek(o.time); playback.playing=!o.paused && playback.time<otto::duration;
        if(o.ingredients) playback.openDialog();
        if(!o.render.empty()) {
            parentDirectory(o.render);
            const auto& image=o.toppingsDetail?renderer.drawToppingsDetail():renderer.draw(playback);
            otto::check(image.writeToFile(o.render.c_str()),"write PNG");
            std::cout<<"Rendered "<<o.render<<" at "<<playback.time<<" s; CPU render "<<renderer.renderMilliseconds()<<" ms\n"; return 0;
        }
        if(o.benchmark) { benchmark(renderer,o,startup); return 0; }
        return windowLoop(renderer,playback,o);
    } catch(const std::exception& e) { std::cerr<<"otto: "<<e.what()<<'\n'; return 1; }
}
