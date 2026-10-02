#!/usr/bin/env python3
"""给 flutter create 现场生成的平台目录打补丁。

平台目录（android/、windows/）不入库，因为里面有 gradle wrapper 这类二进制文件，
手写容易出错。但后台播放必须在 AndroidManifest 里声明前台服务和权限，
所以在这里用脚本补齐——好处是补丁本身可读、可 review，也不用把二进制塞进仓库。

用法：python3 patch_platform.py app/android [app/ios]
"""
import pathlib
import re
import shutil
import sys

PERMS = """    <!-- 必须手动加：flutter create 只把 INTERNET 写进 debug/profile 的 manifest，
         release 包没有它，所有网络请求都会变成 "Failed host lookup"（DNS 解析失败）。 -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <!-- 后台播放：前台服务 + 唤醒锁 + 通知 -->
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
"""

SERVICE = """        <!-- audio_service：后台播放需要的前台服务与媒体按键接收器 -->
        <service
            android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback"
            android:exported="true">
            <intent-filter>
                <action android:name="android.media.browse.MediaBrowserService"/>
            </intent-filter>
        </service>
        <receiver
            android:name="com.ryanheise.audioservice.MediaButtonReceiver"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MEDIA_BUTTON"/>
            </intent-filter>
        </receiver>
"""


def patch_manifest(root: pathlib.Path) -> None:
    mf = root / "app/src/main/AndroidManifest.xml"
    if not mf.exists():
        print(f"!! 找不到 {mf}")
        return
    s = mf.read_text()
    changed = []
    if "android.permission.INTERNET" not in s or "FOREGROUND_SERVICE" not in s:
        s = s.replace("    <application", PERMS + "    <application", 1)
        changed.append("权限")
    if "audioservice.AudioService" not in s:
        s = s.replace("    </application>", SERVICE + "    </application>", 1)
        changed.append("前台服务")
    mf.write_text(s)
    print(f"manifest 已补：{'、'.join(changed) if changed else '无需改动'}")


def patch_gradle(root: pathlib.Path) -> None:
    """media_kit 的原生库要求 minSdk 至少 24，模板默认值未必够"""
    for name in ("app/build.gradle.kts", "app/build.gradle"):
        f = root / name
        if not f.exists():
            continue
        s = f.read_text()
        new = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", s)
        new = re.sub(r"minSdkVersion\s+flutter\.minSdkVersion", "minSdkVersion 24", new)
        if new != s:
            f.write_text(new)
            print(f"{name} 已把 minSdk 提到 24")
        else:
            print(f"{name} 未改（可能已是固定值）")
        return
    print("!! 未找到 app/build.gradle{,.kts}")


def patch_gradle_properties(root: pathlib.Path) -> None:
    """一些老插件（如 media_kit_video 依赖的 volume_controller）Kotlin 目标是 1.8，
    而 Flutter 把 Java 目标设成 11，Gradle 会因此直接报
    「Inconsistent JVM Target Compatibility」而中断构建。
    这个校验是保守检查，两者字节码在 D8 上能共存，所以降级为警告。
    比注入一堆 Kotlin DSL 去统一 jvmTarget 安全得多。"""
    f = root / "gradle.properties"
    if not f.exists():
        print(f"!! 找不到 {f}")
        return
    s = f.read_text()
    if "kotlin.jvm.target.validation.mode" in s:
        print("gradle.properties 已有 jvm target 校验设置")
        return
    s += ("\n# 老插件的 Kotlin 目标 (1.8) 与 Flutter 设的 Java 目标 (11) 不一致，\n"
          "# 默认会让 Gradle 直接中断；这只是保守校验，字节码能共存。\n"
          "kotlin.jvm.target.validation.mode=warning\n")
    f.write_text(s)
    print("gradle.properties 已把 jvm target 校验降级为 warning")


def patch_plugin_gradles(compile_sdk: int = 36) -> None:
    """把 pub cache 里插件的 compileSdk 提到 compile_sdk。

    为什么必须动第三方文件：media_kit_video 把自己的 compileSdk 钉在 31，
    而它依赖的 wakelock_plus 要求「依赖它的工程必须编译到 API 36」，
    AAR metadata 校验直接让构建失败。插件不是我们的代码，
    flutter 也没有覆盖单插件 compileSdk 的正式手段，只能改它的 gradle。
    """
    cache = pathlib.Path.home() / ".pub-cache" / "hosted" / "pub.dev"
    if not cache.exists():
        print("!! 找不到 pub cache，跳过插件 compileSdk 补丁")
        return
    patched = []
    for f in sorted(cache.glob("*/android/build.gradle*")):
        s = f.read_text()

        def bump(m: re.Match) -> str:
            cur = int(m.group("num"))
            if cur >= compile_sdk:
                return m.group(0)
            sep = " = " if "=" in m.group("eq") else " "
            return f"{m.group('name')}{sep}{compile_sdk}"

        new = re.sub(
            r"(?P<name>compileSdk|compileSdkVersion)(?P<eq>\s*=\s*|\s+)(?P<num>\d+)",
            bump, s)
        if new != s:
            f.write_text(new)
            patched.append(f.parent.parent.name)
    print(f"提了 compileSdk 的插件（{len(patched)} 个）：{', '.join(patched) or '无'}")


def patch_icons(root: pathlib.Path) -> None:
    assets = pathlib.Path(__file__).resolve().parent.parent / "assets/icon"
    android = root / "app/src/main/res"
    if android.exists():
        sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96,
                 "xxhdpi": 144, "xxxhdpi": 192}
        for density, size in sizes.items():
            target = android / f"mipmap-{density}/ic_launcher.png"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(assets / f"icon-{size}.png", target)
        print("Android launcher 图标已替换")
    windows = root / "runner/resources/app_icon.ico"
    if windows.parent.exists():
        shutil.copyfile(assets / "biliweb.ico", windows)
        print("Windows 图标已替换")


def patch_plist(root: pathlib.Path) -> None:
    plist = root / "Runner/Info.plist"
    if not plist.exists():
        return
    s = plist.read_text()
    if "UIBackgroundModes" in s:
        print("Info.plist 已有 UIBackgroundModes")
        return
    s = s.replace(
        "</dict>\n</plist>",
        "\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t</array>\n</dict>\n</plist>",
        1,
    )
    plist.write_text(s)
    print("Info.plist 已加 UIBackgroundModes: audio")


def main() -> int:
    for arg in sys.argv[1:]:
        root = pathlib.Path(arg)
        if not root.exists():
            print(f"跳过不存在的 {root}")
            continue
        print(f"== 打补丁 {root} ==")
        if (root / "app/src/main/AndroidManifest.xml").exists():
            patch_manifest(root)
            patch_gradle(root)
            patch_gradle_properties(root)
            patch_plugin_gradles()
        patch_icons(root)
        if (root / "Runner/Info.plist").exists():
            patch_plist(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
