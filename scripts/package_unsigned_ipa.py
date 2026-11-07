#!/usr/bin/env python3
"""从独立Fork的真机archive打包未签名IPA；不导入证书、不清理原archive。"""
import argparse
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile

BUNDLE_ID = "dev.denis.readerfork.dev"
IPA_NAME = "Reader-Fork-Dev-unsigned.ipa"
EXTENSIONS = {BUNDLE_ID + ".widget", BUNDLE_ID + ".shareextension"}


def validate_bundle(bundle, expected_id=None):
    with (bundle / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    bundle_id = info.get("CFBundleIdentifier")
    if expected_id is not None and bundle_id != expected_id:
        raise ValueError(f"不是预期的Fork Bundle ID：{bundle.name}")
    if info.get("CFBundleSupportedPlatforms") != ["iPhoneOS"]:
        raise ValueError(f"只接受真机iPhoneOS产物，不接受模拟器：{bundle.name}")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or not (bundle / executable).is_file():
        raise ValueError(f"Bundle缺少有效可执行文件：{bundle.name}")
    return bundle_id


def package(archive, output):
    archive, output = Path(archive).resolve(), Path(output).resolve()
    apps = list((archive / "Products/Applications").glob("*.app"))
    if len(apps) != 1:
        raise ValueError("archive必须恰好包含一个主App")
    app = apps[0]
    validate_bundle(app, BUNDLE_ID)
    extensions = [validate_bundle(path) for path in (app / "PlugIns").glob("*.appex")]
    if len(extensions) != len(EXTENSIONS) or set(extensions) != EXTENSIONS:
        raise ValueError("archive缺少Fork的Widget/ShareExtension，或混入了其他扩展")
    output.mkdir(parents=True, exist_ok=True)
    ipa = output / IPA_NAME
    checksum = output / (IPA_NAME + ".sha256")
    if ipa.exists() or checksum.exists():
        raise FileExistsError("产物已存在；请选择新的输出目录，不覆盖已有IPA")
    # 只清理本次临时目录；不删除archive、用户数据或DerivedData。
    with tempfile.TemporaryDirectory(prefix=".readerfork-ipa-", dir=output) as temporary:
        stage = Path(temporary)
        shutil.copytree(app, stage / "Payload" / app.name, symlinks=True)
        staged_ipa = stage / IPA_NAME
        subprocess.run(["/usr/bin/zip", "-qry", "-y", str(staged_ipa), "Payload"], cwd=stage, check=True)
        with zipfile.ZipFile(staged_ipa) as zipped:
            if zipped.testzip() is not None:
                raise ValueError("生成的IPA ZIP校验失败")
        digest = hashlib.sha256()
        with staged_ipa.open("rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
        staged_checksum = stage / checksum.name
        staged_checksum.write_text(f"{digest.hexdigest()}  {IPA_NAME}\n", encoding="utf-8")
        staged_ipa.rename(ipa)
        staged_checksum.rename(checksum)
    return ipa


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    print(package(args.archive, args.output))


if __name__ == "__main__":
    main()
