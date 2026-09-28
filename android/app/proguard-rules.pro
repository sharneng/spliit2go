# ML Kit (#125). The text recognition and Document Scanner libraries each
# bundle their own copies of Google's internal ML Kit classes. Shrinking a
# release build left the Document Scanner calling into text recognition's
# copy, and starting it threw a NullPointerException inside ML Kit (seen on
# a phone and reproduced on the emulator; debug builds, which aren't shrunk,
# were fine). Keep them as they ship.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google.android.gms.vision.** { *; }
