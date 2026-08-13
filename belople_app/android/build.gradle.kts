allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// rtmp_broadcaster (the Live RTMP publisher) was last published 17 months ago
// and still declares `compileSdkVersion 33`, which AGP now refuses outright:
// its own transitive AndroidX dependencies require 34 or newer. Raising the
// plugin's compileSdk to the app's is safe on its own — compileSdk only says
// which APIs the code may reference while compiling, not which devices it runs
// on (that's minSdk, untouched at 24) or which behaviour it opts into
// (targetSdk, also untouched).
//
// Applied to every subproject rather than named, so the next stale plugin
// doesn't cost another build cycle to diagnose.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val android = ext as com.android.build.gradle.BaseExtension
            if (android.compileSdkVersion?.removePrefix("android-")?.toIntOrNull()
                    ?.let { it < 36 } == true) {
                android.compileSdkVersion(36)
            }
        }
    }
}

// Must stay AFTER the compileSdk fixup above: this forces every subproject to
// evaluate, and afterEvaluate cannot be registered on a project that already
// has.
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
