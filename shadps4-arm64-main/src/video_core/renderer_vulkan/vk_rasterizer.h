// SPDX-FileCopyrightText: Copyright 2024 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <memory>
#include <utility>
#include <vector>

#include <boost/container/small_vector.hpp>

#include "common/recursive_lock.h"
#include "common/shared_first_mutex.h"
#include "video_core/buffer_cache/buffer_cache.h"
#include "video_core/page_manager.h"
#include "video_core/renderer_vulkan/gpu_bench.h"
#include "video_core/renderer_vulkan/vk_pipeline_cache.h"
#include "video_core/texture_cache/texture_cache.h"

namespace AmdGpu {
struct Liverpool;
}

namespace Core {
class MemoryManager;
}

namespace Vulkan {

class Scheduler;
class RenderState;
class GraphicsPipeline;

class Rasterizer {
public:
    explicit Rasterizer(const Instance& instance, Scheduler& scheduler,
                        AmdGpu::Liverpool* liverpool);
    ~Rasterizer();

    [[nodiscard]] Scheduler& GetScheduler() noexcept {
        return scheduler;
    }

    /// Handles DMA writes that land on a depth target's HTILE surface. Returns true when the
    /// write was consumed as a depth clear.
    bool TryHtileClear(VAddr address, std::span<const u32> htile_words);

    /// Logs the next `count` guest draws, dispatches and markers. Debugging aid.
    static void StartDrawTrace(s32 count);

    [[nodiscard]] VideoCore::BufferCache& GetBufferCache() noexcept {
        return buffer_cache;
    }

    [[nodiscard]] VideoCore::TextureCache& GetTextureCache() noexcept {
        return texture_cache;
    }

    void Draw(bool is_indexed, u32 index_offset = 0);
    void DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                      VAddr count_address);

    void DispatchDirect();
    void DispatchIndirect(VAddr address, u32 offset, u32 size);

    void ScopeMarkerBegin(const std::string_view& str, bool from_guest = false);
    void ScopeMarkerEnd(bool from_guest = false);
    void ScopedMarkerInsert(const std::string_view& str, bool from_guest = false);
    void ScopedMarkerInsertColor(const std::string_view& str, const u32 color,
                                 bool from_guest = false);

    void FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds);
    void CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds);
    u32 ReadDataFromGds(u32 gsd_offset);
    bool InvalidateMemory(VAddr addr, u64 size);
    bool ReadMemory(VAddr addr, u64 size);
    bool IsMapped(VAddr addr, u64 size);
    void MapMemory(VAddr addr, u64 size);
    void UnmapMemory(VAddr addr, u64 size);

    void CpSync();
    u64 Flush();
    void Finish();
    void OnSubmit();

    PipelineCache& GetPipelineCache() {
        return pipeline_cache;
    }

    template <typename Func>
    void ForEachMappedRangeInRange(VAddr addr, u64 size, Func&& func) {
        const auto range = decltype(mapped_ranges)::interval_type::right_open(addr, addr + size);
        Common::RecursiveSharedLock lock{mapped_ranges_mutex};
        for (const auto& mapped_range : (mapped_ranges & range)) {
            func(mapped_range);
        }
    }

