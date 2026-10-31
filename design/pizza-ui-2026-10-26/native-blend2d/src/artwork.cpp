#include "artwork.hpp"
#include "reveal.hpp"
#include "relief.hpp"
#include "dough.hpp"
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace otto {
const std::array<Recipe,8> recipes{{
    {"Margherita", "A love letter to the classics.", {"San Marzano tomato", "Fior di latte", "Fresh basil"}, 0x6b7841, {"tomato","cheese","basil"}, {0xf4d59a,0xcf9450,0x90532b}, 0xa73e26, {0xf8db9b,0xeaaa60}, 0xf9e6b4, "tomato"},
    {"Pepperoni", "A little heat. A lot of character.", {"Spiced pepperoni", "Mozzarella", "Oregano"}, 0xad4c32, {"pepperoni","pepperoni","basil"}, {0xe9b976,0xb57534,0x714021}, 0x96351f, {0xedc378,0xd98d43}, 0xf1cb86, "tomato"},
    {"Funghi", "Earthy, delicate, quietly indulgent.", {"Chestnut mushrooms", "Truffle cream", "Thyme"}, 0x887052, {"mushroom","mushroom","cheese"}, {0xe1cca1,0xb7996a,0x756043}, 0xbfb08a, {0xf6ead0,0xd6c19a}, 0xfff4da, "cream"},
    {"Primavera", "The garden, in all its colour.", {"Sweet peppers", "Kalamata olives", "Basil pesto"}, 0x788342, {"pepper","olive","basil"}, {0xebd29b,0xb59755,0x7c6334}, 0x56683a, {0xd6d498,0xa6b06c}, 0xeee2af, "pesto"},
    {"Hawaiian", "A golden little escape.", {"Roasted pineapple", "Prosciutto cotto", "Mozzarella"}, 0xc69938, {"pineapple","ham","pineapple"}, {0xf8d28a,0xd69f46,0x93612b}, 0xc67a32, {0xffe2a0,0xe8b857}, 0xffeaba, "golden"},
    {"Frutti di Mare", "A taste of the Mediterranean.", {"Tiger prawns", "Garlic butter", "Flat-leaf parsley"}, 0xcc805d, {"shrimp","shrimp","basil"}, {0xf1d8a8,0xc9a375,0x8b6541}, 0xbd6d49, {0xf8dfbc,0xe9b590}, 0xfff1d4, "cream"},
    {"Calabrese", "Bold flavours, southern soul.", {"Calabrian salami", "Red onion", "Chilli oil"}, 0xa7482e, {"pepperoni","onion","pepper"}, {0xdba86b,0xa56732,0x633b26}, 0x8d3020, {0xd7864d,0xbe5c33}, 0xedbb80, "tomato"},
    {"Quattro Formaggi", "Four cheeses. Perfect harmony.", {"Gorgonzola", "Fontina & mozzarella", "Parmigiano Reggiano"}, 0xb19b61, {"cheese","bluecheese","cheese"}, {0xeddaa8,0xc4a469,0x886939}, 0xd4c59b, {0xfff1c6,0xe4cf8e}, 0xfff9df, "four-cheese"}
}};
void check(BLResult result, const char* operation) {
    if (result!=BL_SUCCESS) throw std::runtime_error(std::string(operation)+" failed: "+std::to_string(result));
}
void stroke(BLContext& c, const BLPath& p, uint32_t color, double width) {
    c.setStrokeWidth(width); c.strokePath(p, rgba(color));
}
void line(BLContext& c, double x0,double y0,double x1,double y1,uint32_t color,double width) {
    BLPath p; p.moveTo(x0,y0); p.lineTo(x1,y1); stroke(c,p,color,width);
}
BLPath svgPath(const char* s) {
    BLPath p;
    char command = 0;
    double x=0,y=0,startX=0,startY=0,qx=0,qy=0;
    auto skip = [&] { while (*s && (std::isspace(static_cast<unsigned char>(*s)) || *s==',')) ++s; };
    auto number = [&] { skip(); char* end=nullptr; double v=std::strtod(s,&end);
        if (end==s) throw std::runtime_error("Invalid local artwork path");
        s=end; return v; };
    while (true) {
        skip(); if (!*s) break;
        if (std::isalpha(static_cast<unsigned char>(*s))) command=*s++;
        bool relative = std::islower(static_cast<unsigned char>(command));
        double ox=relative ? x : 0, oy=relative ? y : 0;
        switch (std::toupper(static_cast<unsigned char>(command))) {
        case 'M': { x=number()+ox; y=number()+oy; p.moveTo(x,y); startX=x; startY=y; command=relative?'l':'L'; break; }
        case 'L': { x=number()+ox; y=number()+oy; p.lineTo(x,y); break; }
        case 'Q': { qx=number()+ox; qy=number()+oy; x=number()+ox; y=number()+oy; p.quadTo(qx,qy,x,y); break; }
        case 'T': { qx=2*x-qx; qy=2*y-qy; x=number()+ox; y=number()+oy; p.quadTo(qx,qy,x,y); break; }
        case 'C': { double a=number()+ox,b=number()+oy,c=number()+ox,d=number()+oy;
            x=number()+ox; y=number()+oy; p.cubicTo(a,b,c,d,x,y); break; }
        case 'Z': p.close(); x=startX; y=startY; command=0; break;
        default: throw std::runtime_error("Unsupported artwork path command");
        }
    }
    return p;
}
BLPath wedge(double r) {
    constexpr double half = .3752510865888774;
    BLPath p; p.moveTo(5,0); p.lineTo(r*std::cos(half),-r*std::sin(half));
    p.arcTo(0,0,r,r,-half,2*half); p.close(); return p;
}
namespace {
void path(BLContext& c,const char* source,uint32_t fill,uint32_t outline=0,double width=1) {
    BLPath p=svgPath(source); if(fill) c.fillPath(p,rgba(fill)); if(outline) stroke(c,p,outline,width);
}
BLGradient radial(double x,double y,double r,uint32_t a,uint32_t b) {
    BLGradient g(BLRadialGradientValues(x,y,x,y,r));
    g.addStop(0,rgba(a)); g.addStop(1,rgba(b)); return g;
}
void topping(BLContext& c,std::string_view name) {
    if(name=="pepperoni") {
        auto g=radial(-4,-4,23,0xd87551,0x9b3d2b); g.addStop(.75,rgba(0xbf4d35));
        c.fillCircle(0,0,15,g); c.setStrokeWidth(.45); c.strokeCircle(0,0,15,rgba(0xa9452e));
        c.setStrokeWidth(.35); c.strokeCircle(0,0,12.5,rgba(0xed9970));
        constexpr int pts[7][2]={{0,-8},{7,-5},{-7,-3},{4,4},{-5,7},{9,6},{-2,0}};
        for(int i=0;i<7;++i) { c.save(); c.translate(pts[i][0],pts[i][1]); c.rotate(i*25*pi/180);
            c.fillEllipse(0,0,i%2?1.2:1.8,1.1,rgba(0xf1ba8b)); c.restore(); }
    } else if(name=="tomato") {
        c.fillCircle(0,0,14,radial(-4,-5,23,0xea8450,0xb9482c)); c.setStrokeWidth(.4); c.strokeCircle(0,0,14,rgba(0xb64b2d));
        c.fillCircle(0,0,10.8,rgba(0xe58b4c)); c.setStrokeWidth(1.2); c.strokeCircle(0,0,10.8,rgba(0xf1b16c));
        for(int i=0;i<3;++i) { c.save(); c.rotate(i*2*pi/3); path(c,"M 0 -1 Q -12 -11 -2 -10 Q 4 -8 0 -1",0xb9502e);
            c.fillEllipse(-4,-6,1,2,rgba(0xfbe2a0)); c.restore(); } c.fillCircle(0,0,2,rgba(0xf8c37a));
    } else if(name=="basil") {
        BLGradient g(BLLinearGradientValues(-18,-18,18,18)); g.addStop(0,rgba(0x8b9b45)); g.addStop(1,rgba(0x435a29));
        auto p=svgPath("M -11 13 C -18 -2 -8 -16 12 -14 C 18 3 9 15 -11 13"); c.fillPath(p,g); stroke(c,p,0x52692d,.6);
        path(c,"M -13 16 L 10 -12 M -5 6 L -7 -4 M 1 -1 L 10 0 M 4 -5 L 3 -11",0,0xb4bd71,.8);
    } else if(name=="mushroom") {
        path(c,"M -14 2 C -19 -19 16 -22 16 1 Q 9 7 4 3 L 5 13 Q 0 17 -5 13 L -4 3 Q -10 7 -14 2",0xfff0cc,0x9f774f,.45);
        path(c,"M -12 1 Q 0 -7 13 1 M -8 1 L -6 -2 M 8 1 L 6 -2 M 0 4 L 0 12",0,0xc09a6a,.7);
        path(c,"M -11 -6 Q -6 -13 2 -12",0,0xfff9e9,2);
    } else if(name=="olive") {
        c.fillEllipse(0,0,10,12,rgba(0x43432e)); c.setStrokeWidth(.4); c.strokeEllipse(0,0,10,12,rgba(0x303525));
        c.save(); c.setCompOp(BL_COMP_OP_CLEAR); c.fillEllipse(0,0,4.5,6); c.restore();
        path(c,"M -6 -6 Q -8 -1 -6 5",0,0x81805c,1);
    } else if(name=="pepper") {
        path(c,"M -10 11 Q -17 -1 -9 -11 Q -2 -17 10 -8 L 6 -3 Q -1 -9 -4 -4 Q -9 1 -4 8 Z",0xd98235,0xb66c2a,.4);
        path(c,"M -8 8 Q -13 -1 -7 -8 Q -1 -12 6 -7",0,0xf3b85d,2);
    } else if(name=="pineapple") {
        path(c,"M -9 -12 L 9 -9 L 12 10 L -9 12 L -13 -2 Z",0xe8b943,0xc39230,.35);
        path(c,"M -6 -7 L 5 -5 L 7 6 L -5 8 Z",0xf7d56a); path(c,"M -5 -6 L 5 6 M 4 -5 L -4 7",0,0xeabd4d);
    } else if(name=="ham") {
        path(c,"M -12 -9 Q -2 -14 11 -7 L 14 6 Q 2 15 -10 10 Z",0xd98779,0xb6655c,.4);
        path(c,"M -10 -6 Q 1 -11 10 -5 M -7 8 Q 0 10 10 5",0,0xf2bca4,2);
    } else if(name=="shrimp") {
        path(c,"M 10 -7 C -1 -20 -20 -5 -11 8 C -5 20 13 13 12 3 C 9 -3 2 -3 1 3 C 3 10 -7 6 -5 0 C -3 -6 3 -5 7 -2 L 15 -7 L 15 -13 Z",0xf3ad84,0xcb805c,.4);
        path(c,"M -10 -4 L -4 -1 M -11 3 L -5 3 M -6 10 L -3 5 M 2 11 L 3 6",0,0xffddba,2.2);
    } else if(name=="onion") {
        path(c,"M -12 -8 Q 16 -20 12 9 Q 1 21 -12 -8 Z",0,0xa76a7b,4);
        path(c,"M -11 -7 Q 12 -15 10 8 Q 1 16 -11 -7",0,0xe4b7b1,1.5);
    } else if(name=="bluecheese") {
        path(c,"M -11 -9 L 7 -12 L 13 8 L -7 12 Z",0xefdfac,0xd2bc87,.35);
        path(c,"M -6 -6 L -1 0 L -4 6 M 5 -8 L 3 -1 L 8 5 M -1 0 L 4 2",0,0x82917a,1.8);
    } else {
        path(c,"M -11 -7 Q -6 -15 2 -11 Q 14 -13 13 -2 Q 18 7 7 11 Q -3 16 -10 8 Q -17 4 -11 -7",0xfff2c6,0xe1c48e,.3);
        path(c,"M -7 -7 Q 0 -11 7 -6",0,0xfffbea,2);
    }
}
void sliceArt(BLContext& c,int i) {
    const auto& r=recipes[i]; std::string_view style=r.style;
    auto crust=radial(0,0,207,r.crust[0],r.crust[2]);
    crust.addStop(.86,rgba(r.crust[0])); crust.addStop(.96,rgba(r.crust[1]));
    c.fillPath(wedge(),crust); stroke(c,wedge(),r.crust[2],.6);
    c.fillPath(wedge(182),rgba(r.sauce)); stroke(c,wedge(182),r.crust[1],1.3);
    auto cheese=radial(80,-32,160,r.cheese[0],r.cheese[1]);
    c.fillPath(wedge(style=="tomato"?171:176),cheese); stroke(c,wedge(style=="tomato"?171:176),r.edge,1.3);
    for(int j=0;j<18;++j) {
        double rad=43+(j*43%126),a=(-17+j*19%34)*pi/180,x=rad*std::cos(a),y=rad*std::sin(a);
        c.save(); c.translate(x,y); c.rotate(j*41*pi/180); c.setGlobalAlpha(style=="tomato"?.38:.25);
        path(c,"M -7 0 q 1 -7 8 -5 t 6 8 q -2 5 -9 3 Z",style=="cream"?0xfff8e8:style=="four-cheese"?(j%2?0xf8f1cd:0xb2b58a):r.sauce); c.restore();
    }
    if(style=="pesto") for(int j=0;j<30;++j) {
        double a=(-18+j*23%36)*pi/180,rad=35+j*5; c.save(); c.setGlobalAlpha(.5);
        c.fillCircle(rad*std::cos(a),rad*std::sin(a),.8+j%2,rgba(0x596d32)); c.restore();
    }
    if(style=="cream") { c.save(); c.setGlobalAlpha(.48); path(c,"M 66 -9 Q 113 10 169 -30 M 99 22 Q 131 7 172 19",0,0xfff8e9,3); c.restore(); }
    // Toasting is irregular; the highlight now comes from the round crust's
    // geometry rather than painted, parallel rings across a flat surface.
    for(int j=0;j<13;++j) {
        double a=(-19+j*3.1)*pi/180,rad=187+(j*7%11);
        c.save(); c.translate(rad*std::cos(a),rad*std::sin(a)); c.rotate(a);
        c.setGlobalAlpha(j%3?.14:.25);
        c.fillEllipse(0,0,1.5+j%3,2.1+j%4,rgba(r.crust[2])); c.restore();
    }
    for(int j=0;j<34;++j) {
        double rad=35+j*47%135,a=(-18+j*13%36)*pi/180;
        c.save(); c.translate(rad*std::cos(a),rad*std::sin(a)); c.rotate(j*23*pi/180); c.setGlobalAlpha(j%3?.3:.8);
        c.fillEllipse(0,0,1+j%3,.7+j%2,rgba(j%3?0xbf8a45:0xfff0b6)); c.restore();
    }
    for(int j=0;j<13;++j) {
        double rad=50+j*10,a=(-16+j*17%32)*pi/180,x=rad*std::cos(a),y=rad*std::sin(a);
        c.save(); c.setGlobalAlpha(.65); line(c,x,y,x+2,y-2,0x697442); line(c,x+1,y-2,x+3,y,0x697442); c.restore();
    }
    constexpr int marks[]{-15,-8,3,13,18};
    for(int j=0;j<5;++j) { double a=marks[j]*pi/180; c.save(); c.translate(192*std::cos(a),192*std::sin(a));
        c.rotate(a); c.setGlobalAlpha(.45); c.fillEllipse(0,0,1.2+j%2,2.4+j%3,rgba(0x9e6436)); c.restore(); }
}
double hash(double x,double y) { double v=std::sin(x*127.1+y*311.7)*43758.5453; return v-std::floor(v); }
double noise(double x,double y) {
    double ix=std::floor(x),iy=std::floor(y),fx=smooth(x-ix),fy=smooth(y-iy);
    return std::lerp(std::lerp(hash(ix,iy),hash(ix+1,iy),fx),std::lerp(hash(ix,iy+1),hash(ix+1,iy+1),fx),fy);
}
struct Vec { double x,y,z; };
Vec norm(Vec a) { double n=std::sqrt(a.x*a.x+a.y*a.y+a.z*a.z); return {a.x/n,a.y/n,a.z/n}; }
double dot(Vec a,Vec b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
uint32_t pack(double r,double g,double b,double a) {
    auto byte=[](double x) { return uint32_t(std::lround(clamp(x)*255)); };
    return (byte(a)<<24)|(byte(clamp(r)*a)<<16)|(byte(clamp(g)*a)<<8)|byte(clamp(b)*a);
}
uint32_t* row(BLImageData& d,int y) { return reinterpret_cast<uint32_t*>(static_cast<uint8_t*>(d.pixelData)+y*d.stride); }

struct Ingredient {
    std::string_view name;
    ReliefField field{88,88,2,-22,-22};
    std::vector<float> alpha=std::vector<float>(88*88);
};
void makeIngredient(Ingredient& asset,std::string_view name) {
    asset.name=name; constexpr int size=88;
    BLImage image(size,size,BL_FORMAT_PRGB32);
    { BLContext c(image); c.clearAll(); c.scale(2); c.translate(22,22); topping(c,name); check(c.end(),"bake ingredient"); }
    BLImageData data{}; check(image.getData(&data),"read ingredient");
    std::vector<float> distance(size*size);
    for(int y=0;y<size;++y) for(int x=0;x<size;++x) {
        size_t i=size_t(y)*size+x; uint32_t p=row(data,y)[x]; double a=(p>>24)/255.;
        asset.alpha[i]=float(a); distance[i]=a>.5?1000.f:0.f;
        auto& v=asset.field.pixels[i];
        // Keep local ingredient color premultiplied while interpolating across
        // its transparent silhouette; unassociated RGB would leave dark rims.
        if(a>0) { v.r=((p>>16)&255)/255.f; v.g=((p>>8)&255)/255.f; v.b=(p&255)/255.f; }
    }
    // Distance to each food silhouette gives bevels that follow its own edge,
    // including olive/onion holes, instead of the pizza's radial direction.
    for(int y=0;y<size;++y) for(int x=0;x<size;++x) {
        auto i=size_t(y)*size+x; float d=distance[i];
        if(x>0) d=std::min(d,distance[i-1]+1);
        if(y>0) d=std::min(d,distance[i-size]+1);
        if(x>0 && y>0) d=std::min(d,distance[i-size-1]+1.414214f);
        if(x+1<size && y>0) d=std::min(d,distance[i-size+1]+1.414214f);
        distance[i]=d;
    }
    for(int y=size-1;y>=0;--y) for(int x=size-1;x>=0;--x) {
        auto i=size_t(y)*size+x; float d=distance[i];
        if(x+1<size) d=std::min(d,distance[i+1]+1);
        if(y+1<size) d=std::min(d,distance[i+size]+1);
        if(x+1<size && y+1<size) d=std::min(d,distance[i+size+1]+1.414214f);
        if(x>0 && y+1<size) d=std::min(d,distance[i+size-1]+1.414214f);
        distance[i]=d;
    }
    for(int y=0;y<size;++y) for(int x=0;x<size;++x) {
        auto i=size_t(y)*size+x; auto& v=asset.field.pixels[i]; if(asset.alpha[i]<=0) continue;
        double u=-22+(x+.5)/2,vv=-22+(y+.5)/2;
        double d=std::max(0.,(distance[i]-.35)/2),bevel=1.6,peak=3,roughness=.6,specular=.08;
        double grain=noise(u*.6+7.1,vv*.6+2.8)-.5;
        if(name=="pepperoni") {
            double r=std::hypot(u,vv)/15;
            peak=2.7+1.45*std::pow(clamp(r),4)+grain*.16; bevel=1.15; roughness=.3; specular=.22;
        } else if(name=="tomato") {
            double angle=std::atan2(vv,u),r=std::hypot(u,vv)/14;
            peak=3.3+.5*(1-r*r)-.45*std::pow(std::max(0.,std::cos(angle*3)),8)*smooth(r); roughness=.28; specular=.2;
        } else if(name=="basil") {
            double vein=std::exp(-std::pow((u+vv*.8)/1.1,2));
            peak=1.45+.65*std::sin((u-vv)*.13)+vein*.35+grain*.1; bevel=1.9; roughness=.62; specular=.09;
        } else if(name=="mushroom") {
            peak=vv<3 ? 3.9+1.6*std::sqrt(std::max(0.,1-std::pow(u/18,2)))*(1-std::pow((vv+5)/22,2)) : 2.5;
            peak+=grain*.13; bevel=2.7; roughness=.72; specular=.07;
        } else if(name=="olive") {
            peak=5.8; bevel=4.2; roughness=.2; specular=.34;
        } else if(name=="pepper") {
            peak=4+.4*std::sin(u*.3+vv*.1); bevel=2.8; roughness=.36; specular=.17;
        } else if(name=="pineapple") {
            peak=6.2+grain*.12+std::sin(u*1.8)*.045; bevel=1.6; roughness=.45; specular=.12;
        } else if(name=="ham") {
            peak=2.2+.7*std::sin(u*.25+vv*.15)+.3*std::cos(vv*.4); bevel=1.1; roughness=.48; specular=.12;
        } else if(name=="shrimp") {
            peak=6.1*(.965+.035*std::cos(std::atan2(vv,u)*9)); bevel=4.5; roughness=.43; specular=.12;
        } else if(name=="onion") {
            peak=2.8; bevel=2.1; roughness=.27; specular=.16;
        } else if(name=="bluecheese") {
            peak=4.9+grain*.25; bevel=1.5; roughness=.74; specular=.045;
        } else {
            peak=3.3+.45*std::sin(u*.21)*std::cos(vv*.24)+grain*.09; bevel=4.2; roughness=.4; specular=.16;
        }
        v.height=float(std::max(0.,peak)*smooth(d/bevel)); v.roughness=float(roughness); v.specular=float(specular);
        // Low-amplitude material grain affects the albedo as well as the cap.
        double texture=1+grain*(name=="olive"?.025:name=="bluecheese"?.1:.055);
        v.r=float(std::min(double(asset.alpha[i]),v.r*texture));
        v.g=float(std::min(double(asset.alpha[i]),v.g*texture));
        v.b=float(std::min(double(asset.alpha[i]),v.b*texture));
    }
}
const Ingredient& ingredient(std::string_view name) {
    static const auto assets=[] {
        std::array<Ingredient,12> result;
        constexpr std::string_view names[]{"pepperoni","tomato","basil","mushroom","olive","pepper","pineapple","ham","shrimp","onion","cheese","bluecheese"};
        for(int i=0;i<12;++i) makeIngredient(result[i],names[i]);
        return result;
    }();
    for(const auto& asset:assets) if(asset.name==name) return asset;
    throw std::runtime_error("Unknown ingredient material");
}
float sampleAlpha(const Ingredient& a,double x,double y) {
    int ix=int(std::floor(x)),iy=int(std::floor(y)); if(ix<0 || iy<0 || ix>=87 || iy>=87) return 0;
    float fx=float(x-ix),fy=float(y-iy); auto i=size_t(iy)*88+ix;
    return std::lerp(std::lerp(a.alpha[i],a.alpha[i+1],fx),std::lerp(a.alpha[i+88],a.alpha[i+89],fx),fy);
}
void placeIngredients(ReliefField& surface,const BLImageData& mask,int index) {
    constexpr double points[9][4]={{58,0,.7,8},{96,-15,.95,-20},{101,19,.8,40},{134,-33,1,-35},{140,4,1.1,15},{143,39,.9,60},{170,-48,.83,30},{173,-15,.8,65},{172,27,1,-15}};
    for(int j=0;j<9;++j) {
        const auto& p=points[j]; const auto& asset=ingredient(recipes[index].toppings[j%3]);
        double angle=(p[3]+index*17)*pi/180,cs=std::cos(angle),sn=std::sin(angle);
        int x0=std::max(0,int((p[0]-32*p[2]-surface.left)*surface.scale));
        int x1=std::min(surface.width-1,int((p[0]+32*p[2]-surface.left)*surface.scale));
        int y0=std::max(0,int((p[1]-32*p[2]-surface.top)*surface.scale));
        int y1=std::min(surface.height-1,int((p[1]+32*p[2]-surface.top)*surface.scale));
        for(int y=y0;y<=y1;++y) for(int x=x0;x<=x1;++x) {
            auto maskRow=reinterpret_cast<const uint32_t*>(static_cast<const uint8_t*>(mask.pixelData)+y*mask.stride);
            if(!(maskRow[x]>>24)) continue;
            double dx=(surface.left+(x+.5)/surface.scale-p[0])/p[2],dy=(surface.top+(y+.5)/surface.scale-p[1])/p[2];
            double u=(dx*cs+dy*sn+22)*2-.5,v=(-dx*sn+dy*cs+22)*2-.5;
            float alpha=sampleAlpha(asset,u,v); if(alpha<=0) continue;
            auto top=asset.field.sample(u,v); auto& base=surface.pixels[size_t(y)*surface.width+x];
            top.height=base.baseHeight+top.height*float(p[2]); if(top.height<base.height) continue;
            base.r=base.r*(1-alpha)+top.r; base.g=base.g*(1-alpha)+top.g; base.b=base.b*(1-alpha)+top.b;
            base.height=top.height; base.roughness=top.roughness; base.specular=top.specular;
        }
    }
}
} // namespace

Artwork::Artwork() { for(int i=0;i<8;++i) bake(i); }
void Artwork::bake(int index) {
    auto& sprite=sprites_[index];
    BLImage art(width,height,BL_FORMAT_PRGB32),mask(width,height,BL_FORMAT_PRGB32);
    { BLContext c(art); c.clearAll(); c.scale(scale); c.translate(-left,-top); sliceArt(c,index); check(c.end(),"bake slice base"); }
    { BLContext c(mask); c.clearAll(); c.scale(scale); c.translate(-left,-top); c.fillPath(wedge(),BLRgba32(0xffffffff)); check(c.end(),"bake slice mask"); }
    check(sprite.scratch.create(width,height,BL_FORMAT_PRGB32),"create scratch");
    BLImageData source{},coverage{};
    check(art.getData(&source),"read slice base"); check(mask.getData(&coverage),"read slice mask");
    ReliefField surface(width,height,scale,left,top);
    for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
        uint32_t pixel=row(source,y)[x]; double a=(pixel>>24)/255.;
        auto& p=surface.pixels[size_t(y)*width+x];
        p.r=float(a?((pixel>>16)&255)/(255*a):.965);
        p.g=float(a?((pixel>>8)&255)/(255*a):.93);
        p.b=float(a?(pixel&255)/(255*a):.85);
        p.coverage=(row(coverage,y)[x]>>24)/255.f;
        if(p.coverage>0) {
            double lx=left+(x+.5)/scale,ly=top+(y+.5)/scale,rim=doughRim(lx,ly);
            p.baseHeight=p.height=float(doughHeight(lx,ly,index));
            p.roughness=float(std::lerp(.61,.86,rim)); p.specular=float(std::lerp(.055,.025,rim));
            double grain=1+(noise(lx*.35+index,ly*.35-index)-.5)*(.045+.07*rim);
            p.r=float(clamp(p.r*grain)); p.g=float(clamp(p.g*grain)); p.b=float(clamp(p.b*grain));
        }
    }
    placeIngredients(surface,coverage,index);
    double maxHeight=0;
    for(const auto& p:surface.pixels) maxHeight=std::max(maxHeight,double(p.height));
    auto proximity=surface.proximity(maxHeight);
    const Vec view=norm({0,.505,.862});
    for(int k=0;k<angles;++k) {
        check(sprite.lit[k].create(width,height,BL_FORMAT_PRGB32),"create relief cache");
        check(sprite.ghost[k].create(width,height,BL_FORMAT_PRGB32),"create raised shell cache");
        sprite.revealOffset[k].assign(size_t(width)*height,0);
        BLImageData output{}; check(sprite.lit[k].makeMutable(&output),"write relief cache");
        BLImageData ghost{}; check(sprite.ghost[k].makeMutable(&ghost),"write raised shell cache");
        double angle=k*2*pi/angles,cs=std::cos(angle),sn=std::sin(angle);
        auto shadow=surface.shadow(angle);
        for(int y=0;y<height;++y) for(int x=0;x<width;++x) {
            auto i=size_t(y)*width+x;
            auto hit=surface.intersect(x,y,angle,maxHeight,proximity[i]!=0);
            auto material=surface.sample(hit.x,hit.y);
            double alpha=hit.valid?material.coverage:0;
            if(alpha<=0) { row(output,y)[x]=0; row(ghost,y)[x]=0; continue; }
            double lx=left+(hit.x+.5)/scale,ly=top+(hit.y+.5)/scale,radius=std::hypot(lx,ly);
            sprite.revealOffset[k][i]=int8_t(std::clamp(std::lround((hit.x-x)/scale*16),-127l,127l));
            constexpr double step=.65;
            double nx=-(surface.sampleHeight(hit.x+step,hit.y)-surface.sampleHeight(hit.x-step,hit.y))*scale/(2*step);
            double ny=-(surface.sampleHeight(hit.x,hit.y+step)-surface.sampleHeight(hit.x,hit.y-step))*scale/(2*step);
            double toppingWeight=smooth((hit.height-material.baseHeight)/.6);
            double edge=std::min(std::abs(radius-201),std::abs(.3752*(lx-5)-.9270*std::abs(ly)));
            row(ghost,y)[x]=pack(std::lerp(.68,double(material.r),.32),std::lerp(.62,double(material.g),.32),
                std::lerp(.51,double(material.b),.32),alpha*(.075+std::exp(-edge*1.1)*.23));
            Vec normal=norm({nx*cs-ny*sn,nx*sn+ny*cs,1});
            Vec light=norm({-160-(lx*cs-ly*sn),-200-(lx*sn+ly*cs),302-hit.height});
            double diffuse=std::max(0.,dot(normal,light));
            Vec halfway=norm({light.x+view.x,light.y+view.y,light.z+view.z});
            double specPower=10+(1-material.roughness)*70;
            double specular=material.specular*std::pow(std::max(0.,dot(normal,halfway)),specPower);
            double ambientOcclusion=1;
            if(proximity[i]) {
                double cavity=0;
                for(auto d:std::array<BLPoint,4>{{{3,0},{-3,0},{0,3},{0,-3}}})
                    cavity+=std::max(0.,double(surface.sampleHeight(hit.x+d.x,hit.y+d.y))-hit.height)/4;
                ambientOcclusion=1-std::min(.28,cavity*.15);
            }
            // The shadow is projected from real ingredient heights and rotates
            // relative to the slice so that the world-space key light stays fixed.
            double contact=1-shadow[i]*.36*(1-toppingWeight);
            double ambient=std::lerp(.65,.52,toppingWeight),key=std::lerp(.3,.44,toppingWeight);
            double lighting=(ambient+key*diffuse)*ambientOcclusion*contact;
            double rim=std::pow(1-std::max(0.,dot(normal,view)),2.5)*.035;
            double bounce=(1-diffuse)*.055*toppingWeight;
            row(output,y)[x]=pack(material.r*(lighting+bounce)+specular,material.g*(lighting+bounce*.8)+specular*.89+rim*.3,
                material.b*(lighting+bounce*.5)+specular*.68+rim*.8,alpha);
        }
    }
}
const BLImage& Artwork::image(int index,double angle,double reveal) {
    auto& s=sprites_[index]; reveal=clamp(reveal);
    double pos=std::fmod(angle/(2*pi)*angles, double(angles)); if(pos<0) pos+=angles;
    int first=int(pos),second=(first+1)%angles; int fraction=int(std::lround((pos-first)*256));
    if(reveal>=1 && fraction==0) return s.lit[first];
    if(reveal<=0 && fraction==0) return s.ghost[first];
    if(s.lastAngle==angle && s.lastReveal==reveal) return s.scratch;
    s.lastAngle=angle; s.lastReveal=reveal;
    BLImageData a{},b{},ga{},gb{},out{};
    s.lit[first].getData(&a); s.lit[second].getData(&b);
    s.ghost[first].getData(&ga); s.ghost[second].getData(&gb); s.scratch.makeMutable(&out);
    // Source X may shift by a few physical units because of ingredient height.
    // Use a compact LUT for both cached directions, preserving the same reveal
    // boundary on the cheese, raised caps and the already-synchronized sides.
    constexpr int padding=128;
    std::array<int,width*8+padding*2> mask{};
    for(size_t x=0;x<mask.size();++x)
        mask[x]=int(std::lround(revealCoverage(left+.25+(double(x)-padding)/16,reveal)*256));
    const auto& offsetA=s.revealOffset[first]; const auto& offsetB=s.revealOffset[second];
    for(int y=0;y<height;++y) {
        auto pa=row(a,y),pb=row(b,y),pga=row(ga,y),pgb=row(gb,y),pd=row(out,y);
        for(int x=0;x<width;++x) {
            auto i=size_t(y)*width+x;
            int ma=mask[x*8+padding+offsetA[i]],mb=mask[x*8+padding+offsetB[i]];
            uint32_t result=0;
            for(int shift=0;shift<32;shift+=8) {
                int ca=(int((pa[x]>>shift)&255)*ma+int((pga[x]>>shift)&255)*(256-ma)+128)>>8;
                int cb=(int((pb[x]>>shift)&255)*mb+int((pgb[x]>>shift)&255)*(256-mb)+128)>>8;
                int value=(ca*(256-fraction)+cb*fraction+128)>>8;
                result|=uint32_t(value)<<shift;
            }
            pd[x]=result;
        }
    }
    return s.scratch;
}
} // namespace otto
