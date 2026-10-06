// SDL builds its visionOS curved-window support from Swift sources that only Xcode compiles,
// and SDL_uikitviewcontroller.m imports the header Xcode generates for them. The emulator uses
// SDL without any window on visionOS (the Swift app shows the frames), so the one method that
// header would declare is declared here and does nothing (sdl3_swift_stub.m).
#pragma once
#import "SDL_uikitviewcontroller.h"

@interface SDL_uikitviewcontroller (AstroQuestNoCurvedUI)
- (void)initializeVisionOSCurvedUI;
@end
