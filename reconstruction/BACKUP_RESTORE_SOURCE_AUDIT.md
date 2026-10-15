# G-11 — Backup/Restore: kiểm toán luồng mã gốc và reconstruction

**Ngày rà soát:** 2026-10-15  
**Phạm vi:** chỉ phân tích mã nguồn/IDA export tại workstation; không chạy backup, restore, giải nén hoặc sửa dữ liệu thiết bị.  
**Kết luận:** **CHƯA TRIỂN KHAI G-11**. Hai nút trên Root Settings hiện là fail-closed alerts. Không được bật thao tác restore chỉ vì CI build xanh.

## 1. Hiện reconstruction thực sự làm gì?

| Tầng | Thành phần trong reconstruction | Hoạt động hiện tại | Khoảng trống |
| --- | --- | --- | --- |
| Settings / Root | `sources/prefs/CRPreferences.m`: `createMultiBackupTapped`, `restoreMultiBackupTapped` | Gọi `presentUnavailableBackupAction:` và hiển thị thông báo; không tạo archive, không giải nén | Không có controller cấu hình, picker, progress, delegate hoặc job |
| Settings / container | `sources/prefs/CRPreferences.m` | Có cấu hình container và thao tác lifecycle khác | Chưa thấy entry point single backup/restore gọi `CRPBackupRestoreController` |
| Backup/restore job | `sources/prefs/` | Không tồn tại `CRPBackupOperation`, `CRPRestoreOperation`, `CRPBackupRestoreController`, `CRPBackupContainer` bản reconstruction | Thiếu pipeline, serialization, quota, hủy, mapping, integrity checks |
| ZIP | Preferences bundle reconstructed | Không có backend `SSZipArchive` phục vụ G-11 | Phải bảo đảm ZIP/AES/password/symlink/thuộc tính tương thích định dạng gốc |
| Container paths | `sources/libcrane/CRManager.m` | `enumerate:pathsAssociatedToContainerWithIdentifier:...`, `pathsAssociated...` lấy app/group/PlugInKit paths; `moveOrCopyContainerFromPath:toPath:move:` và `wipeContainer...` có implementation | Các API hiện tại không phải một transaction restore, có nhánh im lặng/không trả kết quả |
| Keychain helper | `sources/cranehelperd/CRHelperd.m` | PreferencesService và GlobalService có các selector dump/restore nhưng dump trả **nil**, restore ghi log và không thực hiện; migration cũng chưa có | Không được phân biệt `nil` với bản dump rỗng hợp lệ; không được giả vờ restore thành công |
| Document/CI | `ORIGINAL_VS_CURRENT_GAP_PLAN.md`; `check_root_actions_contract.py` | Theo dõi G-11, khóa hành vi UI chưa có backend | Chưa có smoke/fixture cho ZIP gốc, differential round trip |

**Giới hạn đánh giá:** trạng thái kiểm thử Python, macOS CI và nhánh sạch chỉ chứng minh source/package hiện tại. Chưa chứng minh archive của Crane gốc có thể đọc/ghi bởi reconstruction.

## 2. Luồng điều khiển gốc: backup

Chứng cứ: `Library/PreferenceBundles/CranePrefs.bundle/CranePrefs_export_for_ai/decompile/` và `analysis/objc_classes.json`.

1. **Entry:** `CRPRootListController createMultiBackupTapped` **0x20E64**. Nếu có file ở `_fileInInteractionController` thì chia sẻ file cũ bằng `openShareMenuWithFile:` (**0x20EFC**); nếu không thì gọi `CRPBackupRestoreController configureAndStartMultiBackup` (**0x2614C**). Không phải mỗi lần nhấn đều tạo file mới.
2. **Cấu hình:** `CRPNewBackupListController initForMultiContainerSelection` (**0x1A604**) + `_configureAndStartBackupWithConfigurationListController:` (**0x26048**); chọn container/preset, tên file, mật khẩu, mã hóa và có đưa Keychain vào hay không. `createButtonPressed` (**0x1B420**) chặn mật khẩu rỗng khi bật mã hóa, có dialog xác nhận mật khẩu.
3. **Tạo job:** `didFinishConfiguringBackupWithListController:` (**0x2619C**) dựng `CRPBackupOperation` cùng đường dẫn `/var/mobile/Library/Crane/tmp/<fullBackupFilename>`, gán danh sách container, password, includeKeychain và cờ multi; chạy qua `processOperation:completion:` (**0x27660**).
4. **Job `main` 0x25A8C:** mở `SSZipArchive`, chuẩn bị số bước (`prepareBackup` 0x2440C), kiểm tra dung lượng (`handleFreeSpaceCheck` 0x23F60), duyệt container và ghi từng container (`processBackupOfContainer:` 0x24CF8), thêm index multi (`addMultiBackupInformation` 0x257AC), xóa file target nếu cancel (0x25A18), đóng ZIP khi hoàn tất (0x25A74).
5. **Mỗi container 0x24CF8:** lấy `applicationIdentifier`, `containerIdentifier`, `containerName`, `deviceIdentifierForVendor` nếu có và `originalPaths` từ `CraneManager`, ghi `Info.plist`; tùy chọn gọi helper dump Keychain để ghi `Keychain.plist`; duyệt các path liên quan và ghi file/thư mục, đồng thời thu thập thuộc tính file vào `Metadata.plist` (nếu có).
6. **Dữ liệu file:** `processBackupOfPath:withIdentifier:pathPrefix:collectAttributes:` (**0x24774**) sử dụng `_enumerate:filesOfContainerPath:cachedProperties:`. Block `sub_24948`: ZIP folder riêng, file thường, và file rỗng qua `writeData`; `NSFileManager attributesOfItemAtPath:` rồi lọc các thuộc tính không thể ghi qua `CRPBackupContainer attributeDictionaryWithNonWritableAttributesFilteredOut:` (**0x23124**).
7. **Kết quả UI:** gốc `didFinishBackupAtPath:` (**0x20E98**) chuyển đường dẫn thành file URL, mở `UIDocumentInteractionController` để chia sẻ; `openShareMenuWithFile:` có tham chiếu cached-cell và fallback view.

### Định dạng archive quan sát được

Trường hợp backup đơn (root ZIP):
```text
<backup single container>  (đuôi do giao diện gốc chỉ định: .cranect)
├── Info.plist          # binary property list; per-container metadata
├── Keychain.plist      # tùy chọn; chỉ nếu helper dump thành công và serialization hợp lệ
├── Metadata.plist      # tùy chọn; keyed writable filesystem attributes
└── <associatedID>/...  # dữ liệu app, App Group, PlugInKit; identifier từ manager
```

Trường hợp backup nhiều container:
```text
<backup multiple containers>.cranebk
├── Info.plist          # chứa "containedContainers": [dictionaryRepresentation, ...]
└── <applicationID>/
    └── <containerID>/
        ├── Info.plist
        ├── Keychain.plist    # optional
        ├── Metadata.plist    # optional
        └── <associatedID>/...
```

**Khóa per-container `Info.plist` đã xác nhận ở 0x24CF8:** `applicationIdentifier`, `containerIdentifier`, `containerName`, `originalPaths`, `deviceIdentifierForVendor` (tùy chọn). **Khóa root multi-index:** `containedContainers` ở 0x257AC; mỗi phần tử đến từ `CRPBackupContainer dictionaryRepresentation` 0x235F0 (`applicationIdentifier`, `containerIdentifier`, `containerName`). `NSPropertyListSerialization` truyền `format=200` (binary plist) trong các bước nêu trên. ZIP write API dùng `compressionLevel=0xFFFFFFFF`, `password=_passwordToUse`, `AES=0` (cần test fixture để xác nhận interoperability mã hóa cụ thể). 

