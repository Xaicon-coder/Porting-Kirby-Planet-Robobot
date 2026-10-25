// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Input devices fed by the iOS UI (touch controls, GameController, CoreMotion).
//
// Unlike the Android frontend (one list of devices per id), the state lives in global atomics
// indexed by the native button / analog id. Devices created by the core (HID, APT, ir:rst,
// extra HID) read that state, so a device created after a button was pressed starts with the
// correct state, and several devices bound to the same button never steal each other's events.

#include <array>
#include <atomic>
#include <cmath>
#include <memory>
#include <string>
#include <tuple>

#include "common/logging/log.h"
#include "common/param_package.h"
#include "common/settings.h"
#include "common/vector_math.h"
#include "core/frontend/input.h"

#import "PPInternal.h"

namespace PlanetPort::Input {

namespace {

constexpr int kNumButtons = Settings::NativeButton::NumButtons;
constexpr int kNumAnalogs = Settings::NativeAnalog::NumAnalogs;

struct ButtonState {
    std::atomic_bool pressed{false};
    /// Incremented on every press so that devices can report presses shorter than their poll
    /// period (each device remembers the last count it has seen).
    std::atomic<std::uint64_t> press_count{0};
};

struct AnalogState {
    std::atomic<float> x{0.0f};
    std::atomic<float> y{0.0f};
};

struct MotionState {
    std::atomic<float> accel_x{0.0f};
    std::atomic<float> accel_y{-1.0f}; // 3DS lying flat, screen up: gravity along -Y
    std::atomic<float> accel_z{0.0f};
    std::atomic<float> gyro_x{0.0f};
    std::atomic<float> gyro_y{0.0f};
    std::atomic<float> gyro_z{0.0f};
};

std::array<ButtonState, kNumButtons> g_buttons;
std::array<AnalogState, kNumAnalogs> g_analogs;
MotionState g_motion;
std::atomic_bool g_registered{false};

class PPButtonDevice final : public ::Input::ButtonDevice {
public:
    explicit PPButtonDevice(int code_)
        : code{code_}, last_seen{IsValid() ? g_buttons[code].press_count.load() : 0} {}

    bool GetStatus() const override {
        if (!IsValid()) {
            return false;
        }
        const ButtonState& state = g_buttons[code];
        const std::uint64_t count = state.press_count.load();
        const bool pressed_since_read = count != last_seen;
        last_seen = count;
        return state.pressed.load() || pressed_since_read;
    }

private:
    bool IsValid() const {
        return code >= 0 && code < kNumButtons;
    }

    const int code;
    mutable std::uint64_t last_seen;
};

class PPAnalogDevice final : public ::Input::AnalogDevice {
public:
    explicit PPAnalogDevice(int code_) : code{code_} {}

