// PlanetPort - native iOS frontend for the Azahar 3DS emulator core.
// Copyright 2026 PlanetPort contributors. Licensed under GPLv2 or any later version.
//
// Software keyboard applet. Button ids and titles mirror the Qt frontend
// (src/citra_qt/applets/swkbd.cpp): id 0 = Cancel (button_text[0]), id 1 = I Forgot
// (button_text[1]), and the OK button id equals the ButtonConfig value (Single 0, Dual 1,
// Triple 2) with title button_text[2].

#include <algorithm>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

#include "common/logging/log.h"
#include "core/frontend/applets/swkbd.h"

#import "PPInternal.h"

namespace {

NSString* MessageForValidationError(Frontend::ValidationError error) {
    using Frontend::ValidationError;
    switch (error) {
    case ValidationError::None:
        return nil;
    case ValidationError::ButtonOutOfRange:
        return @"Pulsante non valido.";
    case ValidationError::MaxDigitsExceeded:
        return @"Il testo contiene troppe cifre.";
    case ValidationError::AtSignNotAllowed:
        return @"Il carattere @ non è consentito.";
    case ValidationError::PercentNotAllowed:
        return @"Il carattere % non è consentito.";
    case ValidationError::BackslashNotAllowed:
        return @"Il carattere \\ non è consentito.";
    case ValidationError::ProfanityNotAllowed:
        return @"Il testo contiene parole non consentite.";
    case ValidationError::CallbackFailed:
        return @"Il gioco ha rifiutato il testo.";
    case ValidationError::FixedLengthRequired:
        return @"Il testo deve avere esattamente la lunghezza richiesta.";
    case ValidationError::MaxLengthExceeded:
        return @"Il testo è troppo lungo.";
    case ValidationError::BlankInputNotAllowed:
        return @"Il testo non può contenere solo spazi.";
    case ValidationError::EmptyInputNotAllowed:
        return @"Il testo non può essere vuoto.";
    }
    return @"Testo non valido.";
}

/// Stateless validator: a SoftwareKeyboard holding a copy of the game's configuration, so a
/// PPKeyboardRequest can validate text without referencing the live applet.
class KeyboardValidator final : public Frontend::SoftwareKeyboard {
public:
    explicit KeyboardValidator(const Frontend::KeyboardConfig& config_) {
        config = config_;
    }
    void ShowError(const std::string&) override {}
};

} // namespace

// -------------------------------------------------------------------------------------------
// PPKeyboardRequest
// -------------------------------------------------------------------------------------------

@interface PPKeyboardRequest ()
- (instancetype)initWithConfig:(const Frontend::KeyboardConfig&)config;
/// Completes the request as cancelled (first button, empty text). Any thread, idempotent.
- (void)cancel;
/// Blocks the calling (emulation) thread until finished or cancelled.
- (void)waitUntilFinished;
@property (nonatomic, readonly) BOOL wasCancelled;
@property (nonatomic, readonly, copy) NSString* resultText;
@property (nonatomic, readonly) NSInteger resultButton;
@end

@implementation PPKeyboardRequest {
    std::unique_ptr<KeyboardValidator> _validator;
    std::atomic_bool _finished;
    dispatch_semaphore_t _semaphore;
    NSString* _hintText;
    NSArray<NSString*>* _buttonTitles;
    NSString* _resultText;
    std::atomic<NSInteger> _resultButton;
    std::atomic_bool _cancelled;
}

- (instancetype)initWithConfig:(const Frontend::KeyboardConfig&)config {
    if ((self = [super init])) {
        _validator = std::make_unique<KeyboardValidator>(config);
        _finished = false;
        _cancelled = false;
        _resultButton = 0;
        _resultText = @"";
        _semaphore = dispatch_semaphore_create(0);
        _hintText = PlanetPort::ToNSString(config.hint_text);
        _maxLength = config.max_text_length;
        _multiline = config.multiline_mode ? YES : NO;

        auto text_at = [&config](std::size_t index, NSString* fallback) -> NSString* {
            if (index < config.button_text.size() && !config.button_text[index].empty()) {
                return PlanetPort::ToNSString(config.button_text[index]);
            }
            return fallback;
        };
        NSString* cancel = text_at(0, @"Annulla");
        NSString* forgot = text_at(1, @"Non ricordo");
        NSString* ok = text_at(2, @"OK");
        switch (config.button_config) {
        case Frontend::ButtonConfig::Single:
            _buttonTitles = @[ ok ];
            _confirmButtonIndex = 0;
            break;
        case Frontend::ButtonConfig::Dual:
            _buttonTitles = @[ cancel, ok ];
            _confirmButtonIndex = 1;
            break;
        case Frontend::ButtonConfig::Triple:
            _buttonTitles = @[ cancel, forgot, ok ];
            _confirmButtonIndex = 2;
            break;
        case Frontend::ButtonConfig::None:
        default:
            // No buttons announced by the game: offer a single confirm (id 0, never validated).
            _buttonTitles = @[ @"OK" ];
            _confirmButtonIndex = 0;
            break;
        }
    }
    return self;
}

