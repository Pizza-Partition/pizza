#pragma once
#include "artwork.hpp"
#include <filesystem>
#include <memory>
#include <string>
#include <unordered_map>

namespace otto {
struct Rect {
    double x{},y{},w{},h{};
    bool contains(double px,double py) const { return px>=x && py>=y && px<x+w && py<y+h; }
};
struct Layout {
    double w{},h{},scale{},ox{},oy{},cx{},cy{},pizzaScale{};
    bool mobile{};
    Rect ingredients, play, replay, seek, speed, chapters[3], modal, close, back;
    Layout(int width,int height);
};
class Renderer {
public:
    Renderer(int width,int height,unsigned threads,const std::filesystem::path& assets);
    void resize(int width,int height);
    const BLImage& draw(const Playback& playback);
    const BLImage& drawToppingsDetail();
    void pointer(double pixelX,double pixelY);
    bool press(Playback& playback,double pixelX,double pixelY);
    void drag(Playback& playback,double pixelX,double pixelY);
    void release(Playback& playback);
    void focusNext(bool backwards,bool dialog);
    void activateFocus(Playback& playback);
    bool dragging() const { return dragging_; }
    double renderMilliseconds() const { return renderMs_; }
private:
    struct Text { BLGlyphBuffer buffer; BLFont font; double width{}; };
    BLFontFace serif_,sans_;
    std::unordered_map<std::string,std::unique_ptr<Text>> textCache_;
    Artwork artwork_;
    BLImage frame_,background_,shadows_[2];
    Layout layout_;
    unsigned threads_;
    double hoverX_=-1,hoverY_=-1,renderMs_{};
    bool dragging_=false,resumeAfterDrag_=false;
    int focus_=-1;
    Text& text(const std::string& value,double size,bool serif);
    void label(BLContext& c,const std::string& value,double x,double y,double size,uint32_t color,bool serif=false,bool centered=false);
    void caps(BLContext& c,const std::string& value,double x,double y,double size,uint32_t color,bool centered=false);
    void makeBackground();
    void scene(BLContext& c,double time,const Frame& f);
    void shadow(BLContext& c,const Frame& f,double time);
    void wheel(BLContext& c,const Frame& f);
    void controls(BLContext& c,const Playback& p,const Frame& f);
    void dialog(BLContext& c);
    void perform(Playback& p,int id);
    Rect focusRect(int id) const;
};
} // namespace otto
