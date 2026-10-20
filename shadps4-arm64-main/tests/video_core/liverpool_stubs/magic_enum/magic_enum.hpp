#pragma once
#include <string_view>
namespace magic_enum { template <class E> std::string_view enum_name(E) { return "enum"; } }
