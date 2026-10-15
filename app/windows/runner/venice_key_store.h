#ifndef VENICE_KEY_STORE_H_
#define VENICE_KEY_STORE_H_
#include <windows.h>
#include <shlobj.h>
#include <wincrypt.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <string>
#include <vector>

// Resolve the current Windows user's real local-data folder. Do not depend on
// the launching terminal/IDE's USERPROFILE, current directory or inherited PATH.
inline void LoadVeniceKey(flutter::MethodResult<flutter::EncodableValue>* result) {
  PWSTR folder = nullptr;
  const HRESULT hr = SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder);
  if (FAILED(hr) || !folder) {
    if (folder) CoTaskMemFree(folder);
    result->Error("key_directory"); return;
  }
  const std::wstring path = std::wstring(folder) + L"\\AIHaptics\\private\\venice\\api-key.sealed";
  CoTaskMemFree(folder);
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    result->Error(error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND
                      ? "key_missing" : "key_read_denied");
    return;
  }
  LARGE_INTEGER length{};
  if (!GetFileSizeEx(file, &length) || length.QuadPart <= 0 || length.QuadPart > 16384) {
    CloseHandle(file); result->Error("key_file_invalid"); return;
  }
  std::vector<uint8_t> sealed(static_cast<size_t>(length.QuadPart));
  DWORD read = 0;
  const BOOL read_ok = ReadFile(file, sealed.data(), static_cast<DWORD>(sealed.size()), &read, nullptr);
  CloseHandle(file);
  if (!read_ok || read != sealed.size()) { result->Error("key_read_failed"); return; }
  DATA_BLOB input{read, sealed.data()}, output{};
  if (!CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr,
                         CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    result->Error("key_decrypt_failed"); return;
  }
  std::vector<uint8_t> plain(output.pbData, output.pbData + output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  flutter::EncodableValue response(std::move(plain));
  result->Success(response);
  auto& buffer = std::get<std::vector<uint8_t>>(response);
  SecureZeroMemory(buffer.data(), buffer.size());
}
#endif
