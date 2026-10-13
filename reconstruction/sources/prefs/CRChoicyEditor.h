#import <Foundation/Foundation.h>

/* Call after loading ChoicyPrefs. Returns Nil when its private API is
 * unavailable or has an incompatible ABI; retrying after a later load is safe. */
Class CRChoicyContainerEditorClass(void);
