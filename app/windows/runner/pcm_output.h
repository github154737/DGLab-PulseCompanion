#ifndef PCM_OUTPUT_H_
#define PCM_OUTPUT_H_
#include <windows.h>
#include <mmsystem.h>
#include <wincrypt.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <deque>
#include <memory>
#include <vector>
#include "venice_key_store.h"

class PcmOutput {
 public:
  explicit PcmOutput(flutter::BinaryMessenger* messenger) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(messenger, "aihaptics/pcm", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      try {
        if (call.method_name() == "load_venice_key") {
          LoadVeniceKey(result.get());
        } else if (call.method_name() == "seal" || call.method_name() == "unseal") {
          const auto* bytes = call.arguments() ? std::get_if<std::vector<uint8_t>>(call.arguments()) : nullptr;
          if (!bytes || bytes->size() > 16384) { result->Error("vault_input"); return; }
          DATA_BLOB input{static_cast<DWORD>(bytes->size()), const_cast<BYTE*>(bytes->data())}, output{};
          const BOOL ok = call.method_name() == "seal"
            ? CryptProtectData(&input, L"AIHaptics beta account", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)
            : CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output);
          if (!ok) { result->Error("vault_unavailable"); return; }
          std::vector<uint8_t> value(output.pbData, output.pbData + output.cbData);
          SecureZeroMemory(output.pbData, output.cbData); LocalFree(output.pbData);
          result->Success(flutter::EncodableValue(value));
        } else if (call.method_name() == "setup") {
          Stop();
          if (device_) { waveOutClose(device_); device_ = nullptr; }
          WAVEFORMATEX format{};
          format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 1;
          format.nSamplesPerSec = 24000; format.wBitsPerSample = 16;
          format.nBlockAlign = 2; format.nAvgBytesPerSec = 48000;
          if (waveOutOpen(&device_, WAVE_MAPPER, &format, 0, 0, CALLBACK_NULL) != MMSYSERR_NOERROR) { result->Error("audio_unavailable"); return; }
          result->Success();
        } else if (call.method_name() == "feed") {
          Collect();
          const auto* bytes = call.arguments() ? std::get_if<std::vector<uint8_t>>(call.arguments()) : nullptr;
          if (!device_ || !bytes || bytes->empty() || bytes->size() % 2 || bytes->size() > 48000 || Pending() + bytes->size() > 96000) { result->Error("audio_backpressure"); return; }
          auto buffer = std::make_unique<Buffer>(); buffer->bytes = *bytes;
          buffer->header.lpData = reinterpret_cast<LPSTR>(buffer->bytes.data());
          buffer->header.dwBufferLength = static_cast<DWORD>(buffer->bytes.size());
          if (waveOutPrepareHeader(device_, &buffer->header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) { result->Error("audio_prepare"); return; }
          if (waveOutWrite(device_, &buffer->header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) { waveOutUnprepareHeader(device_, &buffer->header, sizeof(WAVEHDR)); result->Error("audio_write"); return; }
          buffers_.push_back(std::move(buffer)); result->Success();
        } else if (call.method_name() == "capacity") { result->Success(flutter::EncodableValue(48000)); }
        else if (call.method_name() == "stop") { Stop(); result->Success(); }
        else if (call.method_name() == "pending") { Collect(); result->Success(flutter::EncodableValue(static_cast<int>(Pending() / 2))); }
        else { result->NotImplemented(); }
      } catch (...) { result->Error("audio_error"); }
    });
  }
  ~PcmOutput() { channel_->SetMethodCallHandler(nullptr); Stop(); if (device_) waveOutClose(device_); }
 private:
  struct Buffer { WAVEHDR header{}; std::vector<uint8_t> bytes; };
  HWAVEOUT device_ = nullptr;
  std::deque<std::unique_ptr<Buffer>> buffers_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  size_t Pending() const { size_t count = 0; for (const auto& b : buffers_) if (!(b->header.dwFlags & WHDR_DONE)) count += b->bytes.size(); return count; }
  void Collect() { while (!buffers_.empty() && (buffers_.front()->header.dwFlags & WHDR_DONE)) { waveOutUnprepareHeader(device_, &buffers_.front()->header, sizeof(WAVEHDR)); buffers_.pop_front(); } }
  void Stop() { if (device_) waveOutReset(device_); for (auto& b : buffers_) if (device_) waveOutUnprepareHeader(device_, &b->header, sizeof(WAVEHDR)); buffers_.clear(); }
};
#endif
