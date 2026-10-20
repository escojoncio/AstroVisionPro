#pragma once
#include <format>
#include <string>
#include <utility>
namespace fmt {
template <class... A> std::string format(std::format_string<A...> f, A&&... a) { return std::format(f, std::forward<A>(a)...); }
template <class T> const void* ptr(T* p) { return p; }
template <class T, class C = char, class = void> struct formatter;
struct format_parse_context { const char* begin() { return nullptr; } };
struct format_context { char* out() { return nullptr; } };
template <class O, class... A> O format_to(O o, const char*, A&&...) { return o; }
}