    std::tuple<float, float> GetStatus() const override {
        if (code < 0 || code >= kNumAnalogs) {
            return {0.0f, 0.0f};
        }
        return {g_analogs[code].x.load(), g_analogs[code].y.load()};
    }

private:
    const int code;
};

class PPMotionDevice final : public ::Input::MotionDevice {
public:
    std::tuple<Common::Vec3<float>, Common::Vec3<float>> GetStatus() const override {
        const Common::Vec3<float> accel{g_motion.accel_x.load(), g_motion.accel_y.load(),
                                        g_motion.accel_z.load()};
        const Common::Vec3<float> gyro{g_motion.gyro_x.load(), g_motion.gyro_y.load(),
                                       g_motion.gyro_z.load()};
        return {accel, gyro};
    }
};

class PPButtonFactory final : public ::Input::Factory<::Input::ButtonDevice> {
public:
    std::unique_ptr<::Input::ButtonDevice> Create(const Common::ParamPackage& params) override {
        return std::make_unique<PPButtonDevice>(params.Get("code", -1));
    }
};

class PPAnalogFactory final : public ::Input::Factory<::Input::AnalogDevice> {
public:
    std::unique_ptr<::Input::AnalogDevice> Create(const Common::ParamPackage& params) override {
        return std::make_unique<PPAnalogDevice>(params.Get("code", -1));
    }
};

class PPMotionFactory final : public ::Input::Factory<::Input::MotionDevice> {
public:
    std::unique_ptr<::Input::MotionDevice> Create(const Common::ParamPackage&) override {
        return std::make_unique<PPMotionDevice>();
    }
};

/// Android's TransformAxes (src/android/app/src/main/jni/ndk_motion.cpp): maps the phone's
/// device frame (X right, Y up along the screen, Z out of the screen) to the 3DS frame
/// (X+ towards D-pad left, Y+ out of the touch screen, Z+ towards D-pad up) for a given
/// interface rotation (counter-clockwise quarter turns from portrait).
Common::Vec3<float> TransformAxes(float x, float y, float z, int rotation) {
    Common::Vec3<float> out{};
    out.y = z;
    switch (rotation) {
    case 1:
        out.x = y;
        out.z = x;
        break;
    case 2:
        out.x = x;
        out.z = -y;
        break;
    case 3:
        out.x = -y;
        out.z = -x;
        break;
    case 0:
    default:
        out.x = -x;
        out.z = y;
        break;
    }
    return out;
}

} // namespace

void RegisterFactories() {
    if (g_registered.exchange(true)) {
        return;
    }
    ::Input::RegisterFactory<::Input::ButtonDevice>("gamepad", std::make_shared<PPButtonFactory>());
    ::Input::RegisterFactory<::Input::AnalogDevice>("gamepad", std::make_shared<PPAnalogFactory>());
    ::Input::RegisterFactory<::Input::MotionDevice>("pp_motion",
                                                    std::make_shared<PPMotionFactory>());
}

void ConfigureInputProfile() {
    auto& profile = Settings::values.current_input_profile;
    for (int i = 0; i < kNumButtons; ++i) {
        profile.buttons[i] =
            Common::ParamPackage{{"engine", "gamepad"}, {"code", std::to_string(i)}}.Serialize();
    }
    for (int i = 0; i < kNumAnalogs; ++i) {
        profile.analogs[i] =
            Common::ParamPackage{{"engine", "gamepad"}, {"code", std::to_string(i)}}.Serialize();
    }
    profile.motion_device = "engine:pp_motion";
    profile.touch_device = "engine:emu_window";
}

void SetButton(int native_button, bool pressed) {
    if (native_button < 0 || native_button >= kNumButtons) {
        return;
    }
    ButtonState& state = g_buttons[native_button];
    if (pressed) {
        state.press_count.fetch_add(1);
    }
    state.pressed.store(pressed);
}

void SetAnalog(int native_analog, float x, float y) {
    if (native_analog < 0 || native_analog >= kNumAnalogs) {
        return;
    }
    if (!std::isfinite(x) || !std::isfinite(y)) {
        x = 0.0f;
        y = 0.0f;
    }
    x = std::fmax(-1.0f, std::fmin(1.0f, x));
    y = std::fmax(-1.0f, std::fmin(1.0f, y));
    const float radius = std::sqrt(x * x + y * y);
    if (radius > 1.0f) {
        x /= radius;
        y /= radius;
    }
    g_analogs[native_analog].x.store(x);
    g_analogs[native_analog].y.store(y);
}

void ReleaseAll() {
    for (auto& button : g_buttons) {
        button.pressed.store(false);
    }
    for (auto& analog : g_analogs) {
        analog.x.store(0.0f);
        analog.y.store(0.0f);
    }
}

void SetMotion(double ax, double ay, double az, double gx, double gy, double gz, int rotation) {
    // Android: acceleration = TransformAxes(raw_m_s2) / -g. The Android sensor reports the
    // reaction to gravity (+9.81 on Z lying flat) while CoreMotion's gravity + userAcceleration
    // reports gravity itself in g (-1 on Z lying flat), i.e. raw_android = -g * coremotion.
    // Since TransformAxes is linear: TransformAxes(-g * cm) / -g == TransformAxes(cm).
    // Both platforms report rotation rate in rad/s with the same right-handed device axes.
    constexpr float kRadToDeg = 180.0f / static_cast<float>(M_PI);
    const auto accel = TransformAxes(static_cast<float>(ax), static_cast<float>(ay),
                                     static_cast<float>(az), rotation);
    const auto gyro = TransformAxes(static_cast<float>(gx), static_cast<float>(gy),
                                    static_cast<float>(gz), rotation) *
                      kRadToDeg;
    if (std::isfinite(accel.x) && std::isfinite(accel.y) && std::isfinite(accel.z)) {
        g_motion.accel_x.store(accel.x);
        g_motion.accel_y.store(accel.y);
        g_motion.accel_z.store(accel.z);
    }
    if (std::isfinite(gyro.x) && std::isfinite(gyro.y) && std::isfinite(gyro.z)) {
        g_motion.gyro_x.store(gyro.x);
        g_motion.gyro_y.store(gyro.y);
        g_motion.gyro_z.store(gyro.z);
    }
}

} // namespace PlanetPort::Input
