#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
extract_vendor.py — 从 Pixel 4XL (coral) 工厂镜像提取 Qualcomm vendor 内核模块

作用:
    Android 12+ (含 Pixel 4XL Android 13) 把 vendor 内核模块打包在 vendor_dlkm.img
    里,放在 /lib/modules/<kernel-version>/ 目录。本脚本把它们拆出来,供自定义内核
    编译脚本 (build.sh) 在打包 boot.img 时一同打入 vendor_dlkm 分区。

    输出物适合作为 GitHub Actions 的输入:
        - vendor/                所有 .ko(按原目录结构)
        - load_order.txt         模块加载顺序(由 modules.dep 拓扑排序得出)
        - manifest.json          镜像元信息(内核版本、镜像 build、android 版本)
        - build.props            从 system / build.prop 抽取的关键信息

用法:
    # 1. 从工厂 ZIP 拆
    python3 scripts/extract_vendor.py coral-tp1a.220624.014-factory-xxx.zip out/

    # 2. 已经解压的目录(含 vendor_dlkm.img)
    python3 scripts/extract_vendor.py ./factory_extracted/ out/

    # 3. 直接指定 vendor_dlkm.img
    python3 scripts/extract_vendor.py path/to/vendor_dlkm.img out/

    # 4. 强制重新拆(忽略缓存)
    python3 scripts/extract_vendor.py factory.zip out/ --force

