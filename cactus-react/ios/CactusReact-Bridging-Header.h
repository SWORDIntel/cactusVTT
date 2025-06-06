//
//  Use this file to import your target's public headers that you would like to expose to Swift.
//
#ifndef CactusReact_Bridging_Header_h
#define CactusReact_Bridging_Header_h

// React Native imports - these are common and might be needed
#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTLog.h>

// If you are using Swift modules that need to be exposed to Objective-C,
// the Xcode build system often handles the necessary `-Swift.h` import automatically.
// However, if you encounter issues, you might need to add an explicit import like:
// #import "YourProjectName-Swift.h"
// For this project, if AudioInputModule.swift needs explicit exposure beyond what
// RCT_EXTERN_MODULE provides, it would be:
// #import "CactusReact-Swift.h"
// But typically, for React Native native modules, this specific import in the bridging header
// for the module itself is not required, as `RCT_EXTERN_MODULE` handles the discovery.

// STT FFI Function Declarations for Swift
void* RN_STT_init(const char* model_path, const char* language);
void RN_STT_free(void* stt_context_ptr);
void RN_STT_setUserVocabulary(void* stt_context_ptr, const char* vocabulary);
const char* RN_STT_processAudioFile(void* stt_context_ptr, const char* file_path);
void RN_STT_free_string(char* str_ptr);

#endif /* CactusReact_Bridging_Header_h */
