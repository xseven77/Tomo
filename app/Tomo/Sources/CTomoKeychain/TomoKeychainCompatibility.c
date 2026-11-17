#include "TomoKeychainCompatibility.h"
#include <Security/SecKeychain.h>

// SecItem's modern no-UI options do not reliably work with file-based login
// keychains (Apple FB16959400). Keep the necessary legacy calls isolated here
// until that behavior is fixed; do not suppress deprecations for the app.
// Reference: https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

OSStatus TomoKeychainGetInteractionAllowed(bool *allowed) {
    if (allowed == NULL) {
        return errSecParam;
    }
    Boolean legacyAllowed = false;
    OSStatus status = SecKeychainGetUserInteractionAllowed(&legacyAllowed);
    if (status == errSecSuccess) {
        *allowed = legacyAllowed != 0;
    }
    return status;
}

OSStatus TomoKeychainSetInteractionAllowed(bool allowed) {
    return SecKeychainSetUserInteractionAllowed(allowed);
}

#pragma clang diagnostic pop