**Quan trọng:** Không khẳng định sơ đồ này bao trùm mọi nhánh/phiên bản định dạng; metadata relative-path, symbolic link, special files, empty file và ZIP UTF-8 flags cần xác nhận bằng một archive thực tế. Trong nguồn có legacy keys `originalPath` và `applicationGroups` được restore đọc thay cho `originalPaths` khi cần, nên chỉ đọc schema mới là chưa đủ.

## 3. Luồng điều khiển gốc: restore

1. **Entry/UI:** Root `restoreMultiBackupTapped` **0x211A8** → `configureAndStartMultiRestoreWithCompletion:` **0x26D7C** → `_openFilePickerForBackupWithExtension:completion:` **0x26468**; extension multi `cranebk`. Single restore 0x26B3C truyền `cranect`. `documentPicker:didPickDocumentsAtURLs:` 0x26AF0 lấy URL đầu tiên.
2. **Restore job:** `CRPRestoreOperation initWithBackupPath:` **0x28D10**; `isMultiContainerBackup` **0x28D90** xác định bằng `pathExtension == "cranebk"` (cần xác thực ZIP nội dung, không thể chỉ dựa vào đuôi file).
3. **Prepare `main` 0x2B9B0:** tạo đường dẫn tạm `/var/mobile/Library/Crane/tmp/<UUID>`, kiểm tra target cho single restore, dung lượng (`handleFreeSpaceCheck` 0x28FE0: ước lượng **1.2 × kích thước file archive**), yêu cầu/kiểm thử mật khẩu (`retrievePasswordIfNeeded` 0x292EC).
4. **Read index:** `loadBackupInfo` **0x29504** chỉ giải nén `Info.plist` và đọc dictionary, xóa file Info tạm; multi khôi phục `containedContainers`, single tạo một `CRPBackupContainer`. Nhánh không có app hợp lệ có thể báo `NO_APPS_INSTALLED_ERROR`.
5. **Mapping:** `determineBackupsToRestore` **0x29A84**: multi tạm dừng cho UI chọn/match `containersInBackup` (event 2); single liên kết backup source với `single_targetContainer`. `handleAppIdentifierCheck` **0x29CAC** từ chối single restore nếu bundle ID khác (restoreError code 1).
6. **Giải nén:** `extractBackup` **0x29F54** gọi `SSZipArchive unzipFileAtPath:toDestination:overwrite:password:progressHandler:completionHandler:` với `overwrite=NO`.
7. **Kiểm tra định danh group:** `handleGroupIdentifierCheckForBackupContainer:targetContainer:` **0x2A298** đọc `originalPaths` hoặc legacy `applicationGroups` + `originalPath` từ Info; so với các associated paths DEFAULT trên thiết bị đích, có thể hiển thị event 3 cho người dùng xác nhận mismatch.
8. **Restore từng mapping:** block `sub_2BF9C` từ `main` gọi **theo thứ tự**: `target createIfNotExists` → `restoreMetadataOfContainer:` (0x2A848) → `restoreBackupContainer:intoContainer:` (0x2ADA0) → `updatePathsOfContainer:withBackupContainer:` (0x2B31C).
9. **Bước có tính phá hủy 0x2ADA0:** yêu cầu reload nếu target đang active, gọi `CraneManager wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:NO`, sau đó duyệt các path đích và gọi `moveOrCopyContainerFromPath:toPath:move:YES` cho thành phần đã giải nén. Nếu có `Keychain.plist`, gọi helper PreferencesService restore Keychain; nếu Info chứa `deviceIdentifierForVendor`, ghi lại ID thiết bị của container.
10. **Đổi đường dẫn metadata 0x2B31C:** ánh xạ `originalPaths` từ nguồn sang path mới dựa vào `_replacementPartForPath:`; dùng `_applyReplacementStrings:forPlistsAtPath:` dưới `Library/Preferences` cho từng associated path đích. Đây là lý do giải nén/chép đè thô chưa tương đương bản gốc.

**Lưu ý về tính chất chứng cứ:** các lời gọi và thứ tự trên có bằng chứng trực tiếp từ hàm/bock decompile. Điều kiện nội bộ của `sub_2BF14`, thư viện ZIP hoặc hành vi phức tạp của helper chưa được xác minh đầy đủ; đây không phải một đặc tả byte-level hoàn chỉnh.

## 4. Tại sao không thể chỉ nối selector cũ với manager hiện tại?

1. **Nguy cơ mất dữ liệu:** `CRManager.m wipeContainer...shouldRepopulate:NO` hiện có hành vi xóa thư mục; nguyên mẫu restore gốc gọi nó trước khi chuyển file. Không có transaction/rollback xuyên app/group/plugin/keychain.
2. **Không có trạng thái lỗi tin cậy:** `moveOrCopyContainerFromPath:toPath:move:` hiện trả `void`, gọi `NSFileManager` nhưng không trả thành công/thất bại. Restore cần xác nhận copy/move từng path, phân biệt thiếu nguồn, thiếu đích, target đang active, quyền sandbox và lỗi disk-full.
3. **Khác biệt logic wipe:** bản reconstruction từ chối xóa một số target không an toàn/active bằng `cr_canModifyStoredContainer`, khác ý nghĩa của lời gọi gốc; `wipe` trả `void` khiến caller khó biết hành vi đã bị từ chối.
4. **Vị trí dữ liệu:** `pathsAssociated...` trong reconstruction lấy app home + group + PlugInKit qua runtime `LSApplicationProxy`. Không được tự suy diễn đường dẫn từ một bundle ID trong archive; chính originalPaths→currentPaths có thể khác giữa máy/phiên bản iOS.
5. **Keychain:** `CRHPreferencesService` và `CRHGlobalService` trong helper hiện trả `nil` khi dump, restore không làm gì. Chạy backup với includeKeychain mà không phân biệt lỗi có thể tạo backup không đầy đủ rồi báo thành công; chạy restore có thể bỏ sót dữ liệu bảo mật.
6. **Khả năng tin cậy ZIP:** phải xác minh entry names, traversal (`../`), absolute paths, symlink escaping, ZIP bomb, duplicate member, giới hạn decompression, metadata không đáng tin và độ hợp lệ của plist **trước** khi đụng container thật.
7. **Định dạng mật khẩu/thuộc tính:** `SSZipArchive` có các nhánh riêng cho file rỗng, thư mục, link và flags mật khẩu. Cần round-trip kiểm thử từ ít nhất một fixture gốc, không thể lấy việc `AES=0` trong call site làm bằng chứng duy nhất rằng mọi file cùng thuật toán mã hóa.
8. **Ràng buộc bản gốc:** `handleGroupIdentifierCheck...` có prompt xác nhận mismatch; bản mới không nên tự động bỏ qua cảnh báo hoặc tự động ánh xạ sang DEFAULT.

## 5. Phương án triển khai theo bằng chứng (chưa thực thi)

| Giai đoạn | Sản phẩm cụ thể | Điều kiện hoàn thành |
| --- | --- | --- |
| **A — chỉ đọc** | Khai báo schema ZIP Info/Metadata/Keychain, parser listing/validation cho `.cranect` và `.cranebk` | Test read-only với archive Crane gốc; reject malformed/malicious ZIP; không tạo file, không sửa container |
| **B — archive compatibility** | Backup formatter cho app/group/plugin, directory/empty-file/attributes, path prefix, binary plist | Byte-level field comparison với archive mẫu; single & multi round-trip trên fixture tạm, không dùng dữ liệu máy chính |
| **C — Keychain adapter** | Khôi phục dump/restore có trạng thái lỗi, phân biệt nil và dữ liệu rỗng; cảnh báo SEP omitted | Device validation cùng G-04; không cho phép tùy chọn includeKeychain nếu chưa sẵn sàng |
| **D — transaction restore** | Preflight app/group ID, path ownership, available space, backup snapshot, apply/rollback rõ ràng | Mọi đường dẫn đích được xác thực; lỗi copy/move/wipe được propagate; fail-safe không xóa dữ liệu người dùng |
| **E — UI** | `CRPNewBackupListController`, `CRPBackupRestoreController`, progress, picker, mapping, share | Chỉ mở tính năng ghi sau khi A-D pass và device test qua hai container; remove fail-closed alerts khi backend đã đủ an toàn |

