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

#import <Foundation/Foundation.h>

/// `pointModes`, when non-empty, replaces the single default mode with this list of
/// sizes in points (NSValue-wrapped NSSize), first entry = the mode the display starts
/// in. The framebuffer is sized to hold the largest of them.
id createVirtualDisplay(int width, int height, int ppi, BOOL hiDPI, NSString *name, unsigned int serialNum, int refreshRate, NSArray<NSValue *> *pointModes);
