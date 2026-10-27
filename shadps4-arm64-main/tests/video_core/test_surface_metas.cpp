// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <array>

#include <gtest/gtest.h>

#include "video_core/surface_metas.h"

namespace {

using VideoCore::SurfaceMetas;
using Type = SurfaceMetas::Type;

TEST(SurfaceMetas, NewSurfaceStartsClearedAndIsConsumedPerSlice) {
    SurfaceMetas metas;
    metas.Register(Type::CMask, 0x1000);
    EXPECT_TRUE(metas.IsMeta(0x1000));
    EXPECT_TRUE(metas.IsCleared(0x1000, 0));
    EXPECT_TRUE(metas.IsCleared(0x1000, 1));
    EXPECT_TRUE(metas.Touch(0x1000, 0, false));
    EXPECT_FALSE(metas.IsCleared(0x1000, 0));
    EXPECT_TRUE(metas.IsCleared(0x1000, 1));
    // Binding the target again does not clear it again.
    metas.Register(Type::CMask, 0x1000);
    EXPECT_FALSE(metas.IsCleared(0x1000, 0));
}

TEST(SurfaceMetas, UnknownAddressesAreNotMeta) {
    SurfaceMetas metas;
    EXPECT_TRUE(metas.Empty());
    EXPECT_FALSE(metas.IsMeta(0x2000));
    EXPECT_FALSE(metas.IsCleared(0x2000, 0));
    EXPECT_FALSE(metas.ClearAll(0x2000));
    EXPECT_FALSE(metas.Touch(0x2000, 0, true));
}

TEST(SurfaceMetas, ClearAllMarksEverySlice) {
    SurfaceMetas metas;
    metas.Register(Type::CMask, 0x1000);
    metas.Touch(0x1000, 0, false);
    metas.Touch(0x1000, 1, false);
    EXPECT_TRUE(metas.ClearAll(0x1000));
    EXPECT_TRUE(metas.IsCleared(0x1000, 0));
    EXPECT_TRUE(metas.IsCleared(0x1000, 1));
}

TEST(SurfaceMetas, EraseRangeForgetsTheSurfacesInIt) {
    SurfaceMetas metas;
    metas.Register(Type::CMask, 0x1000);
    metas.Register(Type::HTile, 0x2000);
    metas.Register(Type::CMask, 0x3000);
    metas.Touch(0x3000, 0, false);
    // [start, end): the end is not included.
    EXPECT_FALSE(metas.Empty());
    metas.EraseRange(0x1000, 0x3000);
    EXPECT_FALSE(metas.IsMeta(0x1000));
    EXPECT_FALSE(metas.IsMeta(0x2000));
    EXPECT_TRUE(metas.IsMeta(0x3000));
    EXPECT_FALSE(metas.IsCleared(0x3000, 0));
    // A surface mapped there again starts cleared.
    metas.Register(Type::CMask, 0x1000);
    EXPECT_TRUE(metas.IsCleared(0x1000, 0));
    metas.EraseRange(0x5000, 0x5000);
    metas.EraseRange(0x6000, 0x7000);
    EXPECT_TRUE(metas.IsMeta(0x1000));
    EXPECT_TRUE(metas.IsMeta(0x3000));
}

TEST(SurfaceMetas, HtileClearNeedsMostlyClearedEntries) {
    SurfaceMetas metas;
    metas.Register(Type::HTile, 0x3000);
    metas.Register(Type::CMask, 0x4000);
    metas.Touch(0x3000, 0, false);
    // A fill with a cleared zmask entry.
    const u32 cleared = 0x12345670;
    EXPECT_TRUE(metas.TryHtileClear(0x3000, std::span{&cleared, 1}));
    EXPECT_TRUE(metas.IsCleared(0x3000, 0));
    // A template: padding is ignored, half or more cleared counts, occluded tiles included.
    metas.Touch(0x3000, 0, false);
    const std::array<u32, 5> tmpl{0x10, 0x20, 0x1, 0x3, 0};
    EXPECT_TRUE(metas.TryHtileClear(0x3000, tmpl));
    // Mostly written entries that are not cleared: not a clear.
    metas.Touch(0x3000, 0, false);
    const std::array<u32, 3> encoded{0x1, 0x2, 0x30};
    EXPECT_FALSE(metas.TryHtileClear(0x3000, encoded));
    EXPECT_FALSE(metas.IsCleared(0x3000, 0));
    // Only padding, nothing, or a surface that is not HTILE.
    const std::array<u32, 2> padding{0, 0};
    EXPECT_FALSE(metas.TryHtileClear(0x3000, padding));
    EXPECT_FALSE(metas.TryHtileClear(0x3000, {}));
    EXPECT_FALSE(metas.TryHtileClear(0x4000, std::span{&cleared, 1}));
    EXPECT_FALSE(metas.TryHtileClear(0x5000, std::span{&cleared, 1}));
}

} // namespace