### Nguyên tắc giữ nguyên hiện trạng

- **Không sửa** `cranehelperd`, `CraneSB`, injection fixup, securityd hook hoặc logic wipe chỉ để "kích hoạt" backup.
- **Không tự tạo** archive có keychain rỗng khi helper báo nil.
- **Không restore** file ZIP người dùng cung cấp trực tiếp vào một associated path; phải qua preflight mapping và staging.
- **Không báo "đã backup/restore"** nếu bất kỳ bước nào chưa thể xác nhận thành công.

## 6. Lần kiểm chứng kế tiếp

- Dùng **fixture không chứa dữ liệu cá nhân** xuất từ Crane gốc (một backup đơn không mã hóa, một multi, một có password, một có group/plugin path nếu có) trên app thử nghiệm. Nếu không có fixture gốc, chỉ được kiểm thử schema tĩnh và reject-path, **chưa công bố tương thích**.
- Đối chiếu các blocks `sub_244C0`, `sub_2BF14`, `sub_26E18`, `sub_2A050`, `sub_2A0D8` và `CRPBackupContainer` ownership checks; xác định chi tiết lỗi và event delegate.
- Thêm smoke test read-only, với tài liệu hóa rõ **PASS_STATIC**, **PASS_NATIVE** và **PASS_DEVICE** để không đánh đồng.


## 7. Triển khai giai đoạn A: bộ đọc ZIP chỉ kiểm tra cấu trúc (2026-10-15)

**Đã thêm:** `reconstruction/tools/crane_backup_inspector.py`, sử dụng Python `zipfile` ở chế độ `r` với `plistlib`. Đây là **tool chạy offline**, không được đóng gói vào tweak; không gọi `extract`, `extractall`, `CraneManager`, daemon hoặc helper.

**Cách sử dụng (không sửa file):**

```sh
python3 reconstruction/tools/crane_backup_inspector.py /path/to/sample.cranect
python3 reconstruction/tools/crane_backup_inspector.py /path/to/sample.cranebk
```

**Mã thoát / trạng thái JSON:**

- `0` — `structural_pass_not_verified`: các kiểm tra ZIP header, path và plist index cơ bản đạt; **chưa xác minh CRC tất cả payload, tính chân thực của file hoặc khả năng restore**.
- `1` — `invalid`: sai định dạng, traversal, symlink, tên file trùng, schema không hợp lệ hoặc missing member.
- `2` — `unsupported_not_validated`: ZIP mã hóa, tỷ lệ nén bất thường, giới hạn kích thước/số file hoặc phương thức nén chưa hỗ trợ. **Không coi đó là archive không hợp lệ** khi chưa có decoder tương thích.

**Các bước xác thực:** kiểm tra đuôi `.cranect` / `.cranebk`; giới hạn entry count, size và tỷ lệ nén; không theo/giải nén symlink, chặn absolute/traversal/control/drive path, duplicate/case-collision và parent-file collision; xác thực `Info.plist` với `originalPaths` hoặc cặp legacy `applicationGroups` / `originalPath`, `containedContainers` của multi, mọi `(appID, containerID)` và prefix; `Metadata.plist` chỉ parse khi <=2 MiB và path thuộc associatedID; không đọc **nội dung** `Keychain.plist` hay file app.

**Giới hạn bảo vệ mặc định:** tối đa 100.000 ZIP members, 4 GiB một member, 16 GiB tổng claimed size, max ratio 1000, tên <=1024 ký tự, độ sâu <=32, Info/Metadata <=2 MiB. Đây là **giới hạn thận trọng của inspector**, không phải giới hạn định dạng Crane gốc. Các archive lớn hoặc mã hóa sẽ được đánh dấu `unsupported_not_validated`.

**Fixture/CI:** `test_crane_backup_inspector.py` tạo archive tổng hợp trong thư mục tạm cho single, multi, legacy paths và các trường hợp sai (traversal, symlink, duplicate, mismatch, password bit, ZIP bomb). `check_backup_inspector_contract.py` chứng minh không dùng hàm giải nén/ghi và giữ Root handlers fail-closed; cả hai chạy trong `.github/workflows/build.yml`.

**LƯU Ý:** các fixture được sinh từ schema decompile, **chưa có fixture `.cranect`/`.cranebk` thật từ ứng dụng dùng thử Crane gốc**. PASS tại giai đoạn A không đồng nghĩa binary compatibility. Kế tiếp: kiểm tra đối chiếu archive gốc không chứa dữ liệu riêng tư và đánh giá mọi sai lệch schema trước khi định nghĩa writer.

## 8. G-11 giai đoạn A2 — kiểm tra CRC có giới hạn (2026-10-15)

Bổ sung chức năng **tùy chọn** vào inspector tại `tools/crane_backup_inspector.py`. Không thêm backend ghi/restore vào Preferences hoặc helper.

```sh
# Nhanh, chỉ kiểm tra ZIP index và plist cấu trúc
python3 reconstruction/tools/crane_backup_inspector.py sample.cranect

# Đọc tuần tự các payload không phải Keychain (giới hạn 256 MiB),
# bắt lỗi CRC và local-header không khớp; tuyệt đối không giải nén
python3 reconstruction/tools/crane_backup_inspector.py sample.cranebk --verify-payload
```

- **`non_keychain_payload_crc_verified`:** `true` chỉ khi tất cả các entry không phải Keychain được đọc hết bằng chunk 1 MiB và CRC từ ZIP reader không báo lỗi.
- **`payload_crc_verified`:** `true` chỉ khi tùy chọn `--verify-payload` hoàn tất **và backup không chứa `Keychain.plist`**. Có Keychain thì vẫn `false`, kể cả khi các tệp khác hợp lệ.
- **`keychain_contents_read`:** luôn `false`. Không kiểm CRC hoặc kiểm chứng nội dung Keychain trong công cụ này. `crc_checked_bytes` cho biết số byte **không phải Keychain** đã kiểm; không phải số byte restore.
- **Ngưỡng tùy chọn:** `MAX_VERIFY_BYTES=256 MiB` cho tổng các tệp không phải Keychain. Vượt giới hạn => `unsupported_not_validated` (exit 2) **trước khi bắt đầu streaming**.
- **Phát hiện sửa đổi:** CLI chế độ mặc định không xác minh mọi payload; opt-in CRC có thể phát hiện corruption hoặc local ZIP header lệch so với central index. CRC không phải chữ ký mật mã, nên **không chứng minh tính chân thực hay khả năng khôi phục**.
- **Kiểm thử:** thêm 5 bài unittest độc lập (CRC của file bị sửa, Keychain bị sửa nhưng bỏ qua như đã cam kết, local ZIP header mismatch, verify budget, CLI không thay đổi file). Tổng fixture synthetic hiện 17 bài; contract source bảo vệ `--verify-payload` và skip Keychain. CI đang chạy suite bằng discovery nên tự bao gồm các ca mới.
- **Fixture thực:** đã kiểm tra workspace nhưng không tìm thấy `.cranect` hoặc `.cranebk` thật. Chưa thể kết luận byte-level compatibility, đặc biệt encryption và ZIP symlink semantics.

**Còn khóa:** Root Backup/Restore vẫn hiển thị unavailable; không sửa `CRManager`, `cranehelperd`, injection hoặc code vận hành trên iPhone.