依赖:
    Linux 上需要:
        - python3 >= 3.6
        - unzip / gunzip (标准)
        - simg2img   (从 https://github.com/anestisb/android-simg2img 下载)
        - debugfs    (apt install e2fsprogs)
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


# ---------- 常量 ----------

SPARSE_MAGIC = b"\x3a\xff\x26\xed"
GZIP_MAGIC = b"\x1f\x8b"
EXT_MAGIC_OFFSET = 0x438
EXT_MAGIC = b"\x53\xef"

# upstream 从未发布 prebuilt 二进制(/releases/download/* 全部 404),
# 改用 git clone + make。需要 git / make / gcc,这些都是 kernel build 的前置依赖。
SIMG2IMG_REPO = "https://github.com/anestisb/android-simg2img"
SIMG2IMG_REF = "1.1.5"   # 最新 git tag
# 文档提示用,失败时给用户看
SIMG2IMG_SOURCE_URL = f"{SIMG2IMG_REPO}/tree/{SIMG2IMG_REF}"


# ---------- 数据结构 ----------


@dataclass
class VendorManifest:
    """vendor 拆解结果的元信息,会写到 manifest.json"""

    source: str  # 输入 zip 或目录路径
    extracted_at: str  # ISO8601 时间戳
    kernel_version: str = ""  # 如 5.10.123-android13-2-...
    android_version: str = ""  # 如 13
    build_fingerprint: str = ""  # 如 google/coral/coral:13/SP2A.220505.008/...
    build_id: str = ""
    security_patch: str = ""
    vendor_dlkm_size_kb: int = 0
    module_count: int = 0
    sha256_source: str = ""
    tool_versions: dict = field(default_factory=dict)


# ---------- 工具函数 ----------


def log(msg: str) -> None:
    """带时间戳的统一日志输出"""
    ts = datetime.now(tz=timezone.utc).strftime("%H:%M:%S")
    print(f"[extract_vendor {ts}] {msg}", file=sys.stderr, flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"[extract_vendor] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def sha256_file(path: Path) -> str:
    """计算文件 SHA-256,适合几百 MB 文件"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def which_or_die(tool: str, install_hint: str = "") -> str:
    """检查命令是否存在,返回绝对路径"""
    p = shutil.which(tool)
    if p is None:
        msg = f"找不到命令: {tool}"
        if install_hint:
            msg += f"\n  安装提示: {install_hint}"
        die(msg)
    return p


def ensure_simg2img(install_dir: Path) -> str:
    """确保 simg2img 可用,没有就从 upstream 源码编译(只需一次)"""
    local = install_dir / "simg2img"
    if local.exists() and os.access(local, os.X_OK):
        return str(local)

    # 系统 PATH 里已有(用户自己装过),直接复用
    sys_path = shutil.which("simg2img")
    if sys_path:
        return sys_path

    # 系统 PATH 里没有 -> 源码编译。注意 git/make/gcc 是 kernel build 的
    # 前置依赖,本脚本本身也只在这种环境里跑。
    log(f"simg2img 不在 PATH,正在 git clone + make to {local} ...")
    install_dir.mkdir(parents=True, exist_ok=True)
    src_dir = install_dir / "_simg2img_src"

    if shutil.which("git") is None:
        die(
            "找不到 git,无法拉取 simg2img 源码\n"
            f"  请手动编译 {SIMG2IMG_SOURCE_URL} 后把 simg2img 放到 PATH"
        )

    import subprocess
    # 用 --depth=1 + --branch 限制拉取量,只取最少的源码
    subprocess.run(
        ["git", "clone", "--depth=1", "--branch", SIMG2IMG_REF, SIMG2IMG_REPO, str(src_dir)],
        check=True,
    )
    try:
        # Makefile 一般是 POS Makefile,要 gmake;Linux 上 make 即可
        make_bin = shutil.which("gmake") or shutil.which("make")
        if make_bin is None:
            die("找不到 make/gmake,无法编译 simg2img\n"
                "  Linux:  apt install build-essential\n"
                "  macOS:  xcode-select --install")
        subprocess.run([make_bin], cwd=str(src_dir), check=True)
        # 把编译产物拷出来
        shutil.copy2(str(src_dir / "simg2img"), str(local))
        local.chmod(0o755)
    except subprocess.CalledProcessError as e:
        die(
            f"编译 simg2img 失败: {e}\n"
            f"  请手动编译 {SIMG2IMG_SOURCE_URL} 后把可执行文件放到 PATH"
        )
    finally:
        # 不论成败都清掉源码目录,保留 ~10KB 二进制
        shutil.rmtree(str(src_dir), ignore_errors=True)
    return str(local)


# ---------- 解压阶段 ----------


def detect_image_format(path: Path) -> str:
    """检测镜像格式:gzip / sparse / raw_ext4"""
    with open(path, "rb") as f:
        head2 = f.read(2)
    if head2 == GZIP_MAGIC:
        return "gzip"
    with open(path, "rb") as f:
        head4 = f.read(4)
    if head4 == SPARSE_MAGIC:
        return "sparse"
    with open(path, "rb") as f:
        f.seek(EXT_MAGIC_OFFSET)
        ext = f.read(2)
    if ext == EXT_MAGIC:
        return "raw_ext4"
    return "unknown"


def gunzip_to(src: Path, dst: Path) -> None:
    log(f"gunzip: {src.name} -> {dst.name}")
    with gzip.open(src, "rb") as fin, open(dst, "wb") as fout:
        shutil.copyfileobj(fin, fout, length=1024 * 1024)


def sparse_to_raw(simg2img: str, src: Path, dst: Path) -> None:
    log(f"simg2img: {src.name} -> {dst.name}")
    subprocess.run([simg2img, str(src), str(dst)], check=True,
                   capture_output=True)


def prepare_ext4(img: Path, work_dir: Path, simg2img: str) -> Path:
    """把 vendor_dlkm.img 统一转成 raw ext4,返回 ext4 文件路径"""
    fmt = detect_image_format(img)
    log(f"检测镜像格式: {fmt}")

    ext4 = work_dir / "vendor_dlkm.ext4"

    if fmt == "gzip":
        ungz = work_dir / "vendor_dlkm.ungz"
        gunzip_to(img, ungz)
        fmt2 = detect_image_format(ungz)
        if fmt2 == "sparse":
            sparse_to_raw(simg2img, ungz, ext4)
        elif fmt2 == "raw_ext4":
            shutil.move(str(ungz), str(ext4))
        else:
            die(f"gzip 解压后格式仍未知: {fmt2}")
    elif fmt == "sparse":
        sparse_to_raw(simg2img, img, ext4)
    elif fmt == "raw_ext4":
        shutil.copy(img, ext4)
    else:
        die(f"无法识别的镜像格式: {img}")
    return ext4


def extract_files_from_ext4(ext4: Path, out_dir: Path) -> None:
    """用 debugfs rdump 提取 vendor_dlkm 内的文件"""
    debugfs = which_or_die("debugfs", "apt install e2fsprogs")

    out_dir.mkdir(parents=True, exist_ok=True)

    # 提取全部 /lib/modules/* 下文件
    cmd = [
        debugfs, "-R",
        f"rdump /lib/modules {out_dir}",
        str(ext4),
    ]
    log(f"debugfs rdump ...")
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        die(f"debugfs 失败:\n  stdout: {res.stdout}\n  stderr: {res.stderr}")

    # debugfs 有时把目录也列出来,清理空目录
    for p in out_dir.rglob("*"):
        if p.is_dir() and not any(p.iterdir()):
            p.rmdir()


# ---------- 解析元信息 ----------


def read_build_prop(ext4: Path) -> dict:
    """从 vendor_dlkm 里读 build.prop(如果有),没有就返回 {}"""
    debugfs = which_or_die("debugfs", "")
    cmd = [debugfs, "-R", "cat /vendor/build.prop", str(ext4)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    props = {}
    if res.returncode == 0 and res.stdout:
        for line in res.stdout.splitlines():
            if "=" in line and not line.startswith("#"):
                k, _, v = line.partition("=")
                props[k.strip()] = v.strip()
    return props


def detect_kernel_version_from_modules(modules_root: Path) -> str:
    """从 lib/modules/<ver>/ 目录名推断内核版本"""
    for d in modules_root.iterdir():
        if d.is_dir():
            return d.name
    return ""


def parse_modules_dep(modules_root: Path) -> dict[str, list[str]]:
    """解析 modules.dep,返回 {module_path: [dep1, dep2, ...]}"""
    dep_file = None
    for d in modules_root.iterdir():
        cand = d / "modules.dep"
        if cand.exists():
            dep_file = cand
            break
    if dep_file is None:
        return {}
    out: dict[str, list[str]] = {}
    for line in dep_file.read_text(errors="ignore").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([^:]+):\s*(.*)$", line)
        if not m:
            continue
        mod = m.group(1).strip()
        deps = [d.strip() for d in m.group(2).split() if d.strip()]
        out[mod] = deps
    return out


def topological_load_order(modules_root: Path) -> list[str]:
    """
    按 modules.dep 反向拓扑排序得出加载顺序。
    vendor_dlkm 本身可能不提供 modules.load,所以由依赖关系推导。
    """
    dep = parse_modules_dep(modules_root)
    if not dep:
        # fallback:字典序
        return sorted(
            str(p.relative_to(modules_root)) + "\n"
            for p in modules_root.rglob("*.ko")
            for _ in [0]
        )

    # 反向依赖图:被谁依赖 -> 我要先加载
    deps_of: dict[str, set[str]] = {k: set() for k in dep}
    for mod, ds in dep.items():
        for d in ds:
            # d 可能不在 dep 里(它依赖的可能是 kernel 内置或在其他 .ko)
            deps_of.setdefault(d, set()).add(mod)

    visited = set()
    order: list[str] = []

    def visit(m: str):
        if m in visited:
            return
        visited.add(m)
        for dep_mod in dep.get(m, []):
            visit(dep_mod)
        order.append(m)

    # 找到所有 leaf(没被别的依赖的模块),从它们开始
    leaves = [m for m in dep if not deps_of.get(m)]
    for leaf in sorted(leaves):
        visit(leaf)

    return order


# ---------- 主流程 ----------


def resolve_factory_input(input_path: Path, work_dir: Path) -> tuple[Path, Optional[Path]]:
    """
    把多种输入统一成 (vendor_dlkm.img_path, system_dir)
    返回:
        vendor_dlkm_path: 解析后的 vendor_dlkm.img
        system_dir: 解压 ZIP 时一并拿到的目录(可读 build.prop)
    """
    if not input_path.exists():
        die(f"输入不存在: {input_path}")

    if input_path.is_file() and input_path.suffix.lower() == ".img":
        return input_path, None

    if input_path.is_file() and input_path.suffix.lower() == ".zip":
        log(f"解压 ZIP: {input_path.name}")
        extract_dir = work_dir / "zip_extracted"
        if extract_dir.exists():
            shutil.rmtree(extract_dir)
        extract_dir.mkdir(parents=True)
        with zipfile.ZipFile(input_path) as zf:
            zf.extractall(extract_dir)
        return resolve_factory_input(extract_dir, work_dir)

    if input_path.is_dir():
        # 先找 vendor_dlkm.img
        for cand in [input_path / "vendor_dlkm.img",
                     input_path / "image-coral-*" / "vendor_dlkm.img"]:
            for p in input_path.glob(str(cand.relative_to(input_path))):
                if p.is_file():
                    return p, input_path
        # 嵌套一层
        for img in input_path.glob("**/vendor_dlkm.img"):
            return img, input_path
        die(f"在 {input_path} 里找不到 vendor_dlkm.img")

    die(f"无法解析输入: {input_path}")


def main() -> None:
    ap = argparse.ArgumentParser(
        description="从 Pixel 4XL (coral) 工厂镜像提取 vendor_dlkm 内核模块",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("input", type=Path,
                    help="工厂 ZIP、解压目录、或 vendor_dlkm.img 路径")
    ap.add_argument("out", type=Path,
                    help="输出目录")
    ap.add_argument("--work", type=Path, default=None,
                    help="中间工作目录(默认 <out>/.work)")
    ap.add_argument("--force", action="store_true",
                    help="即使 manifest.json 已存在也强制重新拆")
    args = ap.parse_args()

    out: Path = args.out.resolve()
    work: Path = (args.work or out / ".work").resolve()
    work.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)

    manifest_path = out / "manifest.json"
    if manifest_path.exists() and not args.force:
        log(f"已存在 {manifest_path},跳过(--force 强制重跑)")
        return

    # 解析输入
    vendor_img, sys_dir = resolve_factory_input(args.input.resolve(), work)
    log(f"vendor_dlkm.img: {vendor_img}")

    # 准备 simg2img + debugfs
    simg2img = ensure_simg2img(work)
    which_or_die("debugfs", "apt install e2fsprogs")

    # sparse / gzip / ext4 -> raw ext4
    ext4 = prepare_ext4(vendor_img, work, simg2img)

    # 收集工具版本
    tool_versions = {}
    for tool in ("debugfs",):
        try:
            r = subprocess.run([tool, "-V"], capture_output=True, text=True)
            tool_versions[tool] = (r.stdout + r.stderr).strip().split("\n")[0]
        except Exception:
            pass

    # 提取文件
    vendor_ko_dir = out / "vendor"
    if vendor_ko_dir.exists():
        shutil.rmtree(vendor_ko_dir)
    extract_files_from_ext4(ext4, vendor_ko_dir)
    ko_files = list(vendor_ko_dir.rglob("*.ko"))
    log(f"提取到 {len(ko_files)} 个 .ko")

    if not ko_files:
        die("vendor_dlkm 里没找到任何 .ko,请确认这是 Pixel 4XL 镜像")

    # 推断内核版本(lib/modules/<ver>/)
    modules_root = vendor_ko_dir
    kernel_version = detect_kernel_version_from_modules(modules_root)

    # 生成 load_order
    load_order = topological_load_order(modules_root)
    (out / "load_order.txt").write_text("\n".join(load_order) + "\n")
    log(f"load_order.txt: {len(load_order)} 个条目")

    # 读 build.prop
    build_prop = read_build_prop(ext4)

    # 组装 manifest
    manifest = VendorManifest(
        source=str(args.input.resolve()),
        extracted_at=datetime.now(timezone.utc).isoformat(),
        kernel_version=kernel_version,
        android_version=build_prop.get("ro.build.version.release", ""),
        build_fingerprint=build_prop.get("ro.build.fingerprint", ""),
        build_id=build_prop.get("ro.build.id", ""),
        security_patch=build_prop.get("ro.build.version.security_patch", ""),
        vendor_dlkm_size_kb=ext4.stat().st_size // 1024,
        module_count=len(ko_files),
        sha256_source=sha256_file(args.input),
        tool_versions=tool_versions,
    )
    manifest_path.write_text(json.dumps(asdict(manifest), indent=2, ensure_ascii=False))
    log(f"manifest.json: kernel={manifest.kernel_version} "
        f"android={manifest.android_version} modules={manifest.module_count}")

    # 顺手把 build.prop 复制出来(便于人工核对)
    if build_prop:
        (out / "build.prop.txt").write_text(
            "\n".join(f"{k}={v}" for k, v in build_prop.items()) + "\n"
        )

    log(f"完成 -> {out}")
    log(f"  vendor_ko_dir: {vendor_ko_dir}")
    log(f"  manifest:      {manifest_path}")
    log(f"  load_order:    {out / 'load_order.txt'}")


if __name__ == "__main__":
    main()