- (NSString*)hintText {
    return _hintText;
}

- (NSArray<NSString*>*)buttonTitles {
    return _buttonTitles;
}

- (BOOL)wasCancelled {
    return _cancelled.load() ? YES : NO;
}

- (NSString*)resultText {
    @synchronized(self) {
        return _resultText;
    }
}

- (NSInteger)resultButton {
    return _resultButton.load();
}

- (nullable NSString*)validateText:(NSString*)text {
    const std::string input = PlanetPort::ToStdString(text);
    Frontend::ValidationError error = _validator->ValidateFilters(input);
    if (error == Frontend::ValidationError::None) {
        error = _validator->ValidateInput(input);
    }
    return MessageForValidationError(error);
}

- (void)finishWithText:(NSString*)text buttonIndex:(NSInteger)buttonIndex {
    if (_finished.exchange(true)) {
        return;
    }
    @synchronized(self) {
        _resultText = [text copy] ?: @"";
    }
    const NSInteger max_index = static_cast<NSInteger>(_buttonTitles.count) - 1;
    _resultButton = std::clamp<NSInteger>(buttonIndex, 0, std::max<NSInteger>(max_index, 0));
    dispatch_semaphore_signal(_semaphore);
}

- (void)cancel {
    if (_finished.exchange(true)) {
        return;
    }
    _cancelled = true;
    @synchronized(self) {
        _resultText = @"";
    }
    _resultButton = 0;
    dispatch_semaphore_signal(_semaphore);
}

- (void)waitUntilFinished {
    dispatch_semaphore_wait(_semaphore, DISPATCH_TIME_FOREVER);
}

@end

// -------------------------------------------------------------------------------------------
// Frontend keyboard
// -------------------------------------------------------------------------------------------

namespace PlanetPort::Applets {

namespace {

std::mutex g_mutex;
KeyboardPresenter g_presenter;     // guarded by g_mutex
PPKeyboardRequest* g_pending = nil; // guarded by g_mutex
bool g_cancel_all = false;          // guarded by g_mutex; sticky until the next boot

KeyboardPresenter CurrentPresenter() {
    std::scoped_lock lock{g_mutex};
    return g_presenter;
}

class PPSoftwareKeyboard final : public Frontend::SoftwareKeyboard {
public:
    void Execute(const Frontend::KeyboardConfig& config_) override {
        SoftwareKeyboard::Execute(config_);

        while (true) {
            PPKeyboardRequest* request = [[PPKeyboardRequest alloc] initWithConfig:config];
            bool cancelled_already = false;
            {
                // Registering and checking the sticky cancel under the same lock closes the
                // window where a stop could slip in before the request exists.
                std::scoped_lock lock{g_mutex};
                if (g_cancel_all) {
                    cancelled_already = true;
                } else {
                    g_pending = request;
                }
            }

            const KeyboardPresenter presenter = CurrentPresenter();
            if (cancelled_already) {
                [request cancel];
            } else if (presenter.present) {
                presenter.present(request);
            } else {
                // No UI: cancel rather than confirm empty text, which the game could reject
                // forever.
                [request cancel];
            }
            [request waitUntilFinished];

            {
                std::scoped_lock lock{g_mutex};
                if (g_pending == request) {
                    g_pending = nil;
                }
            }

            const std::string text = ToStdString(request.resultText);
            const auto button = static_cast<u8>(request.resultButton);
            const Frontend::ValidationError error = Finalize(text, button);
            if (error == Frontend::ValidationError::None || request.wasCancelled) {
                // On cancel (emulation stopping) never re-present: return even without data,
                // the core is about to shut down.
                return;
            }
            if (presenter.show_error) {
                presenter.show_error(MessageForValidationError(error));
            }
        }
    }

    void ShowError(const std::string& error) override {
        LOG_INFO(Frontend, "PlanetPort: software keyboard error: {}", error);
        const KeyboardPresenter presenter = CurrentPresenter();
        if (presenter.show_error) {
            presenter.show_error(ToNSString(error));
        }
    }
};

} // namespace

void SetKeyboardPresenter(KeyboardPresenter presenter) {
    std::scoped_lock lock{g_mutex};
    g_presenter = std::move(presenter);
}

std::shared_ptr<Frontend::SoftwareKeyboard> CreateSoftwareKeyboard() {
    return std::make_shared<PPSoftwareKeyboard>();
}

void CancelPendingKeyboard() {
    PPKeyboardRequest* pending = nil;
    {
        std::scoped_lock lock{g_mutex};
        g_cancel_all = true;
        pending = g_pending;
        g_pending = nil;
    }
    [pending cancel];
}

void ResetKeyboardCancellation() {
    std::scoped_lock lock{g_mutex};
    g_cancel_all = false;
    g_pending = nil;
}

} // namespace PlanetPort::Applets
