#!/usr/bin/env python3
"""给 flutter create 现场生成的平台目录打补丁。

平台目录（android/、windows/）不入库，因为里面有 gradle wrapper 这类二进制文件，
手写容易出错。但后台播放必须在 AndroidManifest 里声明前台服务和权限，
所以在这里用脚本补齐——好处是补丁本身可读、可 review，也不用把二进制塞进仓库。

用法：python3 patch_platform.py app/android [app/ios]
"""
import pathlib
import re
import sys

PERMS = """    <!-- 后台播放：前台服务 + 唤醒锁 + 通知 -->
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
    if "FOREGROUND_SERVICE" not in s:
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
        if (root / "Runner/Info.plist").exists():
            patch_plist(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
