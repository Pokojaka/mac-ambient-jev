#include "include/CWindowsAccelerator.h"
#include <dxcore.h>
#include <wrl/client.h>
#include <cstring>
#include <cstdio>

int32_t mja_dxcore_identity(uint64_t luid, uint64_t *driver_version, uint64_t *dedicated_memory, int32_t *memory_available, char adapter_identity[45])
{
    if (driver_version == nullptr || dedicated_memory == nullptr ||
        memory_available == nullptr || adapter_identity == nullptr) {
        return static_cast<int32_t>(E_POINTER);
    }
    *memory_available = 0;
    LUID adapter_luid{};
    adapter_luid.LowPart = static_cast<DWORD>(luid);
    const uint32_t luid_high = static_cast<uint32_t>(luid >> 32);
    std::memcpy(&adapter_luid.HighPart, &luid_high, sizeof(adapter_luid.HighPart));
    Microsoft::WRL::ComPtr<IDXCoreAdapterFactory> factory;
    HRESULT hr = DXCoreCreateAdapterFactory(IID_PPV_ARGS(&factory));
    if (FAILED(hr)) return static_cast<int32_t>(hr);
    Microsoft::WRL::ComPtr<IDXCoreAdapter> adapter;
    hr = factory->GetAdapterByLuid(adapter_luid, IID_PPV_ARGS(&adapter));
    if (FAILED(hr)) return static_cast<int32_t>(hr);
    if (!adapter->IsPropertySupported(DXCoreAdapterProperty::HardwareIDParts)) return static_cast<int32_t>(E_NOTIMPL);
    DXCoreHardwareIDParts parts{};
    hr = adapter->GetProperty(DXCoreAdapterProperty::HardwareIDParts, sizeof(parts), &parts);
    if (FAILED(hr)) return static_cast<int32_t>(hr);
    std::snprintf(adapter_identity, 45, "%08x:%08x:%08x:%08x:%08x", parts.vendorID, parts.deviceID, parts.subSystemID, parts.subVendorID, parts.revisionID);
    if (!adapter->IsPropertySupported(DXCoreAdapterProperty::DriverVersion)) return static_cast<int32_t>(E_NOTIMPL);
    uint64_t version;
    hr = adapter->GetProperty(DXCoreAdapterProperty::DriverVersion, sizeof(version), &version);
    if (FAILED(hr)) return static_cast<int32_t>(hr);
    *driver_version = version;
    if (adapter->IsPropertySupported(DXCoreAdapterProperty::DedicatedAdapterMemory)) {
        uint64_t memory;
        hr = adapter->GetProperty(DXCoreAdapterProperty::DedicatedAdapterMemory, sizeof(memory), &memory);
        if (SUCCEEDED(hr)) {
            *dedicated_memory = memory;
            *memory_available = 1;
        }
    }
    return static_cast<int32_t>(S_OK);
}
