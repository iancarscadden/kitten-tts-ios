# Kitten TTS for iOS

A native iOS app that runs [KittenTTS](https://github.com/KittenML/KittenTTS) entirely on-device.

This is (to my knowledge) the first iOS implementation that sounds 1:1 with the original Python version. Previous attempts used MisakiSwift for phonemization, which produces different phonemes than what the model was trained on. I compiled espeak-ng from source for iOS arm64 and use it directly, so the phoneme pipeline is identical to the original Python implementation. The token output matches the Python reference exactly.

## How it works

The pipeline matches the Python KittenTTS implementation step for step:

1. **Text chunking** - Split long text at sentence boundaries (max 400 chars per chunk)
2. **Phonemization** - espeak-ng converts English text to IPA phonemes (compiled as a static C library for iOS arm64)
3. **Tokenization** - IPA phonemes are mapped to token IDs using the KittenTTS vocabulary (178 symbols covering punctuation, letters, and IPA characters)
4. **ONNX inference** - Token IDs + voice style embedding + speed go into the ONNX model, raw audio waveform comes out
5. **Playback** - Float32 PCM audio at 24kHz played through AVAudioEngine (no lossy Int16 conversion)

## Features

- 8 voices: Rosie, Bella, Jasper, Luna, Bruno, Hugo, Kiki, Leo
- 3 model sizes: Nano (15M params), Micro (40M), Mini (80M)
- Adjustable speech speed (0.5x to 2.0x)
- Runs fully offline on-device
- 24kHz audio output

## Why espeak-ng instead of MisakiSwift?

KittenTTS was trained with espeak phonemes. MisakiSwift is a port of the Misaki G2P engine, which produces a completely different set of phonemes. When you feed Misaki phonemes into a model trained on espeak phonemes, the audio sounds garbled and robotic.

I cross-compiled espeak-ng (the same C library the Python version uses) as a static library for iOS arm64. The phoneme output is identical to Python's, which means the audio quality matches too.

## Building

**Requirements:**
- Xcode 26+
- iOS 18+ device (arm64)

**SPM Dependencies:**
- `onnxruntime-swift-package-manager` (Microsoft) - ONNX Runtime for inference

**Build Settings (already configured in the project):**
- Objective-C Bridging Header: `localChat/BridgingHeader.h`
- Other Linker Flags: `-lespeak-ng -lspeechPlayer -lucd -lc++`
- Library Search Paths: `$(SRCROOT)/localChat/espeak-lib`

The espeak-ng static library (`libespeak-ng.a`) and its runtime data files are included in the repo. You don't need to compile espeak-ng yourself.

Just open `localChat.xcodeproj`, let SPM resolve, build, and run.

## Project structure

```
localChat/
  KittenTTSEngine.swift       # TTS engine (phonemization, ONNX inference, playback)
  ContentView.swift            # SwiftUI interface
  BridgingHeader.h             # C bridge for espeak-ng
  Models/                      # ONNX models + voice embedding JSONs
  espeak-ng-data/              # Phoneme tables and English dictionary (~900KB)
  espeak-lib/                  # Static libraries + C bridge code
    libespeak-ng.a             # espeak-ng compiled for iOS arm64
    espeak-bridge.c            # Thin C wrapper around espeak_TextToPhonemes
    include/                   # espeak headers
  Theme/
    Colors.swift               # App color theme
```

## Key implementation details

A few things that took a while to figure out and are easy to get wrong:

**Token padding matters.** The token sequence must be `[0] + phoneme_tokens + [10, 0]`. Token 10 is the end-of-text marker. Without it the model doesn't know when to stop and the audio trails off into noise.

**Trim the last 5000 samples.** The model output has artifacts at the tail end. The Python code does `audio[..., :-5000]` and so does this implementation.

**The espeak phonememode flag is 0x02, not 0x01.** `0x01` is `espeakPHONEMES_SHOW` (ASCII mnemonic output). `0x02` is `espeakPHONEMES_IPA` (IPA Unicode output). The header comments are misleading.

**Unicode scalars, not Characters.** The vocabulary must be built by iterating Unicode scalars. Swift's `Character` type merges combining characters (like U+0329) with their neighbors, which shifts every subsequent token index and corrupts the output.

**espeak-ng data needs directory structure at runtime.** Xcode's synchronized groups flatten files into the bundle root, but espeak expects `lang/gmw/en-US` and `voices/!v/` subdirectories. I solve this by copying core data files from the bundle and writing the language definitions from Swift string literals into a Caches directory at launch.

**Speed priors.** The nano model has per-voice speed multipliers (0.8 for most voices, 0.9 for Hugo) that come from the HuggingFace config. Without them the speech is too fast.

## Credits

- [KittenTTS](https://github.com/KittenML/KittenTTS) by KittenML for the model
- [espeak-ng](https://github.com/espeak-ng/espeak-ng) for phonemization
- [ONNX Runtime](https://github.com/microsoft/onnxruntime) for on-device inference

## License

Apache 2.0 (matching KittenTTS)