## 9. G-11 giai đoạn B — writer ZIP **chỉ cho fixture tách biệt** (2026-10-15)

**Đã triển khai:** `reconstruction/tools/crane_backup_fixture_writer.py`, một CLI Python chỉ phục vụ **dữ liệu thử nghiệm giả lập**, không phải chức năng Backup của Crane trên iPhone và **chưa xác nhận tương thích file Crane gốc**. Nguyên tắc: không backup Keychain, không mã hóa, không giải nén/restore, không động tới `CraneManager`/helperd; dữ liệu đầu vào phải nằm bên trong fixture root đã đánh dấu.

**Cấu trúc thư mục ví dụ (dữ liệu test, không dùng dữ liệu người dùng thật):**

```text
my-disposable-fixture/
├── .crane-disposable-fixture        # đúng bytes: CRANE_DISPOSABLE_FIXTURE_V1 + '\n'
├── manifest.json
├── first/
│   ├── app/                        # chỉ file thường/thư mục thường
│   └── group/
└── output/                          # phải tồn tại sẵn, chỉ ghi file mới
```

**Manifest (đây là ảnh xạ metadata mô phỏng, không được dùng để truy cập path /private/var):**

```json
{
  "containers": [
    {
      "applicationIdentifier": "com.example.fixture",
      "containerIdentifier": "A66C8935-FB19-46A3-A6BD-1100DCA90301",
      "containerName": "Disposable Fixture",
      "originalPaths": {
        "com.example.fixture": "/private/var/mobile/Containers/Data/Application/DUMMY",
        "group.com.example.fixture": "/private/var/mobile/Containers/Shared/AppGroup/DUMMY"
      },
      "sourceDirectories": {
        "com.example.fixture": "first/app",
        "group.com.example.fixture": "first/group"
      }
    }
  ]
}
```

**CLI:**

```sh
python3 reconstruction/tools/crane_backup_fixture_writer.py \
  --fixture-root /path/to/my-disposable-fixture \
  --manifest manifest.json --output fixture.cranect
# Với manifest chứa >=1 container, dùng tên output kết thúc .cranebk để tạo multi archive
```

**Cách hoạt động:** sau khi bắt buộc xác nhận byte marker và source nằm trong root, script kiểm tra tất cả source directories và file thường, chặn symlink/hardlink/special files, kiểm tra tối đa 5.000 entry / 32 MiB mỗi file / 128 MiB tổng, tạo binary `Info.plist`, `Metadata.plist` (hiện chỉ POSIX permissions), dữ liệu app/group theo `<associatedID>/...` và `Info.plist` root `containedContainers` cho multi. File nguồn stream theo khối 1 MiB; dùng `O_NOFOLLOW` nếu OS hỗ trợ và so inode/size/mtime trước/sau mở. ZIP được dựng trong một staging file tên ngẫu nhiên, kiểm tra lại bằng inspector với CRC và **chỉ publish thành file mới bằng hard-link no-replace**; nếu lỗi thì xóa staging của lần gọi, không xóa/ghi đè target trước đó.

**Giới hạn quan trọng:** chưa so sánh với **archive gốc**; `Metadata.plist` chưa có full owner/group/time metadata; không xử lý symlink gốc (cố ý từ chối); `ZIP_DEFLATED` không có password/AES; không hỗ trợ Keychain/SEP; không hứa tái tạo byte-identical ZIP của `SSZipArchive`. Kiểm tra an toàn filesystem thực tế giữa lúc scan và lúc open có thể khác theo OS; writer không phải công cụ bảo vệ dữ liệu mật trước source bị race bởi attacker. Chỉ chạy trên thư mục fixture không có dữ liệu nhạy cảm, tuyệt đối không hướng `--fixture-root` vào container của thiết bị.

**Kiểm thử:** `test_crane_backup_fixture_writer.py` có 13 bài kiểm thử, gồm single/multi tạo→inspector `--verify-payload`→CRC, binary plist, thư mục rỗng, file 0-byte, full originalPaths synthetic, metadata permission, trường hợp input/target nguy hiểm, symlink, tên định danh bị trùng `Info.plist`, no-overwrite và cleanup khi lỗi. `check_backup_fixture_writer_contract.py` và các bước mới trong `.github/workflows/build.yml` giữ phạm vi tách biệt.

**Còn thiếu trước khi dùng cho dữ liệu thật:** fixture xuất từ Crane gốc, so schema/metadata/ZIP method/behavior; thiết kế backup snapshot consistency, giao tiếp Keychain helper có trạng thái lỗi, UI container selection và transactional restore có rollback. Trước các điều kiện đó **không bật các selectors Backup/Restore trên iPhone**.

## 10. G-11 giai đoạn C — đối chiếu định dạng original vs writer (read-only, 2026-10-15)

Thêm CLI `reconstruction/tools/crane_backup_shape_compare.py`. Nó kiểm tra độc lập từng archive bằng `crane_backup_inspector.py`, rồi xuất **chỉ chênh lệch về hình dạng ZIP/plist**, không đọc app payload/Keychain hoặc giải nén, không sửa dữ liệu.

```sh
python3 reconstruction/tools/crane_backup_shape_compare.py \
  --reference /path/to/disposable-original.cranect \
  --candidate /path/to/fixture-writer-output.cranect

# Tùy chọn đọc tuần tự kiểm CRC ngoài Keychain (< 256 MiB mỗi archive)
python3 reconstruction/tools/crane_backup_shape_compare.py \
  --reference /path/to/disposable-original.cranebk \
  --candidate /path/to/fixture-writer-output.cranebk --verify-payload
```

- **Đối chiếu:** single/multi, container count, root `containedContainers`, binary/XML Info và Metadata plist, danh sách **khóa đã biết** (không giá trị), số khóa lạ, số originalPaths, số mục Metadata và các loại writable attributes đã biết, ZIP compression method, thư mục, file, file rỗng, lượng mục và sự hiện diện Keychain.
- **Ẩn dữ liệu nhạy cảm:** không đưa bundle/container ID, tên file, `originalPaths`, `containerName`, vendor ID, nội dung file hoặc Keychain vào JSON; thông báo lỗi CLI chung, không in exception gốc có thể chứa ZIP member name. Với backup nhiều container, chữ ký cấu trúc được sắp xếp ổn định, không dựa vào tên container.
- **Kết quả:** exit 0 `structural_shape_match_not_proven`, exit 1 `structural_differences_found`, exit 2 `unsupported_not_validated` hoặc `unavailable_or_invalid`. Luôn trả `original_compatibility_proven:false`, `restore_safe:false`, `keychain_contents_read:false` và `extracted:false`. Cấu trúc trùng **không đủ chứng minh archive gốc tương thích, restore được hoặc có giá trị bảo mật**.
- **Kiểm thử:** 11 ca tổng hợp trong `test_crane_backup_shape_compare.py` (single/multi, XML/binary, metadata, compression, Keychain presence, trường hợp path nhạy cảm, invalid archive, giữ nguyên file nguồn). Contract `check_backup_shape_compare_contract.py` và hai CI steps mới khóa công cụ ở chế độ chỉ đọc.
- **Tồn đọng:** workspace chưa có ZIP gốc từ Crane trên disposable app, nên hiện chỉ thử nghiệm bằng fixture tổng hợp. Cần cặp archive thật và synthetic cùng điều kiện đầu vào trước khi so kết quả và xác định chi tiết cần sửa ở writer.

## 11. G-11 giai đoạn B2 — metadata theo 12 thuộc tính gốc (2026-10-15)

Đã đối chiếu trực tiếp bản decompile:

