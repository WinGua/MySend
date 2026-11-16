#ifndef RUNNER_WINDOWS_ARGUMENTS_H_
#define RUNNER_WINDOWS_ARGUMENTS_H_
#include <string>
// Inverse of CommandLineToArgvW escaping, including trailing backslashes.
inline std::wstring QuoteWindowsArgument(const std::wstring& argument) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t c : argument) {
    if (c == L'\\') { ++slashes; continue; }
    if (c == L'\"') result.append(slashes * 2 + 1, L'\\');
    else result.append(slashes, L'\\');
    result.push_back(c); slashes = 0;
  }
  result.append(slashes * 2, L'\\');
  result.push_back(L'\"');
  return result;
}
#endif
