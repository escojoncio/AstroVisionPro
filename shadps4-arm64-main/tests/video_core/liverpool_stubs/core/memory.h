#pragma once
#include "common/types.h"
namespace Core { struct Memory { bool TryWriteBacking(void*, const void*, u64) { return false; } static Memory* Instance() { static Memory m; return &m; } };
namespace Memory_ = ::Core; }