- `+[CRPBackupContainer allWritableFileAttributes]` **0x2301C** liệt kê 12 khóa: `NSFileBusy`, `NSFileCreationDate`, `NSFileExtensionHidden`, `NSFileGroupOwnerAccountID`, `NSFileGroupOwnerAccountName`, `NSFileHFSCreatorCode`, `NSFileHFSTypeCode`, `NSFileImmutable`, `NSFileModificationDate`, `NSFileOwnerAccountID`, `NSFileOwnerAccountName`, `NSFilePosixPermissions`.
- `+[CRPBackupContainer attributeDictionaryWithNonWritableAttributesFilteredOut:]` **0x23124** và block **0x23238** chỉ giữ những khóa nằm trong tập hợp trên. `-[CRPRestoreOperation restoreMetadataOfContainer:]` **0x2A848** dùng lại allowlist khi apply metadata. Không phải mọi archive sẽ có đầy đủ 12 khóa.

**Đã triển khai (offline, chỉ fixture):** module `tools/crane_backup_metadata.py` chứa danh sách 12 khóa có thứ tự bất kỳ dưới dạng `frozenset` và hàm `filter_writable_file_attributes`. Module này cung cấp `attributes_available_from_stat` cho writer **chỉ nhận thuộc tính có chứng cứ từ filesystem thử nghiệm**:

- `NSFilePosixPermissions` từ `st_mode`, `NSFileModificationDate` từ `st_mtime` dưới dạng `NSDate` trong binary plist (UTC, độ phân giải giây).
- `NSFileCreationDate` **chỉ nếu hệ điều hành có `st_birthtime`**. Không tự diễn giải POSIX `st_ctime` thành ngày tạo vì trên Linux đây là ngày inode thay đổi.
- `NSFileOwnerAccountID`/`NSFileGroupOwnerAccountID` chỉ lấy nếu OS cung cấp UID/GID số nguyên hợp lệ. Đây là identity **của máy tạo fixture**, **không phải UID/GID phù hợp để khôi phục trên iOS**.
- Các flag HFS, owner/group account name, busy, hidden, immutable không thể suy ra tin cậy từ thông tin portable `stat` nên không giả lập. Hàm filter giữ đúng 12 thuộc tính gốc nếu đã có giá trị hợp lệ từ nguồn ngoài (cần kiểm tra plist serialization riêng).

**Điểm kỹ thuật đã kiểm chứng:** Python `plistlib` mặc định yêu cầu datetime UTC **naive** cho binary plist; lưu timezone-aware datetime khiến `TypeError`. Hàm `_date_if_representable` chuyển về UTC rồi loại `tzinfo` và microseconds trước khi ghi; bộ fixture test xác minh round-trip binary plist.

**Test/CI:** `test_crane_backup_metadata.py` có 8 test (exact allowlist, filter chống khóa không được phép, UTC/creation vs ctime, UID/GID, plist, invalid date), thêm kiểm tra integration writer và cập nhật bài test comparator do `NSFileModificationDate` nay có sẵn; `check_backup_metadata_contract.py` đối chiếu hàm gốc khi có IDA export và giữ UI fail-closed. Hai CI steps kiểm tra metadata và smoke test.

**Giới hạn:** điều này không chứng minh file ZIP tạo từ fixture tương thích thực tế với Crane gốc. Chưa có `.cranect/.cranebk` xuất từ app thử nghiệm Crane gốc; không can thiệp Keychain, không khôi phục metadata vào filesystem, không nối Backup/Restore trên iPhone.

## 12. G-11 — Restore preflight mapping (offline, no restore, 2026-10-15)

**Mã gốc đã xác minh:** `CRPRestoreOperation determineBackupsToRestore` 0x29A84 (multi người dùng chọn mapping qua event 2; single target tường minh), `handleAppIdentifierCheck` 0x29CAC (single backup appID phải trùng target), `handleGroupIdentifierCheck` 0x2A298 + block 0x2A7CC (mỗi associated ID gốc phải có trong tập DEFAULT, nếu không yêu cầu người dùng xác nhận event 3), `updatePathsOfContainer` 0x2B31C (thay các phần đường dẫn), `restoreBackupContainer` 0x2ADA0 (wipe trước move — NGUY HIỂM khi chưa có rollback).

**Đã triển khai `reconstruction/tools/crane_restore_preflight.py`:** kiểm tra đầu vào ZIP bằng read-only `inspect_archive`, đọc có giới hạn đúng `Info.plist` từng container, nhận JSON inventory **do người chạy tự tạo**, không tra cứu thiết bị, không nhập đường dẫn đích, không giải nén/copy/xóa/chmod/chown/move bất cứ thứ gì. Có thể chọn subset nguồn trong multi nhưng mỗi source và mỗi target chỉ dùng một lần. Single buộc một ánh xạ. Cả multi cũng chặn appID mismatch để chặt hơn nhánh single của mã gốc.

**Mẫu inventory chỉ chứa danh sách định danh (không có path):**

```json
{
  "freeBytes": 1000000000,
  "targets": [{
    "applicationIdentifier": "com.example.fixture",
    "containerIdentifier": "TARGET-1",
    "defaultAssociatedIdentifiers": ["com.example.fixture", "group.com.example.fixture"],
    "targetAssociatedIdentifiers": ["com.example.fixture", "group.com.example.fixture"],
    "active": false,
    "existingData": false
  }],
  "mappings": [{
    "sourceApplicationIdentifier": "com.example.fixture",
    "sourceContainerIdentifier": "SOURCE-1",
    "targetApplicationIdentifier": "com.example.fixture",
    "targetContainerIdentifier": "TARGET-1"
  }]
}
```

Trong thực tế `sourceContainerIdentifier` phải khớp archive; `defaultAssociatedIdentifiers` là ảnh chụp TEST inventory của ứng dụng DEFAULT và **không được tự suy từ danh sách backup**. JSON này không xác thực ứng dụng/đường dẫn trên iPhone. `freeBytes` chỉ là số khai báo giả định, **không phải kiểm tra dung lượng thật**; công cụ so sơ bộ với `ceil(1.2 * archive_size)` từ luồng gốc 0x28FE0.

```sh
python3 reconstruction/tools/crane_restore_preflight.py \
  --archive /path/to/disposable.cranect \
  --inventory /path/to/test-inventory.json
```

**Phân loại lý do an toàn:** `application_identifier_mismatch`, `associated_identifier_confirmation_required`, `target_associated_identifier_unavailable`, `target_active_reload_unverified`, `overwrite_requires_snapshot_and_rollback`, `keychain_restore_backend_unavailable`, `free_space_unknown`, `insufficient_estimated_free_space`. Không xuất bundle ID, container ID, group ID hay đường dẫn trong báo cáo JSON. Input hỏng được trả mã lỗi chung tránh lộ tên file/giá trị.

**Kết quả:** exit 0 `preflight_advisory_only` khi không có cảnh báo từ dữ liệu TEST; exit 1 `preflight_blocked` khi có lý do chặn; exit 2 `preflight_unavailable_or_invalid` khi inventory/backup sai. **Ở MỌI KẾT QUẢ `restore_executable:false`, `original_compatibility_proven:false`, `inventory_verified_against_device:false`, `free_space_verified_on_device:false`, `rollback_implemented:false`, `wrote_files:false`, `extracted:false`, `keychain_contents_read:false`.** Nhánh preflight thành công không cấp quyền thực thi restore.

**Fixture/CI:** `test_crane_restore_preflight.py` tạo ZIP giả lập bằng writer fixture, có các tình huống single/multi, chỉ chọn một phần multi, app/group mismatch, target active/existing data, thiếu dung lượng, trùng mapping, Keychain presence, inventory hỏng và che thông tin. `check_restore_preflight_contract.py` khóa nguồn ở chế độ đọc, đối chiếu original selectors/block khi có decompile và giữ Root Settings hành vi fail-closed; hai bước đã thêm trong `.github/workflows/build.yml`.

