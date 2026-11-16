#ifndef RUNNER_WINDOWS_PRIVILEGES_H_
#define RUNNER_WINDOWS_PRIVILEGES_H_
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> RegisterWindowsPrivileges(flutter::BinaryMessenger* messenger, HWND window);
#endif
