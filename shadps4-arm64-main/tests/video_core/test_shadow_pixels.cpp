// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <cstring>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "video_core/shadow_pixels.h"

namespace {

using namespace VideoCore::Shadow;

TEST(ShadowPixels, FormatNamesOfBothApisReadTheSameLayout) {
    const auto vk = ParsePixelFormat("R8G8B8A8Unorm");
    const auto vpk = ParsePixelFormat("RGBA8Unorm");
    EXPECT_TRUE(vk && vpk && SameLayout(*vk, *vpk));
    EXPECT_TRUE(vk->bytes == 4 && vk->channels == 4 && vk->kind == PixelFormat::Kind::Unorm);
    const auto bgra = ParsePixelFormat("B8G8R8A8Srgb");
    EXPECT_TRUE(bgra && bgra->kind == PixelFormat::Kind::Srgb && bgra->order == "bgra");
    EXPECT_TRUE(!SameLayout(*vk, *bgra));  // the order of the channels, the kind
    const auto half = ParsePixelFormat("R16G16B16A16Sfloat");
    EXPECT_TRUE(half && SameLayout(*half, *ParsePixelFormat("RGBA16Float")) && half->bytes == 8);
    EXPECT_TRUE(half->kind == PixelFormat::Kind::Float && half->bits == 16);
    // a depth image sampled as a colour one is the same texels
    EXPECT_TRUE(SameLayout(*ParsePixelFormat("D32Sfloat"), *ParsePixelFormat("R32Float")));
    EXPECT_TRUE(!SameLayout(*ParsePixelFormat("D32Sfloat"), *ParsePixelFormat("R32Uint")));
    // packed and integer layouts are compared by bytes; ones it cannot read are not read
    const auto packed = ParsePixelFormat("A2B10G10R10UnormPack32");
    EXPECT_TRUE(packed && packed->kind == PixelFormat::Kind::Exact && packed->bytes == 4);
    EXPECT_TRUE(!ParsePixelFormat("D32SfloatS8Uint") && !ParsePixelFormat("Bc1RgbaUnormBlock") && !ParsePixelFormat(""));
}

TEST(ShadowPixels, UnormErrorIsTwoOver255)
{
    const PixelFormat f = *ParsePixelFormat("RGBA8Unorm");
    std::vector<uint8_t> a(4 * 4, 100), b = a;
    PixelStats s = ComparePixels(f, a.data(), b.data(), 2, 2);
    EXPECT_TRUE(s.differing == 0 && s.maxError == 0 && s.Psnr() == 99.0);
    b[0] = 102;  // 2/255: inside
    s = ComparePixels(f, a.data(), b.data(), 2, 2);
    EXPECT_TRUE(s.differing == 0 && s.maxError > 0.0078 && s.maxError < 0.0079);
    b[5] = 103;  // 3/255: out, one texel of four
    s = ComparePixels(f, a.data(), b.data(), 2, 2);
    EXPECT_TRUE(s.differing == 1 && s.Percent() == 25.0);
    EXPECT_TRUE(s.Psnr() > 30 && s.Psnr() < 60);
}

TEST(ShadowPixels, Unorm16ErrorIsInSixteenBitSteps) {
    const PixelFormat f = *ParsePixelFormat("R16Unorm");
    uint16_t a[2] = {30000, 30000}, b[2] = {30032, 30033};  // 32 steps: inside; 33: out
    EXPECT_TRUE(ComparePixels(f, reinterpret_cast<uint8_t*>(a), reinterpret_cast<uint8_t*>(b), 1, 1).differing == 0);
    EXPECT_TRUE(ComparePixels(f, reinterpret_cast<uint8_t*>(a + 1), reinterpret_cast<uint8_t*>(b + 1), 1, 1).differing == 1);
    uint16_t c = 30000 + 400;  // 400 steps (under 2/255 of the range, which the 8-bit rule would accept)
    EXPECT_TRUE(ComparePixels(f, reinterpret_cast<uint8_t*>(a), reinterpret_cast<uint8_t*>(&c), 1, 1).differing == 1);
}

TEST(ShadowPixels, FloatErrorIsRelative) {
    const PixelFormat f = *ParsePixelFormat("R32Float");
    float a[3] = {1000.0f, 0.0f, 1.0f}, b[3] = {1000.5f, 1e-7f, 1.01f};
    const PixelStats s = ComparePixels(f, reinterpret_cast<uint8_t*>(a), reinterpret_cast<uint8_t*>(b), 3, 1);
    EXPECT_TRUE(s.differing == 1);  // 1000 vs 1000.5 is 5e-4 relative, 0 vs 1e-7 is under 1e-6: only 1 vs 1.01
    const PixelFormat h = *ParsePixelFormat("RG16Float");
    const uint16_t one = 0x3c00, two = 0x4000;  // 1.0, 2.0
    uint16_t ha[2] = {one, one}, hb[2] = {one, two};
    EXPECT_TRUE(ComparePixels(h, reinterpret_cast<uint8_t*>(ha), reinterpret_cast<uint8_t*>(hb), 1, 1).differing == 1);
    EXPECT_TRUE(ComparePixels(h, reinterpret_cast<uint8_t*>(ha), reinterpret_cast<uint8_t*>(ha), 1, 1).differing == 0);
}

TEST(ShadowPixels, ExactLayoutsDifferByOneBit) {
    const PixelFormat f = *ParsePixelFormat("A2B10G10R10UnormPack32");
    uint32_t a = 0x12345678, b = 0x12345679;
    EXPECT_TRUE(ComparePixels(f, reinterpret_cast<uint8_t*>(&a), reinterpret_cast<uint8_t*>(&b), 1, 1).differing == 1);
    EXPECT_TRUE(ComparePixels(f, reinterpret_cast<uint8_t*>(&a), reinterpret_cast<uint8_t*>(&a), 1, 1).differing == 0);
}

TEST(ShadowPixels, TheRegionIsTheViewportAndTheScissorInsideTheSurface) {
    const float vp[4] = {10.4f, 20.0f, 100.2f, 50.0f};
    const int32_t sc[4] = {0, 0, 60, 1000};
    PixelRect r = DrawRegion(true, vp, true, sc, 640, 480);
    EXPECT_TRUE(r.x == 10 && r.y == 20 && r.w == 50 && r.h == 50);  // x: 10.4 floor 10, scissor ends at 60
    r = DrawRegion(false, vp, false, sc, 640, 480);
    EXPECT_TRUE(r.x == 0 && r.y == 0 && r.w == 640 && r.h == 480);
    const int32_t outside[4] = {700, 0, 10, 10};
    EXPECT_TRUE(DrawRegion(false, vp, true, outside, 640, 480).empty());
    const float big[4] = {-50, -50, 5000, 5000};
    r = DrawRegion(true, big, false, sc, 64, 32);
    EXPECT_TRUE(r.x == 0 && r.w == 64 && r.h == 32);
}

TEST(ShadowPixels, CropAndExpandAreInverse) {
    std::vector<uint8_t> surface(8 * 4 * 2);
    for (size_t i = 0; i < surface.size(); ++i) {
        surface[i] = uint8_t(i);
    }
    const PixelRect rect{2, 1, 3, 2};
    PixelImage image;
    image.x = rect.x, image.y = rect.y, image.width = rect.w, image.height = rect.h;
    image.surfaceWidth = 8, image.surfaceHeight = 4;
    image.texels = CropRect(surface.data(), 8, 2, rect);
    EXPECT_TRUE(image.texels.size() == 3 * 2 * 2);
    EXPECT_TRUE(image.texels[0] == surface[(1 * 8 + 2) * 2] && image.texels[6] == surface[(2 * 8 + 2) * 2]);
    const std::vector<uint8_t> full = ExpandRect(image, 2);
    EXPECT_TRUE(full.size() == surface.size());
    EXPECT_TRUE(full[(1 * 8 + 2) * 2] == surface[(1 * 8 + 2) * 2] && full[0] == 0 && full[(3 * 8 + 7) * 2] == 0);
}

TEST(ShadowPixels, ScheduleCapturesOnePictureEveryInterval) {
    CaptureSchedule s(10.0, 2.0);
    EXPECT_TRUE(!s.Advance(5, 0.0).started);   // first call: the interval starts
    EXPECT_TRUE(!s.Advance(5, 20.0).started);  // same picture: nothing begins mid-picture
    auto step = s.Advance(6, 5.0);
    EXPECT_TRUE(!step.started && !step.ended);
    step = s.Advance(7, 10.0);
    EXPECT_TRUE(step.started && !step.ended && s.Active() && s.Id() == 1);
    EXPECT_TRUE(s.Capturing(11.9) && !s.Capturing(12.0));  // the budget
    step = s.Advance(7, 11.0);
    EXPECT_TRUE(!step.started && !step.ended);
    step = s.Advance(8, 12.5);
    EXPECT_TRUE(step.ended && !step.started && !s.Active());
    step = s.Advance(9, 19.9);
    EXPECT_TRUE(!step.started);
    step = s.Advance(10, 20.0);
    EXPECT_TRUE(step.started && s.Id() == 2);
    CaptureSchedule off(0.0, 2.0);
    EXPECT_TRUE(!off.Advance(1, 0).started && !off.Advance(2, 1000).started && !off.Capturing(1000));
    EXPECT_TRUE(CaptureSchedule::ParseInterval(nullptr) == 10.0 && CaptureSchedule::ParseInterval("0") == 0.0);
    EXPECT_TRUE(CaptureSchedule::ParseInterval("2.5") == 2.5 && CaptureSchedule::ParseInterval("junk") == 10.0);
    EXPECT_TRUE(CaptureSchedule::ParseInterval("-3") == 10.0);
}

Record CapturedDraw(uint64_t seq, uint64_t rt, uint8_t vkValue, uint8_t vpkValue) {
    Record r;
    r.seq = seq;
    r.op = Op::Draw;
    r.vk.status = r.vpk.status = Status::Drawn;
    r.vk.hash[size_t(Stage::Ps)] = r.vpk.hash[size_t(Stage::Ps)] = 0xabc;
    r.pixels = std::make_shared<PixelCapture>();
    PixelTarget& t = r.pixels->color[0];
    t.used = true;
    t.address = rt;
    for (PixelImage* image : {&t.post, &t.vpkPost}) {
        image->width = 2, image->height = 2, image->surfaceWidth = 8, image->surfaceHeight = 8;
    }
    t.post.format = "R8G8B8A8Unorm";
    t.vpkPost.format = "RGBA8Unorm";
    t.post.texels.assign(16, vkValue);
    t.vpkPost.texels.assign(16, vpkValue);
    return r;
}

TEST(ShadowPixelAggregator, DivergentDrawsAreLoggedWithTheirRecordDiffAndTheFirstIsMarked) {
    std::vector<std::string> lines;
    PixelAggregator agg([&](const std::string& l) { lines.push_back(l); });
    agg.Begin();
    agg.Submit(CapturedDraw(1, 0x1000, 50, 50));
    Record bad = CapturedDraw(2, 0x1000, 50, 90);
    bad.vpk.count = 7;  // a difference of the resolved state as well
    agg.Submit(bad);
    agg.Submit(CapturedDraw(3, 0x1000, 50, 200));
    Record skipped = CapturedDraw(4, 0x2000, 1, 1);
    skipped.pixels->vpkSkip = "pipeline compiling";
    agg.Submit(skipped);
    Record other = CapturedDraw(5, 0x2000, 1, 1);
    other.pixels->vkSkip = "msaa";
    agg.Submit(other);
    agg.End();
    EXPECT_TRUE(lines.size() == 4);
    EXPECT_TRUE(lines[0] == "ASTRO_PIXEL diff seq=2 op=draw pgm=0xabc rt=0x1000 fmt=R8G8B8A8Unorm 2x2 pct=100.000 "
                            "maxerr=0.1569 psnr=16.1 first_divergent=yes");
    EXPECT_TRUE(lines[1] == "ASTRO_PIXEL record_diff seq=2 field=count vk=0 vpk=7");
    EXPECT_TRUE(lines[2].find("seq=3 ") != std::string::npos && lines[2].find("first_divergent=no") != std::string::npos);
    EXPECT_TRUE(lines[3] == "ASTRO_PIXEL summary draws=5 compared=3 equal=1 diverged=2 skipped=2(vk:msaa=1,vpk:pipeline_compiling=1)");
}

TEST(ShadowPixelAggregator, ADrawOneSideDidNotDrawIsSkippedWithItsReason) {
    std::vector<std::string> lines;
    PixelAggregator agg([&](const std::string& l) { lines.push_back(l); });
    agg.Begin();
    Record r = CapturedDraw(1, 0x1000, 1, 200);
    r.vpk.status = Status::Skipped;
    r.vpk.reason = "texture unavailable";
    agg.Submit(r);
    agg.End();
    EXPECT_TRUE(lines.size() == 1 && lines[0].find("skipped=1(vpk:skip_texture_unavailable=1)") != std::string::npos);
}

TEST(ShadowPixelAggregator, DifferentFormatsAreSkippedNotCompared) {
    std::vector<std::string> lines;
    PixelAggregator agg([&](const std::string& l) { lines.push_back(l); });
    agg.Begin();
    Record r = CapturedDraw(1, 0x1000, 1, 200);
    r.pixels->color[0].vpkPost.format = "BGRA8Unorm";
    agg.Submit(r);
    agg.End();
    EXPECT_TRUE(lines.size() == 1 && lines[0].find("compared=0 equal=0 diverged=0 skipped=1(format_differs=1)") != std::string::npos);
}

TEST(ShadowPixelAggregator, ARectangleAtAnotherPlaceIsNotCompared) {
    std::vector<std::string> lines;
    PixelAggregator agg([&](const std::string& l) { lines.push_back(l); });
    agg.Begin();
    Record r = CapturedDraw(1, 0x1000, 1, 1);
    r.pixels->color[0].vpkPost.x = 2;
    agg.Submit(r);
    agg.End();
    EXPECT_TRUE(lines.size() == 1 && lines[0].find("compared=0 equal=0 diverged=0 skipped=1(size_differs=1)") != std::string::npos);
}

TEST(ShadowPixelAggregator, ADrawTheShadowDidNotAnswerIsCounted) {
    std::vector<std::string> lines;
    PixelAggregator agg([&](const std::string& l) { lines.push_back(l); });
    agg.Begin();
    agg.Unanswered("shadow threw or off");
    agg.End();
    EXPECT_TRUE(lines.size() == 1 && lines[0].find("draws=1 compared=0 equal=0 diverged=0 skipped=1(shadow_threw_or_off=1)") != std::string::npos);
}

TEST(ShadowPixelAggregator, LineCapAndRestartPerCapture) {
    std::vector<std::string> lines;
    PixelAggregator agg([&](const std::string& l) { lines.push_back(l); }, 3);
    agg.Begin();
    for (uint64_t i = 0; i < 10; ++i) {
        agg.Submit(CapturedDraw(i, 0x1000 + i, 0, 255));
    }
    EXPECT_TRUE(lines.size() == 4 && lines[3].find("diff cap reached") != std::string::npos);
    EXPECT_TRUE(agg.Snapshot().diverged == 10);
    agg.Begin();
    EXPECT_TRUE(agg.Snapshot().draws == 0);
    agg.Submit(CapturedDraw(11, 0x1000, 0, 255));
    EXPECT_TRUE(lines.back().find("first_divergent=yes") != std::string::npos);  // marks start again
}

} // namespace