**Vẫn chưa giải quyết:** không có archive gốc thực tế trên disposable app, chưa có backend Keychain, không có snapshot/staging transaction/rollback, chưa xác minh live inventory hoặc tiền kiểm target filesystem, chưa có runtime prefs/controller. **Không được nối planner này vào `CRManager wipe`** hay mở tính năng Restore trước khi các điều kiện đó hoàn thành.

## 13. G-11 giai đoạn D1 — mô hình transaction/rollback ảo và fault injection (2026-10-15)

**Đã thêm** `reconstruction/tools/crane_restore_transaction_model.py`: công cụ chạy offline nối đầu ra **D0 read-only preflight** tới mô hình trạng thái transaction **trong bộ nhớ**, không có backend restore, không giải nén ZIP, không ghi file thật, không gọi `CraneManager` hoặc helper/Keychain. Đây là **mô phỏng logic bất biến**, không phải snapshot hay rollback filesystem đang sử dụng được trên iPhone.

**Bằng chứng từ Crane gốc:** `CRPRestoreOperation main` tại `0x2B9B0` làm lần lượt free-space, password, load Info, xác định mapping, kiểm tra appID, extract, kiểm tra group rồi chạy suboperation restore. `restoreBackupContainer:intoContainer:` tại `0x2ADA0` **wipe dữ liệu target trước move**; block `0x2B228` chuyển các associated paths sang target, sau đó có thao tác Keychain và device ID. Đây là lý do reconstruction **không được nối selector UI vào wipe** trước khi có atomic recovery thật và error propagation.

**Mô hình D1:** `snapshot(old virtual states)` → `stage(new virtual states)` → `promote target 1..N` → `verify` → `commit` hoặc `rollback toàn bộ trạng thái ảo`. Các phép gán chỉ sử dụng tuple `('old', index)`/`('new', index)` trong dictionary Python, **không dùng tên hoặc nội dung file**. Có thể chèn lỗi tại `after_snapshot`, `after_staging`, `after_first_promotion`, `after_all_promotions`, `after_verification`, `before_commit`; kiểm tra sau lỗi rằng mọi target ảo khớp snapshot trước đó.

```sh
python3 reconstruction/tools/crane_restore_transaction_model.py \
  --archive /path/to/disposable.cranebk \
  --inventory /path/to/test-inventory.json \
  --inject-failure after_first_promotion
```

**Fail-closed:** D0 báo blocked thì không bắt đầu mô phỏng; báo advisory mới mô phỏng. Công cụ chỉ nhận output D0 có toàn bộ cờ không thực thi (`restore_executable:false`, `rollback_implemented:false`, `inventory_verified_against_device:false`, v.v.). JSON không chứa app/container ID hay private path. Bản thân kết quả successful **vẫn không được dùng để bật Restore**.

**Các trạng thái:** `simulation_committed_virtual_only` nếu hoàn tất mô phỏng trong RAM, `simulation_rolled_back_virtual_only` nếu lỗi đã được rollback ảo, `simulation_not_run_blocked` nếu D0 từ chối, `simulation_unavailable_or_invalid` nếu input/contract sai. `real_rollback_implemented:false`, `device_data_touched:false`, `filesystem_writes:false`, `zip_extracted:false`, `keychain_contents_read:false`, `restore_executable:false` ở **mọi kết quả hợp lệ**. Các trạng thái mô phỏng không đảm bảo ứng dụng không mất dữ liệu thật khi restore thực.

**Kiểm thử/CI:** 11 unit tests trong `test_crane_restore_transaction_model.py` cho single/multi commit ảo, fault injection ở tất cả 6 bước, lỗi giữa multi-target, preflight blocked, giả mạo flags, CLI không tiết lộ danh tính, archive/inventory giữ nguyên. `check_restore_transaction_model_contract.py` giới hạn AST imports/calls ở read-only và đối chiếu decompile khi có file gốc. Hai CI steps đã thêm.

**Để biến thành restore thực:** cần xác thực archive gốc disposable app, kiểm CRC/extract an toàn, chụp snapshot dữ liệu thực cho tất cả app/group containers, transaction journal bền vững qua process crash, atomic move với error propagation, restore permissions/Preferences path/Keychain với undo rõ ràng, lifecycle handling và device-based inventory. Những hạng mục đó **chưa được triển khai**.

## 14. G-11 giai đoạn D2 — filesystem journal *lab*, dữ liệu token giả lập (2026-10-15)

Đã thêm `reconstruction/tools/crane_restore_journal_lab.py` để thử nghiệm **transaction có file journal và recovery giữa các lần gọi process**. Đây là công cụ **khác** với Restore thật và mô hình D1 trong RAM: D2 có tạo/ghi/rename/xóa **chỉ những file test token cố định** trong **thư mục con của OS temporary directory**, tuyệt đối không đụng tới container iOS, App Group, dữ liệu ứng dụng, Keychain, `CraneManager`, daemon, hoặc ZIP payload.

**Ràng buộc bảo vệ bắt buộc (fail closed):** root phải là thư mục con của `tempfile.gettempdir()` sau resolve, phải chứa `/.crane-disposable-fixture` với đúng bytes `CRANE_DISPOSABLE_FIXTURE_V1\n`, và thư mục `transaction-lab/` phải có sentinel thứ hai `.crane-transaction-lab` đúng `CRANE_TRANSACTION_LAB_V1\n`. Thư mục `transaction-lab/slots`, `incoming`, `journal` phải có sẵn, không được là symlink. Chỉ dùng file tên cố định `slot-1.txt`, `slot-2.txt`, nội dung chính xác `CRANE_LAB_OLD_SLOT_<i>\n` và `CRANE_LAB_NEW_SLOT_<i>\n`. Không cho path tùy chọn từ inventory; không mở/đọc/ghi tệp ngoài lab. Số lượng slot chỉ 1 hoặc 2 để kiểm thử đơn/multi.

**Giao thức test:** CLI khi bắt đầu yêu cầu archive và inventory giả lập của D0, và D0 phải báo `preflight_advisory_only` (không được cấp phép restore thật). Snapshot các token OLD vào `journal/backup-N.txt`, ghi `staged-N.txt` token NEW, fsync file, cập nhật `journal/state.json` bằng file `.tmp` + atomic rename sang `phase=prepared` **trước khi đổi slots**. Sau đó rename lần lượt staged→slot, kiểm nội dung token, ghi `phase=committed`, và xóa journal được phép. Thử `os.fsync` thư mục trên POSIX khi filesystem hỗ trợ; một số filesystem/macOS có thể từ chối (`EINVAL`/`ENOTSUP`), Windows không có directory fsync qua Python stdlib. Do đó **không khẳng định durability khi mất điện**.

**Fault injection:** `after_journal`, `after_first_swap`, `after_all_swaps`, `after_commit_record`. Lỗi giả lập không tự rollback: để lại journal và trạng thái token đang dở, sau đó gọi `--recover` ở **process khác**. Nếu `phase=prepared`, phục hồi mọi slot về OLD (kể cả khi một phần rollback đã làm xong và bị ngắt); nếu `phase=committed`, giữ NEW và tiếp tục cleanup. Không có journal nhưng có backup orphan, thiếu backup cần thiết, journal sửa hỏng hoặc `.tmp` còn treo => **từ chối thay vì tự xóa**. Đây là quyết định thận trọng để tránh mất dữ liệu khi mẫu khôi phục chưa chứng minh.

**Cách gọi mẫu (chỉ trong thư mục temp tự tạo với hai markers, 2 cặp token và journal folder):** Đường dẫn `/tmp` chỉ minh họa; phải lấy thư mục tạm thực tế từ Python `tempfile.gettempdir()` (trên macOS có thể là `/var/folders/.../T`).

