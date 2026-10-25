// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Frontend::EmuWindow implementation backed by a CAMetalLayer (Vulkan through MoltenVK).
// Objective-C++ only; private to the bridge.

#pragma once

#include <atomic>
#include <memory>
#include <mutex>

#include "common/dynamic_library.h"
#include "core/frontend/emu_window.h"

@class CAMetalLayer;

namespace Core {
class System;
}

namespace PlanetPort {

class PPEmuWindow final : public Frontend::EmuWindow {
public:
    /// `width_px`/`height_px` are drawable pixels. Must be constructed on the emulation thread
    /// after Settings::values has been filled (the initial layout reads it).
    PPEmuWindow(CAMetalLayer* layer, unsigned width_px, unsigned height_px, bool portrait);
    ~PPEmuWindow() override;

    PPEmuWindow(const PPEmuWindow&) = delete;
    PPEmuWindow& operator=(const PPEmuWindow&) = delete;

    // Frontend::EmuWindow / GraphicsContext
    void PollEvents() override;
    std::unique_ptr<Frontend::GraphicsContext> CreateSharedContext() const override;
    std::shared_ptr<Common::DynamicLibrary> GetDriverLibrary() override;

    /// Main thread: remembers a new drawable size/orientation; applied by ApplyPendingLayout().
    void SetPendingLayout(unsigned width_px, unsigned height_px, bool portrait);
    /// Emulation thread, between RunLoop calls. Returns true when a new layout was applied.
    bool ApplyPendingLayout();
    /// Emulation thread: re-applies the current size (after settings that affect the layout).
    void RelayoutCurrent();
    /// Emulation thread: System::ApplySettings() (which re-lays out this window with
    /// portrait = false on non-Android builds) followed by the real layout, both under the
    /// window lock so touch handling never observes the transient layout.
    void ApplyCoreSettings(Core::System& system);
    bool IsPortrait() const;

    /// Touch helpers (any thread). Coordinates are drawable pixels.
    bool TouchBegan(unsigned x, unsigned y);
    void TouchMovedTo(unsigned x, unsigned y);
    void TouchEnded();

private:
    void ApplyLayoutLocked(unsigned width, unsigned height, bool portrait);

    // Retained Objective-C object (ARC manages it as a strong C++ member in Objective-C++).
    CAMetalLayer* metal_layer;

    mutable std::mutex window_mutex;
    unsigned current_width;
    unsigned current_height;
    bool current_portrait;

    unsigned pending_width;
    unsigned pending_height;
    bool pending_portrait;
    std::atomic_bool layout_dirty{false};

    bool touch_active = false;

    std::shared_ptr<Common::DynamicLibrary> driver_library;
};

} // namespace PlanetPort
