// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.

#include <algorithm>

#include <dlfcn.h>

#include "common/logging/log.h"
#include "core/core.h"

#import <QuartzCore/QuartzCore.h>

#import "PPEmuWindow.h"
#import "PPInternal.h"

// MoltenVK is linked statically (force_load) into PlanetCore. Referencing its exported entry
// point lets us locate the Mach-O image that contains it, and keeps the symbol alive even if the
// linker would otherwise consider it unused (azahar never calls Vulkan symbols directly because
// it builds with VK_NO_PROTOTYPES). The real signature does not matter: only the symbol address
// is used and the function is never called through this declaration.
extern "C" void vkGetInstanceProcAddr(void);

namespace PlanetPort {

namespace {

/// Minimal GraphicsContext, like the Android Vulkan frontend's GraphicsContext_Android: Vulkan
/// needs no current context, but the core may ask for a shared one.
class PPGraphicsContext final : public Frontend::GraphicsContext {
public:
    explicit PPGraphicsContext(std::shared_ptr<Common::DynamicLibrary> library)
        : driver_library{std::move(library)} {}

    std::shared_ptr<Common::DynamicLibrary> GetDriverLibrary() override {
        return driver_library;
    }

private:
    std::shared_ptr<Common::DynamicLibrary> driver_library;
};

std::shared_ptr<Common::DynamicLibrary> OpenMoltenVKImage() {
    void* handle = nullptr;
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void*>(&vkGetInstanceProcAddr), &info) != 0 &&
        info.dli_fname != nullptr) {
        handle = dlopen(info.dli_fname, RTLD_NOW | RTLD_NOLOAD);
    }
    if (handle == nullptr) {
        // Fallback: the main program handle; dlsym on it also searches its dependencies.
        handle = dlopen(nullptr, RTLD_NOW);
    }
    if (handle == nullptr) {
        const char* error = dlerror(); // read once: the first call clears it
        LOG_CRITICAL(Frontend, "Unable to obtain a handle to the MoltenVK image: {}",
                     error != nullptr ? error : "unknown error");
        return nullptr;
    }
    if (dlsym(handle, "vkGetInstanceProcAddr") == nullptr) {
        LOG_CRITICAL(Frontend, "vkGetInstanceProcAddr not found in the MoltenVK image");
    }
    return std::make_shared<Common::DynamicLibrary>(handle);
}

} // namespace

PPEmuWindow::PPEmuWindow(CAMetalLayer* layer, unsigned width_px, unsigned height_px,
                         bool portrait)
    : Frontend::EmuWindow(), metal_layer{layer}, current_width{std::max(width_px, 1u)},
      current_height{std::max(height_px, 1u)}, current_portrait{portrait},
      pending_width{current_width}, pending_height{current_height}, pending_portrait{portrait} {
    window_info.type = Frontend::WindowSystemType::MacOS;
    window_info.render_surface = (__bridge void*)metal_layer;
    window_info.render_surface_scale =
        metal_layer != nil ? static_cast<float>(metal_layer.contentsScale) : 1.0f;

    driver_library = OpenMoltenVKImage();

    std::scoped_lock lock{window_mutex};
    ApplyLayoutLocked(current_width, current_height, current_portrait);
}

PPEmuWindow::~PPEmuWindow() = default;

void PPEmuWindow::PollEvents() {
    // Called by the renderer at the end of every frame on the emulation thread. All input is
    // pushed asynchronously (atomics / touch state), so there is nothing to poll.
}

std::unique_ptr<Frontend::GraphicsContext> PPEmuWindow::CreateSharedContext() const {
    return std::make_unique<PPGraphicsContext>(driver_library);
}

std::shared_ptr<Common::DynamicLibrary> PPEmuWindow::GetDriverLibrary() {
    return driver_library;
}

void PPEmuWindow::SetPendingLayout(unsigned width_px, unsigned height_px, bool portrait) {
    if (width_px == 0 || height_px == 0) {
        return;
    }
    std::scoped_lock lock{window_mutex};
    pending_width = width_px;
    pending_height = height_px;
    pending_portrait = portrait;
    layout_dirty.store(true, std::memory_order_release);
}

bool PPEmuWindow::ApplyPendingLayout() {
    if (!layout_dirty.exchange(false, std::memory_order_acq_rel)) {
        return false;
    }
    std::scoped_lock lock{window_mutex};
    if (pending_width == current_width && pending_height == current_height &&
        pending_portrait == current_portrait) {
        return false;
    }
    current_width = pending_width;
    current_height = pending_height;
    current_portrait = pending_portrait;
    ApplyLayoutLocked(current_width, current_height, current_portrait);
    return true;
}

void PPEmuWindow::RelayoutCurrent() {
    std::scoped_lock lock{window_mutex};
    ApplyLayoutLocked(current_width, current_height, current_portrait);
}

void PPEmuWindow::ApplyCoreSettings(Core::System& system) {
    // ApplySettings never takes window_mutex itself, so holding it here cannot self-deadlock.
    std::scoped_lock lock{window_mutex};
    system.ApplySettings();
    ApplyLayoutLocked(current_width, current_height, current_portrait);
}

bool PPEmuWindow::IsPortrait() const {
    std::scoped_lock lock{window_mutex};
    return current_portrait;
}

void PPEmuWindow::ApplyLayoutLocked(unsigned width, unsigned height, bool portrait) {
    // A touch in progress refers to the old geometry: end it before the layout changes.
    if (touch_active) {
        TouchReleased();
        touch_active = false;
    }
    UpdateCurrentFramebufferLayout(width, height, portrait);
}

bool PPEmuWindow::TouchBegan(unsigned x, unsigned y) {
    std::scoped_lock lock{window_mutex};
    touch_active = TouchPressed(x, y);
    return touch_active;
}

void PPEmuWindow::TouchMovedTo(unsigned x, unsigned y) {
    std::scoped_lock lock{window_mutex};
    if (touch_active) {
        TouchMoved(x, y);
    }
}

void PPEmuWindow::TouchEnded() {
    std::scoped_lock lock{window_mutex};
    if (touch_active) {
        TouchReleased();
        touch_active = false;
    }
}

} // namespace PlanetPort
