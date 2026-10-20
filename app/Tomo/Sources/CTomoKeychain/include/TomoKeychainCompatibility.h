#ifndef TOMO_KEYCHAIN_COMPATIBILITY_H
#define TOMO_KEYCHAIN_COMPATIBILITY_H

#include <Security/SecBase.h>
#include <stdbool.h>

// Process-wide policy: callers must serialize access and restore any changes.
OSStatus TomoKeychainGetInteractionAllowed(bool *allowed);
OSStatus TomoKeychainSetInteractionAllowed(bool allowed);

#endif
