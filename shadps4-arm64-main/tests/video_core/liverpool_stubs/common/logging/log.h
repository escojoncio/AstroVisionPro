#pragma once
#include <utility>
namespace Log { enum class Class { Render, Render_Vulkan, Lib_GnmDriver, Kernel }; }
#define LOG_TRACE(c, ...) ((void)0)
#define LOG_DEBUG(c, ...) ((void)0)
#define LOG_INFO(c, ...) ((void)0)
#define LOG_WARNING(c, ...) ((void)0)
#define LOG_ERROR(c, ...) ((void)0)
#define LOG_CRITICAL(c, ...) ((void)0)