```sh
python3 reconstruction/tools/crane_restore_journal_lab.py \
  --fixture-root /tmp/disposable-lab-example \
  --archive /tmp/disposable-lab-example/output/test.cranebk \
  --inventory /tmp/disposable-lab-example/inventory.json \
  --inject-failure after_first_swap

python3 reconstruction/tools/crane_restore_journal_lab.py \
  --fixture-root /tmp/disposable-lab-example --recover
```

**Trạng thái JSON:** `fixture_committed`, `fixture_interrupted_requires_recovery`, `fixture_rolled_back`, `fixture_commit_preserved`, `fixture_lab_invalid_or_unsafe`. Không in đường dẫn hay app/container IDs. Kết quả đều nêu `real_restore_supported:false` và **`real_rollback_implemented:false`**. Không có thao tác restore dữ liệu iPhone, không giải nén ZIP.

**Giới hạn bắt buộc nhớ:** thực nghiệm này không chứng minh crash safety khi mất điện, lỗi đĩa, fsync directory trên Windows, rename nhiều file atomic cùng lúc, concurrent writer/race, hoặc Keychain/vendorID/preferences restore. Atomic từng file + journal không tương đương atomic multi-container filesystem. Không được dùng D2 cho bất kỳ dữ liệu thật nào và không được nối với Root UI / `CRManager wipe`.

**Test/CI:** `test_crane_restore_journal_lab.py` tạo fixtures dưới `tempfile.TemporaryDirectory`, kiểm tra commit/rollback token 1/2 slots, faultpoints, restart sau rollback dở, crash sau commit, symlink và root marker, corrupted backup/journal, preflight blocked, CLI privacy và cleanup. `check_restore_journal_lab_contract.py` khoá marker/temp-only, tên file token, không dùng API restore/native và giữ Root Backup/Restore fail-closed; hai bước CI mới.

## 15. G-11 giai đoạn D3 — kế hoạch xử lý Restore read-only từ ZIP (2026-10-15)

**Mới:** `reconstruction/tools/crane_restore_work_plan.py`. Công cụ kết hợp `inspect_archive` (kiểm ZIP, block traversal/symlink/duplicate), `crane_restore_preflight` D0 (source→target 1:1 từ inventory JSON giả lập), `Info.plist` và `Metadata.plist` từng nguồn để lập thống kê công việc. Nó không giải nén, đọc nội dung file ứng dụng, lấy Keychain, truy cập thiết bị, tạo file hay gọi `CraneManager`. **Không chứa target filesystem path hoặc lệnh thực thi restore**.

**CLI:**

```sh
python3 reconstruction/tools/crane_restore_work_plan.py \
  --archive /path/to/disposable.cranebk \
  --inventory /path/to/test-inventory.json

# Tùy chọn kiểm CRC non-Keychain có giới hạn 256 MiB từ inspector:
python3 reconstruction/tools/crane_restore_work_plan.py \
  --archive /path/to/disposable.cranect \
  --inventory /path/to/test-inventory.json --verify-payload
```

**Báo cáo đã ẩn danh:** số container được chọn/bỏ qua, số file/empty file/explicit directory, dung lượng claimed của file payload được chọn (không phải dung lượng cần restore thực tế), số associated IDs, số record Metadata và trường hợp Metadata path không xuất hiện trong ZIP; loại thuộc tính không biết hoặc sai kiểu; cảnh báo bit quyền setuid/setgid/world-writable. Không in bundle ID, container ID, group ID, `originalPaths`, tên file, metadata values, Keychain contents hay lỗi có thể chứa đường dẫn riêng tư. Các mục `Keychain.plist`, `Info.plist`, `Metadata.plist` không được tính vào dữ liệu app payload.

**Luật block/review:** lấy nguyên reason codes từ D0 (app mismatch, target active, missing group, Keychain, space, existingData không có rollback), bổ sung `associated_data_absent_from_archive`, `metadata_paths_without_zip_entries`, `metadata_unknown_attributes`, `metadata_invalid_attributes`, `metadata_privileged_or_world_writable`. Với Multi cho phép lập plan cho subset nguồn, không yêu cầu tất cả container phải được chọn. Chặn input symlink; kiểm tra stat dev/inode/size/mtime trước và sau scan như một cảnh báo TOCTOU cơ bản, **không là bảo đảm trước attacker đang sửa input liên tục**.

**Trạng thái:** `work_plan_advisory_only` (exit 0), `work_plan_blocked_or_review_required` (exit 1) hoặc `work_plan_invalid_or_unavailable` (exit 2); **mọi nhánh hợp lệ luôn `restore_executable:false`, `original_compatibility_proven:false`, `rollback_implemented:false`, `device_target_paths_verified:false`, `wrote_files:false`, `extracted:false`, `keychain_contents_read:false`**. Nếu dùng `--verify-payload`, chỉ trường `non_keychain_crc_verified` có thể true: đây không phải bảo đảm dữ liệu Keychain hoặc authenticity.

**Test/CI:** `test_crane_restore_work_plan.py` kiểm tra single/multi subset, số lượng và dung lượng, Metadata orphan/unknown/sai kiểu, quyền bất thường, missing associated data, Keychain và bad ZIP/CRC, preflight blocker, tình huống đổi archive giữa các lần đọc, redaction CLI và xác minh không gọi `ZipFile.extract/extractall` hoặc mở payload. `check_restore_work_plan_contract.py` ràng buộc read-only, original source và UI Root fail-closed; CI thêm 2 bước chạy contract và unittest.

**Giới hạn lớn chưa giải quyết:** archive Crane gốc chưa có fixture thử nghiệm, device inventory chỉ là JSON giả lập, chưa có backend Keychain/snapshot+rollback thật, không xác minh path replacement của `CraneManager`, chưa chạy trên macOS/device. Kết quả PASS của D3 **không cho phép bật Restore**.

## 16. G-11 D4 — materialize dữ liệu ZIP fixture vào vùng quarantine TEMP (2026-10-15)

**Mới:** `reconstruction/tools/crane_restore_fixture_materializer.py`, một lab **ghi file thật nhưng chỉ trên dữ liệu tổng hợp dùng một lần** dưới `tempfile.gettempdir()`. Không phải trình Restore của tweak; KHÔNG dùng trên archive người dùng, container iOS, `CraneManager`, Keychain hoặc dữ liệu riêng tư. Công cụ lấy kết quả D3 `plan_restore(..., verify_payload=True)` và chỉ cho phép chạy nếu `work_plan_advisory_only`, không có blocker, tối đa 2 mapping/200 file/16 MiB payload.

**Thư mục bắt buộc:** Python OS temporary root + sentinel `.crane-disposable-fixture` đúng `CRANE_DISPOSABLE_FIXTURE_V1\n`, có sẵn `output/` (ZIP fixture tạo bằng writer), `inventory.json` (D0 JSON thử nghiệm), `restore-materialize-lab/` với marker `.crane-materialize-lab` đúng `CRANE_DISPOSABLE_MATERIALIZE_LAB_V1\n` và hai thư mục rỗng `staging/`, `published/`. Không chấp nhận thư mục không được đánh dấu, ngoài OS temp, input zip ngoài `root/output`, inventory khác `root/inventory.json`, symlink/hardlink, output đã tồn tại hay staging mồ côi. **Các marker không xác thực provenance của ZIP**: chỉ đặt backup synthetic/không nhạy cảm vào khu vực này.

**Luồng test có ghi:** sau khi inspector kiểm ZIP cấu trúc và CRC ngoài Keychain, D0/D3 kiểm tra app/group/metadata/quyền, D4 mở từng file payload qua `ZipFile.open` và đọc theo chunk tối đa 1 MiB; không đọc `Keychain.plist`. Mỗi container và associated identifier được ánh xạ sang thư mục số `container-N/associated-N/` **không sử dụng đường dẫn gốc để ghi lên host**. Chỉ chấp nhận thành phần tên file portable ASCII, tránh thiết bị đặc biệt Windows/`../`/symlink; ghi độc quyền `O_EXCL` và `O_NOFOLLOW` khi OS hỗ trợ. Cả multi nguồn được vật hóa trong **một** `staging/batch` có marker riêng, sau khi hoàn tất thì publish bằng **một lần rename thư mục** sang `published/batch`. Chưa áp dụng Metadata.plist attributes/UID/GID, chưa rewrite Preferences, chưa làm Keychain restore.

