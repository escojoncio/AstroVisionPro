#pragma once
#include <cstdlib>
#define ASSERT(c) do { if (!(c)) std::abort(); } while (0)
#define ASSERT_MSG(c, ...) do { if (!(c)) std::abort(); } while (0)
#define DEBUG_ASSERT(c) ((void)0)
#define DEBUG_ASSERT_MSG(c, ...) ((void)0)
#define UNREACHABLE() std::abort()
#define UNREACHABLE_MSG(...) std::abort()
