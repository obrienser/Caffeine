#import <IOKit/IOMessage.h>

// Swift cannot import these macros: they expand to a function-like macro.
static const uint32_t CaffeineCanSystemSleep = kIOMessageCanSystemSleep;
static const uint32_t CaffeineSystemWillSleep = kIOMessageSystemWillSleep;
static const uint32_t CaffeineSystemHasPoweredOn = kIOMessageSystemHasPoweredOn;
