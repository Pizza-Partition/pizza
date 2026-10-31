#include "renderer.hpp"
#include "reveal.hpp"
#include "dough.hpp"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <stdexcept>

namespace otto {
namespace {
constexpr uint32_t paper=0xf7f5ee,rust=0x92472f,ink=0x473e32,muted=0xa99d8b,rule=0xdfd8ca;
std::string two(int n) { char b[24]; std::snprintf(b,sizeof b,"%02d",n); return b; }
void circle(BLContext& c,double x,double y,double r,uint32_t color,double width=1) {
    c.setStrokeWidth(width); c.strokeCircle(x,y,r,rgba(color));
}
void mark(BLContext& c,double x,double y,double r) {
    circle(c,x,y,r,rust,1.1);
    for(int i=0;i<8;++i) { double a=i*pi/4; line(c,x,y,x+(r-2)*std::cos(a),y+(r-2)*std::sin(a),rust,.8); }
    c.fillCircle(x,y,3,rgba(paper)); circle(c,x,y,3,rust,.8);
}
struct Slice { double angle,lift,height,reveal; };
Slice sliceAt(int i,double time,const Frame& f) {
    bool active=i==f.index && time>=assemble && !f.finishing;
    constexpr double heights[]{1,.92,1.08,.96,1.12,.88,1.05,.94};
    return {(-90+(i*45+90)*f.unfolded+f.rotation)*pi/180,
        active ? f.lift*22*heights[i] : 0,active ? f.lift*24 : 0,
        f.finishing || i<f.index ? 1 : active ? clamp(f.reveal) : 0};
}
BLPoint world(double x,double y,const Slice& s) {
    x+=s.lift; y-=s.lift*.22;
    double cs=std::cos(s.angle),sn=std::sin(s.angle);
    return {x*cs-y*sn,x*sn+y*cs};
}
using Points=std::array<BLPoint,128>;
double cross(BLPoint o,BLPoint a,BLPoint b) { return (a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x); }
int hull(Points& points,int count,Points& result) {
    std::sort(points.begin(),points.begin()+count,[](BLPoint a,BLPoint b){ return a.x<b.x || (a.x==b.x && a.y<b.y); });
    int k=0;
    for(int i=0;i<count;++i) { while(k>=2 && cross(result[k-2],result[k-1],points[i])<=0) --k; result[k++]=points[i]; }
    int limit=k+1;
    for(int i=count-2;i>=0;--i) { while(k>=limit && cross(result[k-2],result[k-1],points[i])<=0) --k; result[k++]=points[i]; }
    return std::max(0,k-1);
}
int footprint(const Slice& s,Points& out) {
    if(s.reveal<=0) return 0;
    Points contour; contour[0]={5,0}; constexpr double half=.3752510865888774;
    for(int j=0;j<=24;++j) { double a=-half+2*half*j/24; contour[j+1]={201*std::cos(a),201*std::sin(a)}; }
    double edge=s.reveal>=1 ? 202 : s.reveal*240-12; int n=0;
    for(int j=0;j<26;++j) {
        BLPoint a=contour[j],b=contour[(j+1)%26];
        if(a.x<=edge) out[n++]=world(a.x,a.y,s);
        if((a.x<=edge)!=(b.x<=edge)) { double t=(edge-a.x)/(b.x-a.x); out[n++]=world(edge,a.y+(b.y-a.y)*t,s); }
    }
    return n;
}
} // namespace
Layout::Layout(int width,int height) {
    mobile=double(width)/height<.82;
    scale=mobile ? std::min(double(width)/480,double(height)/1100) : std::min(double(width)/1440,double(height)/1000);
    w=mobile?480:std::min(1600.,width/scale); h=mobile?std::max(1100.,height/scale):1000;
    ox=(width-w*scale)/2; oy=(height-h*scale)/2;
    double margin=mobile?29:(w-std::min(1320.,w*.9))/2;
    ingredients={w-margin-(mobile?114:148),30,mobile?114.:148.,44};
    cx=w/2; cy=mobile?525:520; pizzaScale=mobile?.82:1.04;
    double py=mobile?h-195:803, pw=mobile?w-58:615, px=(w-pw)/2;
    play={px,py-18,94,37}; replay={px+100,py-18,35,37};
    seek={px+148,py-18,pw-270,37}; speed={px+pw-42,py-18,42,37};
    double chapterY=mobile?h-137:860,chapterW=(w-2*margin)/3;
    for(int i=0;i<3;++i) chapters[i]={margin+i*chapterW,chapterY,chapterW,87};
    modal={(w-(mobile?430:760))/2,(h-(mobile?850:615))/2,mobile?430.:760.,mobile?850.:615.};
    close={modal.x+modal.w-55,modal.y+15,40,40}; back={modal.x+30,modal.y+modal.h-67,modal.w-60,45};
}
Renderer::Renderer(int width,int height,unsigned threads,const std::filesystem::path& assets):layout_(width,height),threads_(threads) {
    check(serif_.createFromFile((assets/"fonts/CormorantGaramond.ttf").string().c_str()),"load Cormorant Garamond");
    check(sans_.createFromFile((assets/"fonts/DMSans.ttf").string().c_str()),"load DM Sans");
    for(auto& s:shadows_) check(s.create(420,420,BL_FORMAT_PRGB32),"create shadow field");
    resize(width,height);
}
void Renderer::resize(int width,int height) {
    layout_=Layout(width,height);
    check(frame_.create(width,height,BL_FORMAT_PRGB32),"create framebuffer");
    check(background_.create(width,height,BL_FORMAT_PRGB32),"create background");
    makeBackground();
}
Renderer::Text& Renderer::text(const std::string& value,double size,bool serif) {
    size=std::round(size*2)/2; // Bound the cache during the continuously moving reel.
    std::string key=(serif?"S":"D")+std::to_string(size)+":"+value;
    auto it=textCache_.find(key); if(it!=textCache_.end()) return *it->second;
    auto t=std::make_unique<Text>();
    check(t->font.createFromFace(serif?serif_:sans_,float(size)),"create font");
    check(t->buffer.setUtf8Text(value.data(),value.size()),"shape text input"); check(t->font.shape(t->buffer),"shape text");
    BLTextMetrics metrics{}; check(t->font.getTextMetrics(t->buffer,metrics),"measure text"); t->width=metrics.advance.x;
    auto& result=*t; textCache_.emplace(std::move(key),std::move(t)); return result;
}
void Renderer::label(BLContext& c,const std::string& s,double x,double y,double size,uint32_t color,bool serif,bool centered) {
    auto& t=text(s,size,serif); c.fillGlyphRun(BLPoint(centered?x-t.width/2:x,y),t.font,t.buffer.glyphRun(),rgba(color));
}
void Renderer::caps(BLContext& c,const std::string& s,double x,double y,double size,uint32_t color,bool centered) {
    // Glyph shaping is cached. Spacing is baked into this short uppercase label.
    std::string spaced; for(char ch:s) { if(!spaced.empty()) spaced+=' '; spaced+=ch; }
    label(c,spaced,x,y,size,color,false,centered);
}
void Renderer::makeBackground() {
    auto& l=layout_; BLContext c(background_); c.fillAll(rgba(paper));
    BLGradient glow(BLRadialGradientValues(background_.width()*.42,background_.height()*.42,background_.width()*.42,background_.height()*.42,background_.width()*.56));
    glow.addStop(0,BLRgba32(0x90fffdf5)); glow.addStop(1,BLRgba32(0x00fffdf5)); c.fillAll(glow);
    c.translate(l.ox,l.oy); c.scale(l.scale);
    double margin=l.mobile?29:(l.w-std::min(1320.,l.w*.9))/2;
    line(c,margin,100,l.w-margin,100,rule);
    mark(c,margin+15,51,l.mobile?13:15); label(c,"otto.",margin+40,64,46,rust,true);
    if(!l.mobile) caps(c,"A LITTLE ART. A LOT OF PIZZA.",l.w/2,55,8,muted,true);
    caps(c,"EIGHT SLICES. ONE LITTLE MASTERPIECE.",l.w/2,154,l.mobile?7:8,muted,true);
    caps(c,"THOUGHTFULLY LAYERED. BEAUTIFULLY SIMPLE.",margin,l.h-27,l.mobile?4.5:6.5,muted);
    label(c,"Made with a little amore",l.w-margin-(l.mobile?118:166),l.h-27,l.mobile?12:15,0x9a8b74,true);
    // Deterministic, very faint paper grain is baked once per resize.
    c.setGlobalAlpha(.035);
    uint32_t state=13;
    for(int i=0;i<6500;++i) { state=state*1664525+1013904223; double x=(state&65535)/65535.*l.w;
        state=state*1664525+1013904223; double y=(state&65535)/65535.*l.h; c.fillRect(x,y,.55,.55,rgba(0x78674b)); }
    check(c.end(),"bake background");
}
void Renderer::shadow(BLContext& output,const Frame& f,double time) {
    std::array<Slice,8> slices; std::array<Points,8> feet; std::array<int,8> sizes{};
    std::array<std::array<double,128>,8> topHeights{};
    bool any=false;
    for(int i=0;i<8;++i) {
        slices[i]=sliceAt(i,time,f); sizes[i]=footprint(slices[i],feet[i]); any|=sizes[i]>=3;
        double cs=std::cos(slices[i].angle),sn=std::sin(slices[i].angle);
        for(int j=0;j<sizes[i];++j) {
            auto p=feet[i][j];
            double x=p.x*cs+p.y*sn-slices[i].lift,y=-p.x*sn+p.y*cs+slices[i].lift*.22;
            topHeights[i][j]=18+doughHeight(x,y,i);
        }
    }
    if(!any) return;
    struct Light { double x,y,z,radius,strength; int count; };
    constexpr Light lights[]={{-160,-200,320,90,.2,32},{0,0,150,210,.075,20}};
    for(int layer=0;layer<2;++layer) {
        const auto& light=lights[layer]; BLContext c(shadows_[layer]); c.clearAll();
        c.scale(.5); c.translate(420,420); c.setCompOp(BL_COMP_OP_PLUS);
        // Each compound path is the union of all slices for one area-light
        // sample (non-zero winding). Overlapping slices never darken twice.
        for(int sample=0;sample<light.count;++sample) {
            double rad=light.radius*std::sqrt((sample+.5)/light.count),a=sample*2.399963229728653;
            double lx=light.x+rad*std::cos(a),ly=light.y+rad*std::sin(a);
            BLPath unionPath;
            for(int i=0;i<8;++i) {
                if(sizes[i]<3) continue;
                Points projected,convex; int count=0;
                for(int j=0;j<sizes[i];++j) for(double z:{slices[i].height,slices[i].height+topHeights[i][j]}) {
                    double factor=light.z/(light.z-z);
                    projected[count++]={lx+(feet[i][j].x-lx)*factor,(ly+(feet[i][j].y-ly)*factor)*.94+9.9};
                }
                int n=hull(projected,count,convex); if(n<3) continue;
                unionPath.moveTo(convex[0]); for(int j=1;j<n;++j) unionPath.lineTo(convex[j]); unionPath.close();
            }
            c.setGlobalAlpha(1./light.count); c.fillPath(unionPath,rgba(0x665442));
        }
        check(c.end(),"render area shadow");
        output.save(); output.setGlobalAlpha(f.unfolded*light.strength);
        output.blitImage(BLRect(-420,-420,840,840),shadows_[layer]); output.restore();
    }
}
void Renderer::scene(BLContext& c,double time,const Frame& f) {
    auto& l=layout_; double cx=l.cx-(l.mobile?0:f.offset*225);
    double cy=l.cy-(l.mobile?f.offset*66:0),scale=l.pizzaScale*(.75+.25*f.unfolded);
    c.save(); c.translate(cx,cy); c.scale(scale); c.setGlobalAlpha(f.unfolded);
    // Dotted orbit.
    for(int i=0;i<220;++i) { double a=i*2*pi/220; c.fillCircle(216*std::cos(a),216*.94*std::sin(a),.4,BLRgba32(0x60bc9a69)); }
    shadow(c,f,time);
    std::array<int,8> order{0,1,2,3,4,5,6,7};
    std::array<Slice,8> slices; for(int i=0;i<8;++i) slices[i]=sliceAt(i,time,f);
    std::stable_sort(order.begin(),order.end(),[&](int a,int b){
        auto center=[](const Slice& s) { auto p=world(120,0,s); return p.y*.505+s.height*.862; };
        return center(slices[a])<center(slices[b]);
    });
    constexpr double half=.3752510865888774;
    for(int i:order) {
        const auto& s=slices[i];
        constexpr int cuts=24,arcs=32,edges=cuts*2+arcs;
        std::array<BLPoint,edges> contour;
        BLPoint upper{201*std::cos(half),-201*std::sin(half)},lower{upper.x,-upper.y};
        for(int j=0;j<cuts;++j) { double t=double(j)/cuts;
            contour[j]={std::lerp(5.,upper.x,t),upper.y*t};
            contour[cuts+arcs+j]={std::lerp(lower.x,5.,t),lower.y*(1-t)};
        }
        for(int j=0;j<arcs;++j) { double a=-half+2*half*j/arcs; contour[cuts+j]={201*std::cos(a),201*std::sin(a)}; }
        std::array<BLPoint,edges> projected;
        std::array<double,edges> heights{},shades{};
        std::array<bool,edges> facing{};
        int start=0;
        for(int j=0;j<edges;++j) {
            projected[j]=world(contour[j].x,contour[j].y,s);
            heights[j]=doughHeight(contour[j].x,contour[j].y,i);
        }
        for(int j=0;j<edges;++j) {
            auto a=projected[j],b=projected[(j+1)%edges]; double dx=b.x-a.x,dy=b.y-a.y,length=std::hypot(dx,dy);
            facing[j]=dx< -1e-8;
            if(!facing[j]) start=j;
            shades[j]=length>0 ? .65+.3*std::max(0.,dy/length*(-.4)-dx/length*(-.5)) : .65;
        }
        std::array<int,edges> run{}; int count=0;
        auto flush=[&] {
            if(count==0) return;
            int first=run[0],last=(run[count-1]+1)%edges;
            double x0=projected[first].x,x1=projected[last].x;
            BLPath wall; auto top=[&](int vertex) { return BLPoint(projected[vertex].x,projected[vertex].y*.94-(s.height+heights[vertex])*.55); };
            auto bottom=[&](int vertex) { return BLPoint(projected[vertex].x,projected[vertex].y*.94-s.height*.55+9.9); };
            wall.moveTo(top(first));
            for(int j=0;j<count;++j) wall.lineTo(top((run[j]+1)%edges));
            wall.lineTo(bottom(last));
            for(int j=count-1;j>=0;--j) wall.lineTo(bottom(run[j]));
            wall.close();
            BLGradient gradient(BLLinearGradientValues(x0,0,x1,0));
            for(int j=0;j<count;++j) {
                int a=run[j],b=(a+1)%edges;
                std::array<double,19> positions{}; int n=0; positions[n++]=0; positions[n++]=1;
                double delta=contour[b].x-contour[a].x;
                if(std::abs(delta)>1e-9 && s.reveal>0 && s.reveal<.999) {
                    for(int k=0;k<=16;++k) {
                        double local=s.reveal*240-revealWidth+k*revealWidth/16;
                        double t=(local-contour[a].x)/delta;
                        if(t>0 && t<1) positions[n++]=t;
                    }
                }
                std::sort(positions.begin(),positions.begin()+n);
                for(int k=0;k<n;++k) {
                    double t=positions[k],worldX=std::lerp(projected[a].x,projected[b].x,t);
                    double coverage=revealCoverage(std::lerp(contour[a].x,contour[b].x,t),s.reveal);
                    double alpha=std::lerp(.2,1.,coverage);
                    auto channel=[&](double shell,double solid) { return uint32_t(std::lround(clamp(std::lerp(shell*.2,solid*shades[a],coverage)/alpha)*255)); };
                    auto color=BLRgba32((uint32_t(std::lround(alpha*255))<<24)|(channel(.68,.629)<<16)|(channel(.62,.417)<<8)|channel(.51,.218));
                    gradient.addStop(clamp((worldX-x0)/(x1-x0)),color);
                }
            }
            // Fill the visible wall as one polygon. Adjacent antialiased quads
            // leave bright vertical seams; a continuous fill keeps the crumb solid.
            c.fillPath(wall,gradient); count=0;
        };
        for(int j=1;j<=edges;++j) {
            int edge=(start+j)%edges;
            if(facing[edge]) run[count++]=edge; else flush();
        }
        flush();
        c.save();
        double cs=std::cos(s.angle),sn=std::sin(s.angle); auto origin=world(0,0,s);
        c.applyTransform(BLMatrix2D(cs,sn*.94,-sn,cs*.94,origin.x,origin.y*.94-s.height*.55));
        const auto& image=artwork_.image(i,s.angle,s.reveal);
        c.blitImage(BLRect(Artwork::left,Artwork::top,Artwork::width/Artwork::scale,Artwork::height/Artwork::scale),image);
        c.restore();
    }
    c.restore();
    double captionY=l.mobile?734-f.offset*88:747;
    c.save(); c.setGlobalAlpha(f.unfolded);
    std::string caption=f.finishing?"BUON APPETITO":time<assemble?"A WORLD OF POSSIBILITY":two(f.completed)+" OF 08 SLICES COMPOSED";
    caps(c,caption,cx,captionY,l.mobile?6:7,0x9e8c70,true);
    line(c,cx-146,captionY-3,cx-115,captionY-3,rule); line(c,cx+115,captionY-3,cx+146,captionY-3,rule); c.restore();
}
void Renderer::wheel(BLContext& c,const Frame& f) {
    auto& l=layout_; if(f.wheelOpacity<=0) return;
    double x=l.mobile?95:l.w*.65,y=l.mobile?670:405,w=l.mobile?290:315;
    const auto& r=recipes[f.index];
    c.save(); c.translate(x,y+(1-std::pow(clamp((f.wheelOpacity-.1)/.9),2))*14); c.setGlobalAlpha(clamp(f.wheelOpacity));
    caps(c,"THE INGREDIENTS",0,0,7.5,muted); label(c,two(f.index+1)+" / 08",w-50,0,10,0x9a896e);
    line(c,0,14,w,14,rule); c.fillCircle(4,41,3,rgba(r.color)); label(c,r.name,17,49,27,rust,true);
    double turn=f.index<7?smooth((f.local-2.95)/.65):0;
    double position=f.index*3+(f.wheelPosition-f.index)*2+turn;
    double reelY=116,reelH=l.mobile?105:163;
    c.save(); c.clipToRect(0,63,w,reelH);
    line(c,0,reelY-26,w,reelY-26,rule,.7); line(c,0,reelY+28,w,reelY+28,rule,.7);
    for(int j=0;j<24;++j) {
        double distance=std::abs(j-position),yy=reelY+(j-position)*54;
        if(yy<49 || yy>63+reelH+25) continue;
        double focus=std::max(0.,1-distance*.45),alpha=std::max(.1,focus*focus);
        double fade=clamp((yy-55)/30)*clamp((63+reelH-yy+12)/35);
        c.save(); c.setGlobalAlpha(clamp(f.wheelOpacity)*alpha*fade);
        double size=std::min(30.,(w-35)/std::max(1.,text(recipes[j/3].ingredients[j%3],30,true).width)*30);
        label(c,recipes[j/3].ingredients[j%3],w/2,yy+9,size*(1-std::min(distance,3.)*.04),distance<.4?rust:muted,true,true); c.restore();
    }
    c.restore();
    label(c,r.note,0,63+reelH+27,l.mobile?16:18,0x9d8d75,true);
    if(!l.mobile) {
        c.fillCircle(3,63+reelH+57,2,rgba(r.color));
        caps(c,f.reveal>=.99?"A LITTLE CLOSER TO PERFECT":"BRINGING FLAVOUR TO LIFE",13,63+reelH+60,5.8,muted);
        label(c,std::to_string(int(std::lround(clamp(f.reveal)*100)))+"%",w-26,63+reelH+60,8,0x9a896e);
    }
    c.restore();
    if(!l.mobile) { c.save(); c.setGlobalAlpha(clamp(f.wheelOpacity)*.7); double cx=l.cx-f.offset*225;
        line(c,cx+245,l.cy,l.w*.65-27,l.cy,rule,.8); c.fillCircle(cx+245,l.cy,2,rgba(0xb69b71)); c.restore(); }
}
Rect Renderer::focusRect(int id) const {
    const auto& l=layout_; switch(id) {
        case 0:return l.ingredients; case 1:return l.play; case 2:return l.replay; case 3:return l.seek;
        case 4:return l.speed; case 5:case 6:case 7:return l.chapters[id-5]; case 8:return l.close; case 9:return l.back;
    } return {};
}
void Renderer::controls(BLContext& c,const Playback& p,const Frame& f) {
    auto& l=layout_;
    for(int id=0;id<8;++id) { auto r=focusRect(id); if(!p.dialog && r.contains(hoverX_,hoverY_)) c.fillRoundRect(BLRoundRect(r.x,r.y,r.w,r.h,4),BLRgba32(0x09a57845)); }
    label(c,"Our ingredients",l.ingredients.x+5,57,l.mobile?12:13,rust);
    line(c,l.ingredients.x+l.ingredients.w-13,52,l.ingredients.x+l.ingredients.w-5,44,rust);
    line(c,l.ingredients.x+l.ingredients.w-11,44,l.ingredients.x+l.ingredients.w-5,44,rust);
    line(c,l.ingredients.x+l.ingredients.w-5,44,l.ingredients.x+l.ingredients.w-5,50,rust);
    auto r=l.play;
    c.fillRoundRect(BLRoundRect(r.x,r.y,r.w,r.h,2),BLRgba32(0x1292472f));
    if(p.playing) { c.fillRect(r.x+14,r.y+13,3,11,rgba(rust)); c.fillRect(r.x+20,r.y+13,3,11,rgba(rust)); }
    else { BLPath path; path.moveTo(r.x+15,r.y+12); path.lineTo(r.x+25,r.y+18.5); path.lineTo(r.x+15,r.y+25); path.close(); c.fillPath(path,rgba(rust)); }
    label(c,p.playing?"Pause":p.time>=duration?"Again":"Play",r.x+34,r.y+23,11,rust);
    r=l.replay; BLPath replay; replay.arcTo(r.x+18,r.y+19,6,6,.2,pi*1.75,true); stroke(c,replay,0x9a896e,1.2);
    line(c,r.x+22,r.y+12,r.x+22,r.y+17,0x9a896e); line(c,r.x+22,r.y+17,r.x+27,r.y+16,0x9a896e);
    r=l.seek; double gap=l.mobile?3:6,barW=(r.w-gap*7)/8;
    for(int i=0;i<8;++i) {
        c.fillRect(r.x+i*(barW+gap),r.y+17,barW,3,rgba(0xe4ddce));
        c.fillRect(r.x+i*(barW+gap),r.y+17,barW*clamp((p.time-assemble-i*cycle)/cycle),3,rgba(0xa87c50));
    }
    c.fillCircle(r.x+r.w*p.time/duration,r.y+18.5,2.6,rgba(rust));
    label(c,two(int(p.time))+" / 35",r.x+r.w+13,r.y+22,l.mobile?8:9,0x9a896e);
    r=l.speed; line(c,r.x,r.y+11,r.x,r.y+26,rule);
    label(c,p.speed==1?"1x":p.speed==1.5?"1.5x":"2x",r.x+12,r.y+22,10,0x9a896e);
    constexpr const char* names[]{"The beginning","The composition","The whole"};
    constexpr const char* details[]{"An idea takes shape.","Every slice, a little different.","Beautifully brought together."};
    double x0=l.chapters[0].x,x1=l.chapters[2].x+l.chapters[2].w,y=l.chapters[0].y;
    line(c,x0,y,x1,y,rule); line(c,x0,y+87,x1,y+87,rule);
    for(int i=0;i<3;++i) {
        r=l.chapters[i]; if(i>0) line(c,r.x,r.y+20,r.x,r.y+67,rule);
        double x=r.x+(l.mobile?15:29),cy=r.y+(l.mobile?24:44),radius=l.mobile?12:16;
        if(f.phase==i) c.fillCircle(x+radius,cy,radius,BLRgba32(0x0cece3d4));
        circle(c,x+radius,cy,radius,f.phase==i?0xb99a74:rule);
        label(c,two(i+1),x+radius,cy+5,l.mobile?12:15,f.phase==i?rust:muted,true,true);
        label(c,names[i],l.mobile?r.x+15:x+radius*2+16,r.y+(l.mobile?53:40),l.mobile?16:22,f.phase==i?rust:0x998d79,true);
        if(!l.mobile) label(c,details[i],x+radius*2+16,r.y+59,10,muted);
    }
    if(focus_>=0 && !p.dialog) { r=focusRect(focus_); c.setStrokeWidth(1.1); c.strokeRoundRect(BLRoundRect(r.x-3,r.y-3,r.w+6,r.h+6,3),rgba(rust)); }
}
void Renderer::dialog(BLContext& c) {
    auto& l=layout_; auto r=l.modal; c.fillRect(0,0,l.w,l.h,BLRgba32(0x66312a20));
    c.fillRoundRect(BLRoundRect(r.x+7,r.y+11,r.w,r.h,7),BLRgba32(0x1730271c));
    c.fillRoundRect(BLRoundRect(r.x,r.y,r.w,r.h,7),rgba(paper));
    caps(c,"THE OTTO COLLECTION",r.x+32,r.y+40,7,muted);
    line(c,l.close.x+13,l.close.y+13,l.close.x+26,l.close.y+26,rust,1.4);
    line(c,l.close.x+26,l.close.y+13,l.close.x+13,l.close.y+26,rust,1.4);
    label(c,"Eight little stories.",r.x+32,r.y+101,l.mobile?39:49,rust,true);
    label(c,"Simple ingredients. A world of flavour.",r.x+32,r.y+130,19,0x9a8b74,true);
    for(int i=0;i<8;++i) {
        double x=r.x+32+(l.mobile?0:(i%2)*350),y=r.y+166+(l.mobile?i*72:(i/2)*88),w=l.mobile?r.w-64:310;
        line(c,x,y,x+w,y,rule);
        label(c,two(i+1),x,y+26,8,0xae9773); label(c,recipes[i].name,x+27,y+29,25,rust,true);
        std::string ingredients=recipes[i].ingredients[0]; ingredients+=" / "; ingredients+=recipes[i].ingredients[1]; ingredients+=" / "; ingredients+=recipes[i].ingredients[2];
        double size=std::min(10.,(w-27)/text(ingredients,10,false).width*10);
        label(c,ingredients,x+27,y+51,size,0x988b77);
    }
    label(c,"Back to the composition   >",l.back.x,l.back.y+28,12,rust);
    if(focus_==8 || focus_==9) { r=focusRect(focus_); c.setStrokeWidth(1); c.strokeRect(BLRect(r.x,r.y,r.w,r.h),rgba(rust)); }
}
const BLImage& Renderer::draw(const Playback& p) {
    auto start=std::chrono::steady_clock::now(); auto& l=layout_; const auto f=frameAt(p.time);
    BLContextCreateInfo info{}; info.threadCount=threads_;
    BLContext c; check(c.begin(frame_,info),"begin framebuffer");
    c.setCompOp(BL_COMP_OP_SRC_COPY); c.blitImage(BLPointI(0,0),background_); c.setCompOp(BL_COMP_OP_SRC_OVER);
    c.translate(l.ox,l.oy); c.scale(l.scale); c.setPatternQuality(BL_PATTERN_QUALITY_BILINEAR);
    std::string title=f.finishing?"Complete.":"Pizza.";
    label(c,title,l.w/2,245,l.mobile?83:103,rust,true,true);
    double half=text(title,l.mobile?83:103,true).width/2;
    line(c,l.w/2-half-80,211,l.w/2-half-29,211,0xcbbb9e,.7);
    line(c,l.w/2+half+29,211,l.w/2+half+80,211,0xcbbb9e,.7);
    label(c,f.finishing?"Eight individual stories. One beautiful whole.":"Good things come together, one slice at a time.",l.w/2,280,l.mobile?16:20,0x9a8b74,true,true);
    if(!l.mobile) {
        caps(c,f.finishing?"MADE TO BE SHARED":"THE ART OF COMING TOGETHER",l.chapters[0].x+34,341,7,muted);
        double sx=l.w-l.chapters[0].x-75,sy=350;
        circle(c,sx,sy,39,0xc9baa1); circle(c,sx,sy,44,0xded4c3,.7);
        caps(c,"CRAFTED",sx,sy-18,5,0x958166,true); caps(c,"WITH CARE",sx,sy+25,5,0x958166,true);
        c.save(); c.translate(sx-16,sy-12); stroke(c,svgPath("M 16 27 L 16 7 M 16 19 C 6 20 5 11 5 11 C 12 10 16 14 16 19 M 16 14 C 25 14 27 5 27 5 C 20 5 16 8 16 14"),0x958166,1.1); c.restore();
    }
    scene(c,p.time,f); wheel(c,f); controls(c,p,f); if(p.dialog) dialog(c);
    check(c.end(),"finish framebuffer");
    renderMs_=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count(); return frame_;
}
const BLImage& Renderer::drawToppingsDetail() {
    auto start=std::chrono::steady_clock::now();
    BLContext c(frame_); c.fillAll(rgba(paper));
    double scale=std::min(frame_.width()/1440.,frame_.height()/1000.);
    c.translate((frame_.width()-1440*scale)/2,(frame_.height()-1000*scale)/2); c.scale(scale);
    label(c,"Texture & depth.",62,72,52,rust,true);
    label(c,"Pepperoni, mushrooms, olives, herbs and prawns",62,103,15,muted);
    constexpr int indices[]{1,2,3,5};
    for(int j=0;j<4;++j) {
        double x=40+(j%2)*700,y=135+(j/2)*425;
        line(c,x+20,y, x+660,y,rule);
        label(c,recipes[indices[j]].name,x+25,y+40,32,rust,true);
        c.blitImage(BLRect(x+25,y+65,Artwork::width*1.05,Artwork::height*1.05),artwork_.image(indices[j],0,1));
    }
    check(c.end(),"render topping detail");
    renderMs_=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count(); return frame_;
}
void Renderer::pointer(double x,double y) { hoverX_=(x-layout_.ox)/layout_.scale; hoverY_=(y-layout_.oy)/layout_.scale; }
void Renderer::perform(Playback& p,int id) {
    switch(id) {
    case 0:p.openDialog(); focus_=8;break;
    case 1:p.toggle();break; case 2:p.replay();break; case 4:p.nextSpeed();break;
    case 5:p.seek(0);p.playing=true;break; case 6:p.seek(assemble);p.playing=true;break;
    case 7:p.seek(duration);p.playing=false;break;
    case 8:case 9:p.closeDialog();focus_=0;break;
    }
}
bool Renderer::press(Playback& p,double x,double y) {
    pointer(x,y);
    if(p.dialog) {
        if(!layout_.modal.contains(hoverX_,hoverY_) || layout_.close.contains(hoverX_,hoverY_) || layout_.back.contains(hoverX_,hoverY_)) perform(p,8);
        return true;
    }
    for(int id=0;id<8;++id) if(focusRect(id).contains(hoverX_,hoverY_)) {
        focus_=id;
        if(id==3) { dragging_=true; resumeAfterDrag_=p.playing; p.playing=false; drag(p,x,y); }
        else perform(p,id);
        return true;
    }
    focus_=-1;return false;
}
void Renderer::drag(Playback& p,double x,double y) {
    pointer(x,y); if(dragging_) p.seek(clamp((hoverX_-layout_.seek.x)/layout_.seek.w)*duration);
}
void Renderer::release(Playback& p) {
    if(dragging_) { dragging_=false; p.playing=resumeAfterDrag_ && p.time<duration; }
}
void Renderer::focusNext(bool backwards,bool modal) {
    int low=modal?8:0,high=modal?9:7;
    if(focus_<low || focus_>high) focus_=backwards?high:low;
    else focus_=focus_==low && backwards ? high : focus_==high && !backwards ? low : focus_+(backwards?-1:1);
}
void Renderer::activateFocus(Playback& p) { if(focus_>=0 && (!p.dialog || focus_>=8)) perform(p,focus_); }
} // namespace otto
