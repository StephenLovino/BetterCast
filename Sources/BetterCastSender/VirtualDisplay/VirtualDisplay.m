// -*- Mode: ObjC; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4; fill-column: 100 -*-

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#import "CGVirtualDisplay.h"
#import "CGVirtualDisplayDescriptor.h"
#import "CGVirtualDisplayMode.h"
#import "CGVirtualDisplaySettings.h"

#import "VirtualDisplay.h"

id createVirtualDisplay(int width, int height, int ppi, BOOL hiDPI, NSString *name, unsigned int serialNum, int refreshRate, NSArray<NSValue *> *pointModes) {

    CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
    settings.hiDPI = hiDPI;

    CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
    descriptor.queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
    descriptor.name = name;

    // See System Preferences > Displays > Color > Open Profile > Apple display native information
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
    // Each point is 2x2 pixels in a HiDPI mode, so the framebuffer has to fit the
    // largest listed mode at that density as well as the nominal size.
    unsigned int density = hiDPI ? 2 : 1;
    unsigned int framebufferWide = width, framebufferHigh = height;
    for (NSValue *value in pointModes) {
        NSSize size = value.sizeValue;
        framebufferWide = MAX(framebufferWide, (unsigned int)size.width * density);
        framebufferHigh = MAX(framebufferHigh, (unsigned int)size.height * density);
    }
    descriptor.maxPixelsHigh = framebufferHigh;
    descriptor.maxPixelsWide = framebufferWide;
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / ppi, 25.4 * height / ppi);
    descriptor.serialNum = serialNum;
    descriptor.productID = serialNum;
    descriptor.vendorID = 1;

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];

    double hz = refreshRate > 0 ? refreshRate : 60;
    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];
    for (NSValue *value in pointModes) {
        NSSize size = value.sizeValue;
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)size.width
                                                              height:(unsigned int)size.height
                                                         refreshRate:hz]];
    }
    if (modes.count == 0) {
        unsigned int modeWide = width, modeHigh = height;
        if (settings.hiDPI) {
            modeWide /= 2;
            modeHigh /= 2;
        }
        [modes addObject:[[CGVirtualDisplayMode alloc] initWithWidth:modeWide
                                                              height:modeHigh
                                                         refreshRate:hz]];
    }
    settings.modes = modes;

    if (![display applySettings:settings])
        return nil;

    return display;
}
