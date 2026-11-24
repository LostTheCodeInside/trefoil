# gomobile generates JNI bridge classes that are reached only from native code.
# R8 cannot see those references, so without these rules the release build strips
# them and libbox fails at runtime with NoClassDefFoundError / UnsatisfiedLinkError.
-keep class go.** { *; }
-keep class io.nekohasekai.libbox.** { *; }
-keep class io.nekohasekai.libxray.** { *; }
-keepclasseswithmembernames class * { native <methods>; }

# Our PlatformInterface implementation is instantiated from Go via the binding.
-keep class com.lupangoding.trefoil.core.** { *; }
