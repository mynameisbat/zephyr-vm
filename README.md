# Zephyr — giả lập Android siêu nhẹ cho macOS

Zephyr chạy Android 17 (LineageOS 24, arm64) trên Mac Apple Silicon bằng **Virtualization.framework** của Apple: không QEMU, không Android SDK.

| | Zephyr | Android Emulator (Google) |
|---|---|---|
| Kích thước app | ~3 MB | SDK + emulator vài GB |
| Boot | ~6–14 s (lần đầu ~14 s) | 20–60 s |
| RAM thực (máy 2 GB) | ~2,1 GB | 3–4 GB+ |
| CPU khi rảnh | ~3 % | 10–30 % |
| GPU 3D | Không (SwiftShader, vẽ bằng CPU) | Có |
| Google Play | Không mặc định | Có (ảnh Google APIs) |

Số liệu đo trên M1 Pro, macOS 27.2.

## Build & chạy

Chỉ cần Command Line Tools (không cần Xcode):

```bash
scripts/build.sh                 # debug; CONFIG=release scripts/build.sh cho bản release
open build/Zephyr.app
```

Lần đầu mở app: bấm **Tải LineageOS (~1,1 GB)**, hoặc **Nhập từ tệp…** với một tệp `UTM-VM-lineage-*-virtio_arm64only.zip` tải từ
[jqssun/android-lineage-qemu](https://github.com/jqssun/android-lineage-qemu/releases). Sau đó bấm **+** để tạo thiết bị.

`Zephyr --open <tên>` mở và bật thẳng một thiết bị.

## Điều khiển

| Mac | Android |
|---|---|
| Click / kéo | Chạm / vuốt |
| ⌥ + kéo | Chụm 2 ngón (đối xứng qua tâm màn hình) |
| Pinch trên trackpad | Chụm 2 ngón |
| Cuộn chuột / 2 ngón trackpad | Vuốt cuộn |
| Chuột phải / chuột giữa | Back / Home |
| Bàn phím | Bàn phím USB ảo |
| Kéo-thả `.apk` vào màn hình | Cài app |

Thanh bên phải: nguồn, âm lượng, Back/Home/Gần đây, chụp màn hình (lưu ra Desktop), cài APK, thư mục chia sẻ.

ADB: mỗi thiết bị đang chạy mở `127.0.0.1:5555` (hoặc cổng lẻ tiếp theo) → `adb connect 127.0.0.1:5555`.
Thư mục `~/Library/Application Support/ZephyrVM/Shared` xuất hiện trong Android tại `/mnt/vendor/shared`.

## CLI

```bash
.build/debug/zephyrctl import UTM-VM-lineage-….zip
.build/debug/zephyrctl create pixel --display phone-fhd --memory 3072
.build/debug/zephyrctl run pixel --console     # chạy không giao diện, Ctrl-C để tắt
```

## Kiến trúc

```
Sources/
  ZephyrCore/                 engine, không phụ thuộc UI
    Disk/QCOW2Converter       qcow2 → raw sparse (VZ chỉ đọc raw)
    Disk/GPT                  đọc bảng phân vùng
    Boot/                     tách kernel + ramdisk từ boot.img / vendor_boot.img (v3/v4),
                              ghép bootconfig → boot thẳng bằng VZLinuxBootLoader (bỏ qua EFI/GRUB)
    VM/VirtualMachineFactory  cấu hình VZ: virtio-blk (vda hệ thống, vdb userdata), virtio-gpu,
                              NAT, vsock, virtio-fs, âm thanh, balloon, bàn phím USB
    VM/MachineController      vòng đời máy ảo
    VM/VsockForwarder         127.0.0.1:5555 ⇄ vsock 5555 (adbd trong Android)
    ADB/ADBClient             client giao thức ADB viết bằng Swift, chạy trên vsock
    Input/InputInjector       cảm ứng đa điểm + phím cứng qua công cụ `uinput` có sẵn của Android
  ZephyrApp/                  app SwiftUI
  zephyrctl/                  CLI
```

Mỗi thiết bị là một thư mục `Machines/<uuid>.zvm` gồm `config.json`, `system.img` (bản clone APFS copy-on-write của ảnh gốc — tạo tức thì, gần như không tốn chỗ) và `userdata.img` (file sparse, chỉ chiếm chỗ khi dùng).

## Giới hạn đã biết

- Chỉ Apple Silicon (máy ảo arm64).
- Không tăng tốc GPU: Virtualization.framework chỉ có virtio-gpu 2D, nên game 3D nặng sẽ chậm.
- Ảnh LineageOS ở chế độ SwiftShader trả màu đảo đỏ/xanh; Zephyr sửa phía Mac bằng bộ lọc Core Image.
- Chưa xoay màn hình, chưa có lưu/khôi phục trạng thái tức thì.
- SDK macOS 27 biến `@State` thành macro cần Xcode; `scripts/build.sh` tự dùng SDK 26.5 khi chỉ có Command Line Tools.