private:
    void PrepareRenderState(const GraphicsPipeline* pipeline);
    RenderState BeginRendering(const GraphicsPipeline* pipeline);
    /// For a pass with no colour or depth target: how far the draws' scissors (and, for plain
    /// triangles, their viewports) reach, rounded up to whole 32-pixel tiles.
    std::pair<u32, u32> AttachmentlessExtent() const;
    void Resolve();
    void DepthStencilCopy(bool is_depth, bool is_stencil);
    void EliminateFastClear();

    void UpdateDynamicState(const GraphicsPipeline* pipeline, bool is_indexed) const;
    void UpdateViewportScissorState() const;
    void UpdateDepthStencilState() const;
    void UpdatePrimitiveState(bool is_indexed) const;
    void UpdateRasterizationState() const;
    void UpdateColorBlendingState(const GraphicsPipeline* pipeline) const;

    bool FilterDraw();

    /// The passes a draw is made in: for each, the colour targets (a bit each) it leaves out.
    /// One pass that leaves nothing out, unless two of the draw's targets are one surface.
    boost::container::small_vector<u8, 4> SharedTargetPasses(u8 mrt_mask) const;

    void BindBuffers(const Shader::Info& stage, Shader::Backend::Bindings& binding,
                     Shader::PushData& push_data);
    void BindTextures(const Shader::Info& stage, Shader::Backend::Bindings& binding);
    bool BindResources(const Pipeline* pipeline);
    std::unique_ptr<VideoCore::Buffer> IsolateReadConstGuestBuffer(VAddr addr, u64 size);
    void RetireIsolatedReadConstSnapshots();

    /// Set while a draw is made in more than one pass (SharedTargetPasses).
    bool in_target_passes{};

    /// After a draw began a render pass: what the pass's pipelines are made for and which
    /// images it draws to, for the draws after it (PipelineForOpenPass).
    void NoteOpenPass(const GraphicsPipeline* pipeline);
    /// Whether the GPU test (gpu_bench.h) leaves this draw out now.
    bool BenchLeavesOut(GpuBench::Mode mode, const GraphicsPipeline* pipeline, u64 vertices,
                        bool& pixels_out) const;
    /// With `pixels_out`, the draw about to be made runs its vertices only (GpuBench). Answers
    /// whether rasterizer discard was on before, for BenchPixelsBack after the draw.
    bool BenchPixelsOut(bool pixels_out);
    void BenchPixelsBack(bool pixels_out, bool discard_before);
    /// A draw's depth, blend and pixel shader state, for the shader test's report.
    std::string DescribeDrawState(const GraphicsPipeline* pipeline) const;
    /// A draw whose targets are some of those of the pass that is open (the same images, none
    /// cleared, the same size), or none at all, can be made in that pass instead of ending it:
    /// on a GPU that renders in tiles, ending a pass writes all its targets out to memory and
    /// the next one reads them back in. Answers with a pipeline made for the pass's targets
    /// that writes to none the draw has not got itself, or nullptr when the draw needs a pass
    /// of its own (or that pipeline is not made yet). SHADPS4_MERGE_PASSES=0 turns it off.
    const GraphicsPipeline* PipelineForOpenPass(const GraphicsPipeline* pipeline,
                                                const RenderState& state);

    struct OpenPass {
        u64 serial{~0ull};
        PipelineCache::OpenPassTargets targets{};
        std::array<VideoCore::ImageId, AmdGpu::NUM_COLOR_BUFFERS + 1> images{};
        u32 num_images{};
    };
    OpenPass open_pass{};
    /// Set while the draw being made is made in a pass with more targets than its own.
    bool in_open_pass{};

    void ResetBindings() {
        for (auto& image_id : bound_images) {
            texture_cache.GetImage(image_id).binding = {};
        }
        bound_images.clear();
    }

    bool IsComputeMetaClear(const Pipeline* pipeline);
    bool IsComputeImageCopy(const Pipeline* pipeline);
    bool IsComputeImageClear(const Pipeline* pipeline);

private:
    friend class VideoCore::BufferCache;

    const Instance& instance;
    Scheduler& scheduler;
    VideoCore::PageManager page_manager;
    VideoCore::BufferCache buffer_cache;
    VideoCore::TextureCache texture_cache;
    AmdGpu::Liverpool* liverpool;
    Core::MemoryManager* memory;
    boost::icl::interval_set<VAddr> mapped_ranges;
    Common::SharedFirstMutex mapped_ranges_mutex;
    PipelineCache pipeline_cache;

    using RenderTargetInfo = std::pair<VideoCore::ImageId, VideoCore::TextureCache::ImageDesc>;
    std::array<RenderTargetInfo, AmdGpu::NUM_COLOR_BUFFERS> cb_descs;
    std::pair<VideoCore::ImageId, VideoCore::TextureCache::ImageDesc> db_desc;
    boost::container::small_vector<vk::DescriptorImageInfo,
                                   Shader::NUM_IMAGES + Shader::NUM_SAMPLERS>
        image_infos;
    boost::container::static_vector<vk::DescriptorBufferInfo, Shader::NUM_BUFFERS> buffer_infos;
    boost::container::small_vector<VideoCore::ImageId, Shader::NUM_IMAGES> bound_images;

    u32 set_write_index{};
    Pipeline::DescriptorWrites set_writes;
    Pipeline::BufferBarriers buffer_barriers;
    Shader::PushData push_data;

    using BufferBindingInfo = std::tuple<VideoCore::BufferId, AmdGpu::Buffer, u64>;
    boost::container::static_vector<BufferBindingInfo, Shader::NUM_BUFFERS> buffer_bindings;
    std::vector<std::unique_ptr<VideoCore::Buffer>> isolated_readconst_buffers;
    u32 isolated_readconst_hits{};
    using ImageBindingInfo = std::pair<VideoCore::ImageId, VideoCore::TextureCache::ImageDesc>;
    boost::container::small_vector<ImageBindingInfo, Shader::NUM_IMAGES> image_bindings;
    bool fault_process_pending{};
    bool attachment_feedback_loop{};
};

} // namespace Vulkan
