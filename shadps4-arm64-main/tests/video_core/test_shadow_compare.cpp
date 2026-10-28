// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "video_core/shadow_compare.h"

namespace {

using namespace VideoCore::Shadow;

Record DrawRecord() {
    Record r;
    r.seq = 7;
    r.op = Op::Draw;
    for (Side* s : {&r.vk, &r.vpk}) {
        s->status = Status::Drawn;
        s->color[0].used = true;
        s->color[0].address = 0x1000;
        s->color[0].width = 1920;
        s->color[0].height = 1080;
        s->color[0].pitch = 1920;
        s->color[0].dataFormat = 10;
        s->color[0].tileMode = 13;
        s->color[0].sliceCount = 1;
        s->color[0].samples = 1;
        s->indexAddress = 0x2000;
        s->indexBytes = 600;
        s->count = 300;
        s->instances = 1;
        s->topology = 2;
        s->hash[size_t(Stage::Vs)] = 0xaaaa;
        s->hash[size_t(Stage::Ps)] = 0xbbbb;
        s->buffers = {{Stage::Vs, 0x5000, 256, 16, false}, {Stage::Ps, 0x6000, 64, 0, false}};
        s->viewportValid = true;
        s->viewport[0] = 0, s->viewport[1] = 0, s->viewport[2] = 1920, s->viewport[3] = 1080, s->viewport[5] = 1;
        s->stateValid = true;
        s->depthFunc = 7;
    }
    r.vk.color[0].hostFormat = "R8G8B8A8Srgb";
    r.vpk.color[0].hostFormat = "RGBA8Srgb";
    return r;
}

bool Has(const Outcome& o, const std::string& field) {
    for (const Diff& d : o.diffs) {
        if (d.field == field) {
            return true;
        }
    }
    return false;
}

const Diff* Find(const Outcome& o, const std::string& field) {
    for (const Diff& d : o.diffs) {
        if (d.field == field) {
            return &d;
        }
    }
    return nullptr;
}

TEST(ShadowCompare, FormatNamesOfBothApisMeetInOneText) {
    EXPECT_TRUE(NormalizeFormat("R8G8B8A8Unorm") == NormalizeFormat("RGBA8Unorm"));
    EXPECT_TRUE(NormalizeFormat("B8G8R8A8Srgb") == NormalizeFormat("RGBA8Srgb"));
    EXPECT_TRUE(NormalizeFormat("R16G16B16A16Sfloat") == NormalizeFormat("RGBA16Float"));
    EXPECT_TRUE(NormalizeFormat("A2B10G10R10UnormPack32") == NormalizeFormat("RGB10A2Unorm"));
    EXPECT_TRUE(NormalizeFormat("B10G11R11UfloatPack32") == NormalizeFormat("RG11B10Float"));
    EXPECT_TRUE(NormalizeFormat("B5G6R5UnormPack16") == NormalizeFormat("B5G6R5Unorm"));
    EXPECT_TRUE(NormalizeFormat("D32SfloatS8Uint") == NormalizeFormat("D32FloatS8"));
    EXPECT_TRUE(NormalizeFormat("D24UnormS8Uint") == NormalizeFormat("D24UnormS8"));
    EXPECT_TRUE(NormalizeFormat("D32Sfloat") == NormalizeFormat("D32Float"));
    EXPECT_TRUE(NormalizeFormat("Bc1RgbaUnormBlock") == NormalizeFormat("BC1"));
    EXPECT_TRUE(NormalizeFormat("Bc7SrgbBlock") == NormalizeFormat("BC7Srgb"));
    EXPECT_TRUE(NormalizeFormat("Astc4x4SrgbBlock") == NormalizeFormat("Astc4x4Srgb"));
    // different formats stay different: the sRGB-ness, the width, the kind, the depth
    EXPECT_TRUE(NormalizeFormat("R8G8B8A8Unorm") != NormalizeFormat("RGBA8Srgb"));
    EXPECT_TRUE(NormalizeFormat("R8G8B8A8Unorm") != NormalizeFormat("RGBA16Unorm"));
    EXPECT_TRUE(NormalizeFormat("R32Sfloat") != NormalizeFormat("R32Uint"));
    EXPECT_TRUE(NormalizeFormat("D32Sfloat") != NormalizeFormat("D32FloatS8"));
    EXPECT_TRUE(NormalizeFormat("") == "none");
}

TEST(ShadowCompare, SameResolutionHasNoDifferences) {
    const Outcome o = Compare(DrawRecord());
    EXPECT_TRUE(o.compared);
    EXPECT_TRUE(o.diffs.empty());
}

TEST(ShadowCompare, ABufferBoundSmallerIsFoundWithItsProgram) {
    Record r = DrawRecord();
    r.vpk.buffers[0].size = 128;  // the host cut the V# short
    const Outcome o = Compare(r);
    const Diff* d = Find(o, "buf.vs.size");
    EXPECT_TRUE(d != nullptr);
    EXPECT_TRUE(o.diffs.size() == 1);
    EXPECT_TRUE(d && d->vk == "256" && d->vpk == "128");
    EXPECT_TRUE(d && d->pgm == 0xaaaa);  // the vertex stage's program
}

TEST(ShadowCompare, OrderOfBindingsIsNotADifference) {
    Record r = DrawRecord();
    std::swap(r.vpk.buffers[0], r.vpk.buffers[1]);
    EXPECT_TRUE(Compare(r).diffs.empty());
    r.vk.textures = {{Stage::Ps, 0x9000, 10, 0, 9, 13, 0, 0, 64, 64, {4, 5, 6, 7}, false, true, "R8G8B8A8Unorm", 64, 64},
                     {Stage::Ps, 0x8000, 10, 0, 9, 13, 0, 0, 32, 32, {4, 5, 6, 7}, false, true, "R8G8B8A8Unorm", 32, 32}};
    r.vpk.textures = {r.vk.textures[1], r.vk.textures[0]};
    r.vpk.textures[0].hostFormat = "RGBA8Unorm";
    r.vpk.textures[1].hostFormat = "RGBA8Unorm";
    r.vk.samplers = {{Stage::Ps, 0, 0, 0, 1, 1, 1, false, false}, {Stage::Ps, 2, 2, 2, 0, 0, 0, true, false}};
    r.vpk.samplers = {r.vk.samplers[1], r.vk.samplers[0]};
    EXPECT_TRUE(Compare(r).diffs.empty());
}

TEST(ShadowCompare, MissingAndWrongBindingsAreFound) {
    Record r = DrawRecord();
    r.vpk.buffers.pop_back();
    r.vk.textures = {{Stage::Ps, 0x9000, 10, 0, 9, 13, 0, 0, 64, 64, {4, 5, 6, 7}, false, true, "R8G8B8A8Unorm", 64, 64}};
    r.vpk.textures = r.vk.textures;
    r.vpk.textures[0].hostFormat = "BGRA8Srgb";
    r.vpk.textures[0].dstSel = {6, 5, 4, 7};
    r.vk.samplers = {{Stage::Ps, 0, 0, 0, 1, 1, 1, false, false}};
    r.vpk.samplers = {{Stage::Ps, 2, 0, 0, 1, 1, 1, false, false}};
    const Outcome o = Compare(r);
    EXPECT_TRUE(Has(o, "buf.ps.only_vk"));
    EXPECT_TRUE(Has(o, "tex.ps.host_format"));
    EXPECT_TRUE(Has(o, "tex.ps.swizzle"));
    EXPECT_TRUE(Has(o, "sampler.ps"));
    EXPECT_TRUE(o.diffs.size() == 4);
}

TEST(ShadowCompare, TargetsDepthAndFixedFunction) {
    Record r = DrawRecord();
    r.vpk.color[0].hostFormat = "RGBA8Unorm";  // sRGB lost
    r.vpk.color[0].height = 1088;
    r.vpk.viewport[2] = 1919.8f;  // within the tolerance
    r.vpk.viewport[3] = 1070;
    r.vpk.depthTest = true;
    r.vk.color[1].used = true;
    Outcome o = Compare(r);
    EXPECT_TRUE(Has(o, "color0.host_format"));
    EXPECT_TRUE(Has(o, "color0.height"));
    EXPECT_TRUE(Has(o, "color1.used"));
    EXPECT_TRUE(Has(o, "viewport.height"));
    EXPECT_TRUE(!Has(o, "viewport.width"));
    EXPECT_TRUE(Has(o, "state.depth_test"));
}

TEST(ShadowCompare, ScissorIsComparedInsideTheTargets) {
    Record r = DrawRecord();
    r.vk.scissorValid = r.vpk.scissorValid = true;
    r.vk.scissor[2] = 16384, r.vk.scissor[3] = 16384;  // the registers' default rectangle
    r.vpk.scissor[2] = 1920, r.vpk.scissor[3] = 1080;  // clipped to the target
    EXPECT_TRUE(Compare(r).diffs.empty());
    r.vpk.scissor[2] = 1000;
    EXPECT_TRUE(Has(Compare(r), "scissor.width"));
}

TEST(ShadowCompare, SkippedByOneSideIsTheDifferenceAndNothingElse) {
    Record r = DrawRecord();
    r.vpk.status = Status::Skipped;
    r.vpk.reason = "pipeline compiling";
    r.vpk.count = 5;  // not compared: it was not drawn
    Outcome o = Compare(r);
    EXPECT_TRUE(o.diffs.size() == 1);
    EXPECT_TRUE(Has(o, "status.vk_drawn.vpk_skip_pipeline_compiling"));
    r.vk.status = Status::Skipped;
    r.vk.reason = "no pipeline";
    o = Compare(r);
    EXPECT_TRUE(o.bothSkipped && o.diffs.empty());
    r = DrawRecord();
    r.vpk.status = Status::NotRun;
    o = Compare(r);
    EXPECT_TRUE(!o.compared && o.diffs.empty());
}

TEST(ShadowCompare, DispatchAndDma) {
    Record r;
    r.op = Op::DispatchDirect;
    for (Side* s : {&r.vk, &r.vpk}) {
        s->status = Status::Drawn;
        s->hash[size_t(Stage::Cs)] = 0xcccc;
        s->groups = {4, 1, 1};
    }
    r.vpk.groups[0] = 8;
    Outcome o = Compare(r);
    EXPECT_TRUE(o.diffs.size() == 1 && o.diffs[0].field == "groups.x" && o.diffs[0].pgm == 0xcccc);
    Record f;
    f.op = Op::FillBuffer;
    f.vk.status = f.vpk.status = Status::Drawn;
    f.vk.dst = f.vpk.dst = 0x1000;
    f.vk.bytes = 64;
    f.vpk.bytes = 32;
    o = Compare(f);
    EXPECT_TRUE(o.diffs.size() == 1 && o.diffs[0].field == "fill.bytes");
}

TEST(ShadowCompare, VulkanSkippedForItsPipelineIsNotADifference) {
    Record r = DrawRecord();
    r.vk.status = Status::Skipped;
    r.vk.reason = "no graphics pipeline";  // compiling on another thread
    r.vk.hash = {};
    Outcome o = Compare(r);
    EXPECT_TRUE(o.compared && o.hostSkipped && o.diffs.empty());
    r.vk.reason = "resources could not be bound";  // a real difference
    o = Compare(r);
    EXPECT_TRUE(!o.hostSkipped && o.diffs.size() == 1);
    r.vk.reason = "no graphics pipeline";
    r.vpk.status = Status::Skipped;
    o = Compare(r);
    EXPECT_TRUE(o.bothSkipped && !o.hostSkipped);
    Aggregator agg([](const std::string&) {});
    r = DrawRecord();
    r.vk.status = Status::Skipped;
    r.vk.reason = "no compute pipeline";
    agg.Submit(r);
    const Totals t = agg.Snapshot();
    EXPECT_TRUE(t.skippedVk == 1 && t.hostSkipVk == 1 && t.compared == 0 && t.different == 0);
}

TEST(ShadowCompare, TheProgramHashIsComparedAsGiven) {
    Record r = DrawRecord();
    EXPECT_TRUE(Compare(r).diffs.empty());
    r.vk.hash[size_t(Stage::Ps)] = 0xbbbb5;  // a permutation of the host shader mixed in
    const Outcome o = Compare(r);
    EXPECT_TRUE(Has(o, "hash.ps") && o.diffs.size() == 1);
}

TEST(ShadowCompare, BuffersReachedByAPointerAreOnlyComparedWhenBothListThem) {
    Record r = DrawRecord();
    r.vpk.buffers.push_back({Stage::Ps, 0x7000, 0, 0, false, true});  // s_load through a pointer: Vulkan binds nothing
    EXPECT_TRUE(Compare(r).diffs.empty());
    r.vpk.buffers.push_back({Stage::Ps, 0x7100, 64, 0, false, false});  // a V# one is a binding: Vulkan lacks it
    Outcome o = Compare(r);
    EXPECT_TRUE(Has(o, "buf.ps.only_vpk") && o.diffs.size() == 1);
    r.vk.buffers.push_back({Stage::Ps, 0x7000, 32, 0, false, false});  // both list it: compared
    r.vpk.buffers.pop_back();
    o = Compare(r);
    EXPECT_TRUE(Has(o, "buf.ps.size") && o.diffs.size() == 1);
}

TEST(ShadowCompare, FormatsThatGiveTheShaderTheSameBitsAreEqualTheOthersStayDifferent) {
    EXPECT_TRUE(BitIdenticalView("D32Sfloat", "R32Float", false));
    EXPECT_TRUE(BitIdenticalView("R32Float", "D32Sfloat", false));
    EXPECT_TRUE(BitIdenticalView("D16Unorm", "R16Unorm", false));
    EXPECT_TRUE(!BitIdenticalView("D32Sfloat", "R32Uint", false));
    EXPECT_TRUE(!BitIdenticalView("D32Sfloat", "R32Float", true));  // storage: not a depth view
    EXPECT_TRUE(!BitIdenticalView("R8G8B8A8Unorm", "RGBA8Srgb", false));
    EXPECT_TRUE(!BitIdenticalView("A2B10G10R10UnormPack32", "R32Uint", true));
    EXPECT_TRUE(BitIdenticalView("R32Sint", "R32Uint", true));
    EXPECT_TRUE(!BitIdenticalView("R16G16Uint", "R32Uint", true));
    Record r = DrawRecord();
    r.vk.textures = {{Stage::Ps, 0x9000, 4, 7, 9, 13, 0, 0, 64, 64, {4, 5, 6, 7}, false, true, "D32Sfloat", 64, 64}};
    r.vpk.textures = r.vk.textures;
    r.vpk.textures[0].hostFormat = "R32Float";
    EXPECT_TRUE(Compare(r).diffs.empty());
    r.vpk.textures[0].hostFormat = "R32Uint";
    EXPECT_TRUE(Has(Compare(r), "tex.ps.host_format"));
    r.vk.textures[0].hostFormat = "A2B10G10R10UnormPack32";
    r.vk.textures[0].storage = r.vpk.textures[0].storage = true;
    EXPECT_TRUE(Has(Compare(r), "tex.ps.host_format"));
}

TEST(ShadowCompare, ClearedAndDepthUsedDifferencesAreStillReported) {
    Record r = DrawRecord();
    r.vpk.color[0].cleared = true;
    r.vpk.depth.used = true;
    const Outcome o = Compare(r);
    EXPECT_TRUE(Has(o, "color0.cleared") && Has(o, "depth.used"));
}

TEST(ShadowAggregator, FirstThreeInFullThenOnlyCounted) {
    std::vector<std::string> lines;
    Aggregator agg([&](const std::string& l) { lines.push_back(l); });
    for (int i = 0; i < 10; ++i) {
        Record r = DrawRecord();
        r.seq = agg.NextSeq();
        r.vpk.buffers[0].size = 128;
        agg.Submit(r);
    }
    Record other = DrawRecord();
    other.seq = agg.NextSeq();
    other.vpk.hash[size_t(Stage::Ps)] = 0xdddd;  // another program, same field kind
    other.vpk.buffers[0].size = 128;
    agg.Submit(other);
    Record same = DrawRecord();
    same.seq = agg.NextSeq();
    agg.Submit(same);
    EXPECT_TRUE(lines.size() == 3 + 1);  // 3 of (buf.vs.size, vertex program), then only the new hash.ps
    EXPECT_TRUE(lines[0] == "ASTRO_SHADOW diff seq=1 op=draw field=buf.vs.size vk=256 vpk=128 pgm=0xaaaa");
    const Totals t = agg.Snapshot();
    EXPECT_TRUE(t.ops == 12 && t.compared == 12 && t.equal == 1 && t.different == 11);
}

TEST(ShadowAggregator, SummaryEverySixHundredFramesWithTheTopKeys) {
    std::vector<std::string> lines;
    Aggregator agg([&](const std::string& l) { lines.push_back(l); }, {3, 4000, 600, 2});
    for (int i = 0; i < 5; ++i) {
        Record r = DrawRecord();
        r.seq = agg.NextSeq();
        r.vpk.count = 1;
        agg.Submit(r);
    }
    Record r = DrawRecord();
    r.seq = agg.NextSeq();
    r.vpk.instances = 3;
    agg.Submit(r);
    Record skipped = DrawRecord();
    skipped.vk.status = skipped.vpk.status = Status::Skipped;
    skipped.seq = agg.NextSeq();
    agg.Submit(skipped);
    lines.clear();
    agg.Tick(599);
    EXPECT_TRUE(lines.empty());
    agg.Tick(600);
    EXPECT_TRUE(lines.size() == 3);  // the totals and the top 2
    EXPECT_TRUE(lines[0].find("summary frames=600 ops=7 compared=6 equal=0 different=6 skipped_vk=1 skipped_vpk=1 "
                              "skipped_both=1") != std::string::npos);
    EXPECT_TRUE(lines[1] == "ASTRO_SHADOW top rank=1 field=count pgm=0xbbbb count=5 first_seq=1");
    EXPECT_TRUE(lines[2] == "ASTRO_SHADOW top rank=2 field=instances pgm=0xbbbb count=1 first_seq=6");
    lines.clear();
    agg.Tick(700);
    EXPECT_TRUE(lines.empty());
    agg.Tick(1200);
    EXPECT_TRUE(lines.size() == 3);
}

TEST(ShadowAggregator, LineCapStopsTheDiffLinesNotTheCounting) {
    std::vector<std::string> lines;
    Aggregator agg([&](const std::string& l) { lines.push_back(l); }, {3, 4, 600, 30});
    for (uint64_t pgm = 1; pgm <= 10; ++pgm) {
        Record r = DrawRecord();
        r.seq = agg.NextSeq();
        r.vpk.hash[size_t(Stage::Ps)] = pgm;
        r.vk.hash[size_t(Stage::Ps)] = pgm;
        r.vpk.count = 1;
        agg.Submit(r);
    }
    EXPECT_TRUE(lines.size() == 5);  // 4 diff lines and the one line that says so
    EXPECT_TRUE(lines[4].find("diff cap reached") != std::string::npos);
    EXPECT_TRUE(agg.Snapshot().different == 10);
}

} // namespace
