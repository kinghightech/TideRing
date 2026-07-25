#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "morning" asset catalog image resource.
static NSString * const ACImageNameMorning AC_SWIFT_PRIVATE = @"morning";

/// The "newbg" asset catalog image resource.
static NSString * const ACImageNameNewbg AC_SWIFT_PRIVATE = @"newbg";

/// The "ring" asset catalog image resource.
static NSString * const ACImageNameRing AC_SWIFT_PRIVATE = @"ring";

#undef AC_SWIFT_PRIVATE
