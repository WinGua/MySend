#include "windows_privileges.h"
#include "windows_arguments.h"
#include "utils.h"
#include <flutter/standard_method_codec.h>
#include <shlobj.h>
#include <shellapi.h>
#include <filesystem>
#include <optional>
#include <vector>

namespace {
std::optional<bool> IsElevated(DWORD* error) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) { *error = GetLastError(); return std::nullopt; }
  TOKEN_ELEVATION elevation{}; DWORD length = 0;
  const BOOL ok = GetTokenInformation(token, TokenElevation, &elevation, sizeof(elevation), &length);
  *error = ok ? ERROR_SUCCESS : GetLastError();
  CloseHandle(token);
  if (!ok) return std::nullopt;
  return elevation.TokenIsElevated != 0;
}
std::wstring FromUtf8(const std::string& value) {
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), size);
  return result;
}
}
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> RegisterWindowsPrivileges(flutter::BinaryMessenger* messenger, HWND window) {
  using flutter::EncodableValue;
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(messenger, "mysend/windows_privileges", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window](const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    if (call.method_name() == "getUserDataDirectory") {
      PWSTR root = nullptr;
      const HRESULT status = SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_DEFAULT, nullptr, &root);
      if (FAILED(status)) { result->Error("DATA_DIRECTORY", "Cannot resolve current user data directory"); return; }
      // Match Runner.rc and the existing path_provider_windows layout, without creating it.
      const auto path = std::filesystem::path(root) / L"WinGua" / L"MySend";
      CoTaskMemFree(root);
      result->Success(EncodableValue(Utf8FromUtf16(path.c_str())));
      return;
    }
    if (call.method_name() != "isElevated" && call.method_name() != "restartElevated") { result->NotImplemented(); return; }
    DWORD error = 0;
    const auto elevated = IsElevated(&error);
    if (!elevated.has_value()) { result->Error("PRIVILEGE_QUERY", "Cannot query process privileges", EncodableValue(static_cast<int64_t>(error))); return; }
    if (call.method_name() == "isElevated") { result->Success(EncodableValue(*elevated)); return; }
    if (*elevated) { result->Error("ALREADY_ELEVATED", "The process already has administrator privileges"); return; }
    const auto* data = call.arguments() ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!data) { result->Error("INVALID_ARGUMENT", "Missing original user data directory"); return; }
    const auto directory = FromUtf8(*data);
    if (directory.empty() || directory.find(L'\0') != std::wstring::npos || !std::filesystem::path(directory).is_absolute()) {
      result->Error("INVALID_ARGUMENT", "Original user data directory must be absolute"); return;
    }
    std::vector<wchar_t> module(32768);
    const DWORD count = GetModuleFileNameW(nullptr, module.data(), static_cast<DWORD>(module.size()));
    if (count == 0 || count >= module.size()) { result->Error("EXECUTABLE_PATH", "Cannot resolve MySend executable"); return; }
    const std::wstring executable(module.data(), count);
    const auto working = std::filesystem::path(executable).parent_path().wstring();
    // Start this executable only, without cmd/powershell, preserving the original user's identity/config.
    const auto arguments = QuoteWindowsArgument(L"--data-directory=" + directory);
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info); info.fMask = SEE_MASK_NOCLOSEPROCESS;
    info.hwnd = window; info.lpVerb = L"runas"; info.lpFile = executable.c_str();
    info.lpParameters = arguments.c_str(); info.lpDirectory = working.c_str(); info.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&info)) {
      const DWORD code = GetLastError();
      if (code == ERROR_CANCELLED) result->Success(EncodableValue(false));
      else result->Error("ELEVATION_FAILED", "Windows could not restart MySend as administrator", EncodableValue(static_cast<int64_t>(code)));
      return;
    }
    if (info.hProcess) CloseHandle(info.hProcess);
    result->Success(EncodableValue(true));
  });
  return channel;
}