**Rollback mô phỏng có file payload thật:** `--inject-failure after_first_file` hoặc `--inject-failure before_publish` gây lỗi trước publish; công cụ kiểm stage vẫn nằm trong lab, không có symlink/hardlink rồi xóa **chỉ staging/batch do chính lần chạy tạo**, giữ nguyên ZIP/inventory/source và published. Không tự dọn staging mồ côi từ lần chạy trước, không xóa/ghi đè published. Đổi tên thư mục publish chỉ bảo đảm nguyên tử theo ngữ nghĩa hệ thống file phù hợp **trong cùng filesystem**, không chứng minh chống mất điện, không chống dữ liệu bị sửa bởi tác nhân đồng thời; đây không phải transaction journal D2 và cũng không rollback được dữ liệu thật.

**Chạy thử từ fixture đã tạo đầy đủ:**

```sh
python3 reconstruction/tools/crane_restore_fixture_materializer.py \
  --fixture-root /actual/os/temp/disposable-fixture \
  --archive /actual/os/temp/disposable-fixture/output/sample.cranect \
  --inventory /actual/os/temp/disposable-fixture/inventory.json

# fault injection (staging bị xóa, không publish):
python3 reconstruction/tools/crane_restore_fixture_materializer.py \
  --fixture-root /actual/os/temp/disposable-fixture \
  --archive /actual/os/temp/disposable-fixture/output/sample.cranect \
  --inventory /actual/os/temp/disposable-fixture/inventory.json \
  --inject-failure before_publish
```

**CLI JSON:** `fixture_materialized_not_restore` (exit 0), `fixture_stage_rolled_back` (exit 3) hoặc `fixture_invalid_or_unsafe` (exit 2). Không in bundle/container/group ID, tên file nguồn, `originalPaths` hoặc nội dung file. Trạng thái thành công vẫn `restore_executable:false`, `device_data_touched:false`, `real_rollback_implemented:false`, `keychain_contents_read:false`. Đừng dùng `--fixture-root` trỏ về bất kỳ thư mục container thiết bị nào.

**Kiểm thử/CI:** `test_crane_restore_fixture_materializer.py` có 15 ca thử nghiệm với file thật tổng hợp: single, multi, subset, file zero-byte/empty directory, gián đoạn staging 2 điểm, từ chối đích đã tồn tại, staging orphan, marker sai, archive/inventory ngoài root, target active/existing data, Keychain presence, path traversal, Windows special filename, CLI privacy và bất biến input. `check_restore_fixture_materializer_contract.py` kiểm source guard và Root UI fail-closed; CI thêm 2 bước. Không có ZIP Crane gốc được dùng trong thử nghiệm.

## 17. G-11 D5 — verifier read-only cho D4 quarantine output (2026-10-15)

**Mới:** `reconstruction/tools/crane_restore_quarantine_verify.py` kiểm tra **chỉ đọc** dữ liệu giả lập đã được D4 publish vào `restore-materialize-lab/published/batch`. Nó KHÔNG khôi phục gì thêm, không sửa/xóa/copy file, không áp dụng Metadata, không đọc Keychain, không gọi `CraneManager` hoặc daemon, không xác thực file ZIP gốc.

**Giao diện:** nhận `--fixture-root` (phải là child OS temp có hai markers D4), `--archive` chỉ trong `<fixture-root>/output`, `--inventory` đúng `<fixture-root>/inventory.json`. Phải có batch D4 đã publish, `staging/` rỗng, `published/` không chứa gì khác ngoài `batch/` và marker `.crane-stage` đúng bytes. Công cụ chạy lại `plan_restore(..., verify_payload=True)` gồm D0/D3 và CRC ngoài Keychain. Nếu preflight có cảnh báo (Keychain, app mismatch, active/existing target, Metadata sai, thiếu dung lượng) thì **không kiểm chứng**.

**So sánh:** tái tạo chính xác ánh xạ thư mục số `container-N/associated-N/` theo từng mapping source D0 từ ZIP Info.plist, chỉ dùng các tên portable D4 đã cho phép. Liệt kê toàn bộ thư mục/file quarantine bằng `os.walk(..., followlinks=False)` với tối đa 8.000 entry, chặn symlink, special file và hardlink. Không đọc nội dung file thừa. Bắt file/thư mục thiếu hoặc ngoài danh sách; đọc file có sẵn với `os.open(O_NOFOLLOW)` khi hỗ trợ, kiểm inode/size/mtime và băm SHA-256 theo từng khối; băm tương ứng từ `ZipFile.open` theo chunk (zipfile còn kiểm CRC). Nếu hash không khớp, size thay đổi, file ngoài danh sách hoặc cấu trúc bất thường, kết quả là mismatch hoặc input invalid chứ KHÔNG tự sửa.

**Đầu ra:** `fixture_verified_read_only` (exit 0), `fixture_integrity_mismatch` (exit 1), `fixture_verify_invalid_or_unavailable` (exit 2). JSON chỉ có các thống kê, số lượng mismatch và reason codes cố định; KHÔNG đưa digest, nội dung file, tên file, đường dẫn, app/container/group ID hoặc raw error. Các cờ **luôn** `restore_executable:false`, `original_compatibility_proven:false`, `real_rollback_implemented:false`, `filesystem_writes:false`, `device_data_touched:false`, `keychain_contents_read:false` ở kết quả có đủ dữ liệu.

```sh
python3 reconstruction/tools/crane_restore_quarantine_verify.py \
  --fixture-root /actual/os/temp/disposable-fixture \
  --archive /actual/os/temp/disposable-fixture/output/sample.cranect \
  --inventory /actual/os/temp/disposable-fixture/inventory.json
```

**Test/CI:** `test_crane_restore_quarantine_verify.py` gồm 21 ca tổng hợp dùng fixture D4: single/multi/subset, file đúng và file 0 byte, file sửa cùng kích thước, file bị cắt/thiếu, file/thư mục ngoài ZIP, thư mục rỗng bị xóa, symlink file/thư mục, hardlink, stage marker bị sửa, chưa publish, published chứa mục thừa, preflight blocked, archive ngoài root, thay đổi archive trong lúc hash, không gọi mutator và CLI status/redaction. `check_restore_quarantine_verify_contract.py` kiểm tra chỉ đọc, chỉ hoạt động trong lab, và Root Backup/Restore không được bật; CI thêm 2 bước.

**Giới hạn:** so SHA-256 của payload sau publish chỉ chứng minh fixture hiện tại giống ZIP đã nhập trong lượt kiểm. Không chứng minh nguồn ZIP đáng tin, không giải quyết attacker race, native iOS permissions/group mapping, Keychain, rollback, crash/power loss; chưa kiểm chứng với backup Crane gốc từ disposable app hoặc macOS native CI. Không dùng công cụ này trên container thật.

**Nguồn kiểm toán tại workspace:** `analysis/objc_classes.json`, bản decompile `0x20E64`, `0x211A8`, `0x2614C`, `0x2619C`, `0x25A8C`, `0x24CF8`, `0x257AC`, `0x29504`, `0x2B9B0`, `0x2ADA0`, `0x2B31C`, và các helpers/blocks chỉ rõ trong mục 2-3; đối chiếu với `sources/prefs/CRPreferences.m`, `sources/libcrane/CRManager.m`, `sources/cranehelperd/CRHelperd.m`.
