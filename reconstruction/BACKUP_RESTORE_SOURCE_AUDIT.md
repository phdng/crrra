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

## 18. G-11 giai đoạn C2 — đối chiếu SHA-256 payload của hai ZIP, chỉ đọc (2026-10-15)

**Khoảng trống ở giai đoạn C:** `crane_backup_shape_compare.py` so hình dạng Info/Metadata và phương thức nén, nhưng *không* so byte nội dung file ứng dụng. Hai ZIP có cùng tên file, cùng kích thước và cùng các khóa plist vẫn có thể chứa dữ liệu khác nhau. Đã bổ sung `reconstruction/tools/crane_backup_payload_parity.py` để thực hiện so sánh sâu có giới hạn.

**Kiểm tra:** trước tiên độc lập kiểm tra cả reference và candidate bằng `crane_backup_inspector.inspect_archive(..., verify_payload=True)` để kiểm CRC *ngoài Keychain*, mỗi ZIP giới hạn 256 MiB uncompressed; chặn ZIP mã hóa và đường dẫn không hợp lệ. Cả hai phải cùng loại single/multi và có **tập cặp `applicationIdentifier` + `containerIdentifier` giống nhau** (chỉ dùng trong RAM, không in ra ngoài); thiếu khớp là `container_identity_or_kind_mismatch_uncompared`. Multi chuẩn hóa prefix `<app>/<container>/` để không phụ thuộc thứ tự container trong index. Sau đó đối chiếu chính xác tập file/thư mục theo relative path, kích thước từng file, SHA-256 từng file cùng tên/kích thước và **serialized bytes** `Info.plist`/`Metadata.plist` (kể cả root multi `Info.plist`). Không đọc nội dung `Keychain.plist` dù file có ở cả hai phía. Bộ so sánh hình dạng C vẫn được gọi để đếm sai biệt keys/ZIP compression methods.

```sh
python3 reconstruction/tools/crane_backup_payload_parity.py \
  --reference /path/to/disposable-crane-original.cranect \
  --candidate /path/to/synthetic-writer-candidate.cranect

# Tương tự cho .cranebk khi app+container IDs đã được căn đúng
```

**Báo cáo bảo vệ riêng tư:** chỉ in số file thiếu/thừa, thư mục thiếu/thừa, file khác kích thước, file cùng kích thước nhưng hash khác, số plist khác byte và `shape_difference_count`, số Keychain bị bỏ qua. Không in identifier, tên file, metadata values, originalPaths, hash digest hoặc lỗi thô. Không tạo/xóa/đổi tên/giải nén file, cấm so cùng inode hoặc input symlink và so dev/inode/size/mtime/ctime ở đầu/cuối để phát hiện một số thay đổi trong lúc đọc.

**Exit code:** 0 `payload_and_metadata_bytes_match_not_proven` khi file/metadata/shape trùng (chỉ có nghĩa là hai archive được cung cấp trùng theo tiêu chí vừa kiểm tra), 1 `payload_or_metadata_differences` hoặc `container_identity_or_kind_mismatch_uncompared`, 2 `parity_unavailable_or_unsupported`. Mọi báo cáo luôn `original_compatibility_proven:false`, `restore_safe:false`, `files_extracted:false`, `filesystem_writes:false`, `keychain_contents_read:false`. Kết quả này **không xác thực provenance**: hai ZIP synthetic giống nhau vẫn *không* chứng minh Crane original tương thích. Serialized metadata timestamp hoặc UID khác nhau có thể khiến `different_plist_bytes > 0` dù file payload giống nhau; đó là dữ liệu chẩn đoán, chưa nên tự normalize hoặc bỏ qua.

**Kiểm thử/CI:** `test_crane_backup_payload_parity.py` tạo cặp ZIP synthetic; thử same-size tamper mà shape vẫn bằng nhau, size/dir/file mismatch, thay đổi `containerName` không đổi keys, đổi compression method, multi, identity mismatch, Keychain khác byte nhưng chưa bao giờ mở, bad ZIP, budget chặn, thay đổi source giữa lượt scan, CLI privacy/exit codes. `check_backup_payload_parity_contract.py` ràng buộc read-only, Keychain skip và giữ nguyên Root Settings fail-closed. Hai bước CI được nối ngay sau Stage C.

**Chưa hoàn tất bước thực địa:** workspace chưa chứa file `.cranect`/`.cranebk` xuất từ Crane gốc trên ứng dụng thử nghiệm. Chưa thể đánh dấu G-11 định dạng gốc verified hoặc bật Backup/Restore iPhone. Cần một reference *thật* được chủ động tạo từ disposable app và candidate offline với cùng IDs/dữ liệu, rồi dùng công cụ này để xác định chênh lệch cụ thể mà không đăng dữ liệu nhạy cảm lên log.

## 19. G-11 C3 — archive Crane gốc đầu tiên, xác minh trực tiếp (2026-10-15)

**Mẫu gốc do người dùng cung cấp (không commit vào Git):** `backup/test_Chrome_bg_10.15.2026_09-25-24.cranect`. Chỉ kiểm tại workspace; không giải nén hoặc sao chép nội dung Chrome vào fixture, không mở Keychain và không in/sao lưu app/container IDs, `originalPaths`, file names, UID/GID, tên account hay giá trị metadata. Giữ file nguyên vẹn, **không đóng gói vào CI/artifact**.

**Kết quả chạy thật:** `crane_original_archive_audit.py --archive backup/test_Chrome_bg_10.15.2026_09-25-24.cranect --verify-payload` trả `original_structure_accepted_not_parity_proof`, CRC dữ liệu ngoài Keychain **PASS**. File ZIP có **22.628.701 byte**; **704 entries** (501 file bao gồm `Info.plist`/`Metadata.plist`, 203 thư mục), **53 file rỗng**, **42.958.372 byte uncompressed**. **Không có ZIP encryption và không có Keychain.plist**. ZIP store (method 0) cho 203 thư mục và deflate (method 8) cho 501 file. Inspector xác nhận `single`, 1 container, `Info.plist` và `Metadata.plist` đều **binary**, Info chứa 5 trường gốc `applicationIdentifier`, `containerIdentifier`, `containerName`, `deviceIdentifierForVendor`, `originalPaths`; `originalPaths` có **10 associated IDs**.

**Bằng chứng quan trọng từ Metadata.plist:** **702 record**, mỗi record ứng với đúng một entry dữ liệu ZIP (499 file payload + 203 directories), không có metadata orphan và không có entry dữ liệu bị thiếu metadata. Cả 702 record có đúng **8 khóa sau**, không có khóa lạ và chỉ **một tổ hợp khóa**: `NSFileCreationDate` (datetime), `NSFileModificationDate` (datetime), `NSFileExtensionHidden` (boolean), `NSFileOwnerAccountID` (integer), `NSFileGroupOwnerAccountID` (integer), `NSFileOwnerAccountName` (string), `NSFileGroupOwnerAccountName` (string), `NSFilePosixPermissions` (integer). Các giá trị cụ thể được giữ kín.

**Sai khác đã xác định với fixture writer Windows:** `crane_backup_metadata.attributes_available_from_stat` hiện chủ động chỉ ghi các thuộc tính lấy được từ OS: POSIX mode, modification time, birthtime nếu cung cấp, numeric UID/GID khi có. Trên Windows có thể thiếu birthtime hoặc names; writer **chưa tạo `NSFileExtensionHidden`, account owner/group names** và không được tự suy diễn giá trị iOS từ host. Bổ sung 8 keys một cách giả định để được 'match' là sai; cần phát triển provider native NSFileManager iOS trên dữ liệu test hoặc metadata manifest có chủ đích trong fixture mới đủ cơ sở. Do archive original có cả dữ liệu riêng tư, **không dùng nó như source tree cho fixture writer**, chưa có cặp candidate chứa chính xác dữ liệu giống archive để kiểm C2 payload parity.

**Thêm công cụ/audit có chế độ read-only:** `reconstruction/tools/crane_original_archive_audit.py` thu thập số liệu nén/ZIP/encryption/metadata coverage/kiểu giá trị trên allowlist, không in path hoặc values; opt-in `--verify-payload` gọi inspector để kiểm CRC trong giới hạn 256 MiB ngoại trừ Keychain. `test_crane_original_archive_audit.py` dùng các ZIP synthetic cho CI; ca regression cho đúng mẫu Chrome chạy **chỉ khi file tồn tại ở workspace**, trên CI sẽ được SKIP và không có backup riêng tư. `check_original_archive_audit_contract.py` kiểm tra không có mutators, Keychain không bị đọc, UI vẫn fail closed. Hai bước CI thêm contract + test.

**Giới hạn kết luận:** đã có **bằng chứng cấu trúc thật** đối với **một** `.cranect` đơn không mật khẩu/Keychain và CRC dữ liệu ngoài Keychain. **Chưa chứng minh writer tương thích bit-for-bit hoặc restore được**, chưa có cặp candidate thật với cùng app/container IDs/payload, chưa chứng minh multi `.cranebk`, mã hóa/password/Keychain. Không bật Root Backup/Restore và không sửa daemon/injection/CraneManager/helper. Cần thêm archive disposable app không chứa dữ liệu riêng tư với cặp candidate thích hợp, rồi chạy `crane_backup_payload_parity.py` để xác nhận chi tiết.

## 20. G-11 C4 — metadata schema 8 trường original bằng **giá trị giả** trong fixture writer (2026-10-15)

Đã đối chiếu ZIP gốc `backup/test_Chrome_bg_10.15.2026_09-25-24.cranect` ở mục 19: tất cả 702 `Metadata.plist` entries có cùng **8 khóa và kiểu**: `NSFileCreationDate`/`NSFileModificationDate` (datetime), `NSFileExtensionHidden` (bool), `NSFileOwnerAccountID`/`NSFileGroupOwnerAccountID` (integer), `NSFileOwnerAccountName`/`NSFileGroupOwnerAccountName` (string), `NSFilePosixPermissions` (integer). Đây là quan sát về **schema**, không có quyền tái tạo UID/GID/account/hidden/time thực của người dùng.

**Đã triển khai (chỉ offline disposable fixture):** `crane_backup_metadata.original_sample_shape_synthetic_attributes` sinh đúng 8 khóa bằng các giá trị test công khai/cố định: 2 timestamp `2001-01-01T00:00:00` (naive UTC tương thích binary plist), `NSFileExtensionHidden=False`, owner/group IDs giả `900001/900002`, tên `crane-fixture-owner-NOT-IOS` và `crane-fixture-group-NOT-IOS`, permissions lấy từ `stat.S_IMODE` của **file fixture**. Các giá trị giả **KHÔNG đúng theo iOS và TUYỆT ĐỐI không dùng để restore lên thiết bị**. Không đọc/sao chép bất kỳ metadata, Chrome payload, account names hoặc đường dẫn thực trong archive gốc để tạo candidate.

Writer hiện có tùy chọn tường minh `--metadata-profile synthetic-original-eight-field`; **mặc định `host-stat` không đổi**. Vẫn đòi root có marker `.crane-disposable-fixture`, manifest chỉ đường dẫn nguồn nằm trong fixture, ghi ZIP tạo mới không overwrite và inspector CRC output. Với cả single/multi và mỗi thư mục/file, `Metadata.plist` dạng binary chứa đúng 8 khóa có type của bản gốc. `Info.plist` giữ schema writer gốc (không được thêm marker lạ chỉ nhằm thông qua test). JSON output công bố `metadata_profile` và `original_compatibility_proven:false`.

```sh
python3 reconstruction/tools/crane_backup_fixture_writer.py \
  --fixture-root /path/to/disposable-fixture \
  --manifest manifest.json --output synthetic-eight.cranect \
  --metadata-profile synthetic-original-eight-field
```

**Kiểm thử:** `test_crane_original_metadata_shape.py` gồm 11 unit tests: binary plist 8-key/type cho mọi file/thư mục, UID/GID không lấy từ host, timestamp test cố định, output deterministic, multi-container, default host-stat không bị ảnh hưởng, profile tùy ý bị từ chối, thiếu marker bị chặn, không overwrite, CLI opt-in không lộ tên chủ sở hữu; ca **local** đối chiếu đúng 8 tên/kiểu với mẫu Chrome gốc chỉ chạy nếu file riêng tư hiện diện, **CI không chứa archive sẽ SKIP**. Source contract `check_original_metadata_shape_contract.py` và 2 CI steps kiểm tra đúng giới hạn.

**Điều chưa được chứng minh:** đây chỉ là **metadata shape parity**. Không hề chứng minh ZIP file/data payload/parity với backup gốc (writer chưa có candidate cùng IDs/payload), không chứng minh việc nhận/trả đúng owner/permissions/timestamp trên iOS, không giải quyết `deviceIdentifierForVendor`/Keychain/password/multi-original hay restore transaction. Mọi Root Backup/Restore vẫn fail-closed; daemon/injection/CraneManager/helper không đổi.

## 21. G-11 C5 — ZIP envelope Crane original (single), bố cục ZIP của writer fixture (2026-10-15)

**Bằng chứng mới từ `backup/test_Chrome_bg_10.15.2026_09-25-24.cranect`** (file do người dùng xác nhận là backup Crane gốc; không commit): đã kiểm *chỉ các ZIP headers*, không đọc payload ứng dụng hoặc Keychain. `Info.plist` là entry số 0; `Metadata.plist` là entry cuối cùng (số 703/704). Trong 704 entries, **203 directory ZIP_STORE (method=0)**; **501 ordinary file ZIP_DEFLATED (method=8)**; tất cả entries có `create_system=19` (macOS), `flag_bits=0x0808`, `extract_version=45`, ZIP64 extra field `(id=1, data_length=16)` tương đương 20 bytes bao gồm header; không có other extras/comment. Original `Info.plist` còn có `deviceIdentifierForVendor: str`, writer hiện không tạo; đây là **gap chưa giải quyết**, không được tự điền vendorID giả để bật restore.

**Công cụ mới `reconstruction/tools/crane_backup_zip_envelope.py`:** gọi inspector trước khi thống kê, từ chối traversal/symlink/encryption và archive multi chưa có mẫu gốc; giới hạn chỉ một ZIP single, báo **booleans/counters/header traits** cố định, không in tên file, app/container IDs, contents, extra-field data, đường dẫn riêng tư hoặc errors thô. Có CLI `--reference` [và `--candidate`] để so các đặc điểm tổng quát giữa hai ZIP mà không cần trùng IDs/file contents. Trả status `zip_envelope_observed_not_original_parity` (chỉ xem một archive), `zip_envelope_features_match_not_proven`, `zip_envelope_features_differ`, hoặc `zip_envelope_unavailable_or_invalid`. Mọi kết quả giữ `original_compatibility_proven:false`, `restore_safe:false`, `app_payload_read:false`, `keychain_contents_read:false`, `filesystem_writes:false`. Hai archive synthetic có flags giống nhau KHÔNG đồng nghĩa tương thích bản gốc.

**Writer thử nghiệm cập nhật, opt-in:** `crane_backup_fixture_writer.py --zip-layout original-observed-structure` chỉ cho **single `.cranect`** disposable fixture có marker. Sử dụng `zipfile.ZipInfo` với creator=19, ghi Info đầu, file/directory tiếp theo, Metadata ở cuối; directory method Store, file method Deflate. Đường dẫn nguồn vẫn cố định dưới fixture; safe scan, byte limits, CRC và exclusive publish không đổi. **Mặc định `--zip-layout standard` giữ hành vi cũ**; `--metadata-profile synthetic-original-eight-field` C4 có thể kết hợp để kiểm thử 8 tên/kiểu (giá trị metadata giả). Multi `.cranebk` bị chặn khi chọn ZIP layout original vì chưa có mẫu multi gốc để suy đoán.

```sh
python3 reconstruction/tools/crane_backup_fixture_writer.py \
  --fixture-root /path/to/disposable-fixture \
  --manifest manifest.json --output synthetic-layout.cranect \
  --metadata-profile synthetic-original-eight-field \
  --zip-layout original-observed-structure

python3 reconstruction/tools/crane_backup_zip_envelope.py \
  --reference backup/test_Chrome_bg_10.15.2026_09-25-24.cranect \
  --candidate /path/to/disposable-fixture/output/synthetic-layout.cranect
```

**Kết quả so real original ↔ synthetic writer:** 5 đặc điểm đã khớp (Info first, Metadata last, directory Store, file Deflate, creator=19), nhưng còn **3 sai khác**: `all_general_flag_0808`, `all_zip64_16_extra`, `all_requires_zip64_version_45`. Python `zipfile` không tái tạo đương nhiên SSZipArchive ZIP64+flags cho mọi entry, **không hack cờ vào central header khi chưa kiểm Local File Header/Data Descriptor và CRC tương ứng**. Writer output JSON luôn `original_zip_envelope_proven:false` và `original_compatibility_proven:false`; checksum/Info vendor ID/timestamp/real ownership vẫn khác. Không bật Backup/Restore gốc chỉ dựa vào 5 đặc điểm đã khớp.

**Unit/CI:** `test_crane_backup_zip_envelope.py` kiểm 16 tình huống, trong đó 2 bài local dùng backup Chrome gốc (CI thiếu archive sẽ SKIP). `check_backup_zip_envelope_contract.py` giới hạn API read-only, ZIP-method creator, opt-in single/marker, root preferences fail-closed; thêm 2 bước vào `.github/workflows/build.yml`. Không đụng daemon, injection, CraneManager, Keychain hoặc UI Root Backup/Restore.

## 22. G-11 N0 — nền tảng native Objective-C cho Backup Info + Restore Reader (2026-10-15)

**Đã chuyển từ công cụ Python sang native:** `reconstruction/sources/prefs/CRBackupNativeCore.h` và `reconstruction/sources/prefs/CRBackupNativeCore.m` đã được nối vào `CranePrefs_FILES` trong Makefile, link với Foundation/CoreFoundation và zlib (`-lz` sẵn có). Đây là thành phần **native ở mức thư viện nội bộ, chưa có nút thao tác trực tiếp**; Root Backup/Restore vẫn hiển thị unavailable và không gọi tới nó.

**Restore Reader an toàn (chỉ đọc):** `readSingleBackupInfoAtPath:error:` mở file `O_RDONLY` + `O_NOFOLLOW` (nếu OS hỗ trợ), giới hạn archive 512 MiB, chỉ đọc local ZIP header/entry đầu `Info.plist` (đúng 10 byte), giới hạn nén 1 MiB/chưa nén 256 KiB, chặn flag/method không hỗ trợ và ZIP encryption, xử lý kích thước ZIP64 từ extra id=1, Deflate raw bằng zlib. Nếu bit 3 data-descriptor bật, kiểm signature `PK0708`, CRC32 và ZIP64 sizes theo descriptor 24 byte (hoặc 16 byte chuẩn). Nếu không bật, kiểm CRC trong local header. Parse bắt buộc binary plist và schema original single `{applicationIdentifier,containerIdentifier,containerName,originalPaths,deviceIdentifierForVendor?}`; đường dẫn originalPaths chỉ được xử lý như chuỗi/không truy cập filesystem, từ chối `.`/`..` và ID không hợp lệ. Không mở nội dung bất kỳ file app/Keychain khác, không giải nén hay ghi file.

**Giới hạn của Reader N0:** chỉ đọc và xác minh **entry Info đầu tiên**, **KHÔNG kiểm chứng đầy đủ central directory, các thành viên khác, encrypted/multi archives, symlink file payload, hoặc toàn bộ CRC**. Không được coi thành công N0 là backup hợp lệ để Restore, không giải nén và không cấp quyền ghi. Tiền kiểm ZIP toàn diện hiện vẫn ở các công cụ Python offline.

**Native Backup manifest preparation (chưa tạo ZIP):** `binarySingleInfoForApplicationIdentifier:containerIdentifier:containerName:originalPaths:deviceIdentifierForVendor:error:` tạo binary `Info.plist` từ dữ liệu do caller cung cấp; **không đoán UUID/vendor ID**, không đọc/ghi dữ liệu app. `writableMetadataAttributes:` lọc đúng 12 writable NSFile attributes gốc 0x2301C/0x23124 và type (`NSDate`, NSNumber integer/boolean, NSString). `binaryMetadataForIndexedAttributes:error:` chỉ serialize binary `Metadata.plist` từ dictionary do caller cung cấp, giới hạn 10.000 mục/2 MiB, chặn tên ZIP relative chứa traversal, không chmod/chown/move hoặc enumerate source. Đây là các primitive native để phục vụ writer thật trong giai đoạn sau, **không phải quy trình sao lưu hoàn chỉnh**.

**CI:** `reconstruction/tools/native_backup_reader_fixture.py` tạo 3 ZIP synthetic không seek: ZIP64 local `Info.plist`+descriptor CRC hợp lệ, descriptor CRC sai, và ZIP chứa Info không phải binary plist; không sử dụng archive Chrome riêng tư. `native_backup_core_smoke.m` biên dịch trên runner macOS với Foundation/CoreFoundation/zlib để kiểm reader, CRC, schema, Info/Metadata binary serialization và rejection path bất thường. `test_crane_native_backup_core.py` xác nhận cấu trúc test-vector trên mọi OS, và khi có bản Chrome gốc tại workspace còn đối chiếu header/ZIP64 descriptor mà không đọc nội dung ứng dụng; `check_native_backup_core_contract.py` giữ không có wipe/restore/Keychain/daemon gọi ngầm. CI thêm build-and-run smoke. Build thực native Theos phải được xác nhận từ GitHub Actions sau push; máy Windows không có SDK iOS/macOS nên chưa khẳng định build xanh.

**N0 sửa smoke Deflate trên macOS (2026-10-15):** Runner đã biên dịch Objective-C nhưng dừng ở `valid first-entry ZIP64 Info rejected`. Kiểm tra byte của fixture generated xác nhận local ZIP64 extra size=20, descriptor **24 byte** với signature + CRC32 + 64-bit compressed/uncompressed sizes đúng, raw Deflate nội dung và binary plist cũng hợp lệ; do đó **không đổi** descriptor parser sang 16 byte khi chưa có bằng chứng. Điều chỉnh buffer inflate từ đúng kích thước khai báo sang `targetSize + 1` (vẫn chặn byte giải nén vượt mức) để tránh trường hợp zlib cần thêm headroom ở ranh giới end-of-block. Bổ sung mã lỗi giai đoạn **không chứa đường dẫn/nội dung** (`10` stat, `20` ZIP header, `30` name, `40` ZIP64, `50` Deflate, `60` descriptor, `70` CRC, `80` binary plist/schema, `90` input changed), ghi số giai đoạn ra CI smoke khi từ chối file giả lập. Python regression kiểm CRC/sizes của descriptor ZIP64 24 byte và EOF raw Deflate; **kết quả macOS sau chỉnh sửa chưa xác nhận, cần CI rerun**.

**N0 sửa triệt để stage 50 (2026-10-15):** CI macOS sau thay đổi buffer vẫn trả `native G-11 reader rejected synthetic ZIP at stage 50`. Đã kiểm tra byte thật trong `crane-native-valid.cranect` và file `test_Chrome_bg_10.15.2026_09-25-24.cranect`: **cả hai đều có ZIP64 local extra id=1, length=16 nhưng uncompressed/compressed local size = 0/0 vì general purpose bit3 bật**; kích thước hợp lệ nằm trong ZIP **CENTRAL DIRECTORY**, còn descriptor 24 byte cuối entry chứa CRC và kích thước thật. Lỗi gốc là `CRReadInfoFromFD` dùng local `(0,0)` làm số byte cần giải nén, dẫn đến `CRInflate` fail ở stage50; không phải thiếu zlib headroom hay descriptor16. Đã bổ sung `CRReadFirstCentralInfo` đọc bounded EOCD (tối đa 65557 byte phần cuối) và **duy nhất central entry đầu tiên** `Info.plist`, kiểm offset đầu=0, tên/method/flags, lấy kích thước ZIP64 từ central extra khi cần, chặn multi-disk/EOCD ZIP64 chưa hỗ trợ. Local ZIP64 size=0 chỉ được chấp nhận khi bit3 bật; các local size nonzero phải khớp central; sau giải nén buộc data descriptor CRC/kích thước khớp central và checksum tính lại. Stage 35 mới biểu thị lỗi đọc/trùng khớp first central entry; stage 50 giữ nguyên giải nén. Bộ fixture synthetic thêm hai trường hợp hỏng central compressed size/CRC được macOS native smoke từ chối; Python test kiểm local=0 nhưng central size thực khác zero. **Cần rerun macOS CI để xác nhận Objective-C smoke/build xanh**; scanner chỉ kiểm entry đầu, tuyệt đối không thay thế full ZIP validator/Restore gate.

**Còn thiếu để bật chức năng:** native ZIP writer tạo đúng original SSZipArchive ZIP64/flags, enumeration có quyền và metadata NSFileManager thực tế, CRC toàn archive, lifecycle/error propagation, rollback snapshot journal, Keychain, app groups/device ID và device tests. Không nối N0 vào nút UI Backup/Restore cho đến khi luồng end-to-end và an toàn đã có. Các thành phần daemon/injection/CraneManager/helper hiện không thay đổi.

## 23. G-11 N1 — native ZIP central/local survey chỉ đọc (2026-10-15)

**Mục tiêu:** Sau khi N0 đọc riêng `Info.plist`, bổ sung lớp Foundation Objective-C `reconstruction/sources/prefs/CRBackupArchiveSurvey.h` và `reconstruction/sources/prefs/CRBackupArchiveSurvey.m` để duyệt toàn bộ **ZIP headers** của archive đơn `.cranect` mà không đọc nội dung file ứng dụng hoặc Keychain. `CranePrefs_FILES` có translation unit mới. Không nối vào Root Restore hoặc bất cứ thao tác xóa/ghi container.

**Đã triển khai:** `inspectSingleArchiveAtPath:error:` mở `O_RDONLY` và `O_NOFOLLOW` khi có; tìm EOCD cuối file, từ chối multi-disk/ZIP64 EOCD chưa hỗ trợ, giới hạn kích thước ZIP 512MiB, central directory 16MiB, số member 10.000, tổng kích thước chưa nén được khai báo 256MiB. Kiểm mọi central directory record: UTF-8, không path traversal/absolute/backslash/colon/control, không tên trùng hoặc file-as-parent, chỉ Store hoặc Deflate, không bit flag mã hóa, không Unix symlink/special, `Info.plist` đầu, `Metadata.plist` cuối. So từng record với local header gồm local name/flags/method, ZIP64 size extra (hỗ trợ local placeholder 0 khi bit3 có descriptor), signature CRC/kích thước data descriptor 16 hoặc 24 byte, thứ tự và không chồng lấn byte. Đầu ra **chỉ có số lượng** file/thư mục, uncompressed claimed, số entry tên Keychain, cùng cờ `payloadCRCVerified:false`, `keychainContentsRead:false`, `restoreExecutable:false`. Không in tên file/path/source ID hay raw error.

**Giới hạn bắt buộc:** parser **không giải nén bất cứ payload nào**, không tính CRC thực sự của file ứng dụng, không parse `Metadata.plist`, không chứng minh payload an toàn, danh tính/app group, rollback hoặc khả năng Restore. Cả báo cáo thành công vẫn **không cấp phép Restore**. `CRBackupNativeCore` N0 vẫn đảm nhận Info/CRC một entry riêng. N1 thử nghiệm độc lập chưa nối vào workflow xóa dữ liệu.

**CI/tests:** `native_backup_survey_fixture.py` tạo 9 ZIP synthetic trong thư mục tạm; `native_backup_survey_smoke.m` chạy parser Objective-C trên macOS cho các ca: hợp lệ, path traversal, duplicate, symlink, Metadata thiếu, local name sai, central method sai, descriptor CRC sai, Keychain presence-only. `test_crane_native_backup_survey.py` chạy 11 kiểm thử trên Windows/macOS (bao gồm header-only mẫu Chrome gốc nếu file riêng tư có sẵn; tự SKIP tại CI). `check_native_backup_survey_contract.py` kiểm source không ghi/xóa/Keychain và Root Restore giữ fail-closed. CI mới bao gồm contract, Python tests, clang Foundation smoke. **Chưa xác minh native build macOS/Theos với phần N1 này**; cần lượt GitHub Actions tiếp theo. ZIP gốc Chrome vẫn được Git bỏ qua và không xuất payload.

## 24. G-11 N2 — native single-container ZIP64 writer **chỉ dành cho fixture dùng một lần** (2026-10-15)

**Thực thi native:** `reconstruction/sources/prefs/CRBackupNativeFixtureWriter.h` và `CRBackupNativeFixtureWriter.m` đã được đưa vào Makefile của CranePrefs. `writeDisposableSingleAtRoot:infoData:metadataData:files:directories:error:` nhận **toàn bộ nội dung qua NSData trong RAM**, bao gồm `Info.plist` và `Metadata.plist` binary do `CRBackupNativeCore` sinh từ dữ liệu giả. Không duyệt hay mở source directory/container iPhone, không lấy UID/GID/tên chủ sở hữu thực, không đọc Keychain, không hỗ trợ mật khẩu/multi/Restore.

**Ràng buộc nơi ghi:** bắt buộc thư mục con thực của `NSTemporaryDirectory()` trên macOS/iOS, root không symlink, marker `.crane-disposable-fixture` chính xác `CRANE_DISPOSABLE_FIXTURE_V1\n`, thư mục `output` tồn tại và không symlink, tạo file cố định `output/native-single.cranect` bằng `openat(O_CREAT|O_EXCL|O_NOFOLLOW)`, mode `0600`. Không ghi đè, không có quyền chọn đường dẫn target từ user, chỉ gọi unlinkat với file tự tạo nếu ghi thất bại. Hạn mức 64 ZIP entries, 1 MiB dữ liệu tổng vào, archive tổng tối đa 2 MiB, kiểm path traversal/symlink tên giả lập/file-as-directory/reserved root plists và luôn loại `Keychain.plist`. Đây là **fixture gate**, không phải khả năng chống adversarial race hoàn chỉnh, và không phục vụ backup ứng dụng thật.

**ZIP native encoder:** viết little-endian Local File Header `PK0304`, `version-needed=45`, `flags=0x0808`, raw Deflate `method=8` cho file, Store `method=0` cho thư mục; mọi entry dùng ZIP64 local extra id1/len16 với size `(0,0)` (bit3), descriptor có signature `PK0708` + CRC32 + 64-bit compressed/uncompressed sizes; central ZIP64 extra (uncomp, comp) là kích thước thực, `made-by=(19<<8)|45`, mode giả lập thông thường và EOCD classic. Thứ tự **Info first → thư mục → payload giả → Metadata last**. Các trường Info/Metadata là dữ liệu thử nghiệm do caller cấp, không chứng minh trùng giá trị owner, timestamp, UUID hoặc vendorID của Crane original.

**CI kiểm chứng độc lập:** `native_backup_fixture_writer_smoke.m` tạo **chỉ dữ liệu giả** dưới OS temp với marker, gọi N2 và sau đó dùng reader N0/N1 để kiểm ZIP đọc được, không ghi đè, chặn path traversal, Keychain, file/directory collision và root không đánh dấu. Smoke in duy nhất đường dẫn **archive giả** để `crane_native_writer_verify.py` dùng Python `zipfile` kiểm độc lập **CRC từng file/directory**, dummy bytes, binary plist, ZIP64 local/central và descriptor, flags, compression, attributes; kết quả chỉ là số lượng và cờ `originalCompatibilityProven:false`, `restoreExecutable:false`. `test_crane_native_writer_verify.py` kiểm fail-closed trên ZIP không đúng fixture, malformed/oversize/symlink và CLI output redaction. `check_native_backup_writer_contract.py` bảo đảm mã native không truy cập file container/Keychain và Root Backup/Restore vẫn unavailable. CI thêm Python tests/contract + macOS clang Foundation/zlib smoke cho writer+N0+N1+CRC.

**Chưa hoàn thành:** mã **native mới chưa được macOS CI/Theos/iPhone xác nhận trong lượt này**; nguồn thật/metadata iOS không được phép dùng N2. `CRBackupArchiveSurvey` N1 vẫn là header-only (CRC thật của archive kiểm riêng trên fixture bằng Python); chưa có writer production với lifecycle, nguyên tử hóa output, journal/snapshot/rollback, native metadata acquisition/Keychain, device verification. Mọi Root Backup/Restore trên iPhone vẫn giữ fail-closed, daemon/injection/CraneManager/helper không thay đổi.

## 25. G-11 N3 — native CRC32 streaming toàn bộ dữ liệu ngoài Keychain, chỉ đọc (2026-10-15)

**Đã triển khai Objective-C:** mở rộng `CRBackupArchiveSurvey.h/.m` với **API riêng**, `verifyNonKeychainPayloadAtPath:error:`. N1 `inspectSingleArchiveAtPath:error:` vẫn chạy `SSurvey(fd, NO)` **chỉ kiểm ZIP headers** và giữ nguyên report 10 keys; N3 gọi `SSurvey(fd, YES)` để trước tiên đối chiếu local/central header, ZIP64, data descriptor, path/symlink/traversal, số member/dung lượng rồi **tính CRC32 thật** của từng file/thư mục không phải Keychain. Đọc qua `pread` và zlib raw Deflate (`inflateInit2(...,-MAX_WBITS)`) hoặc ZIP Store, bộ đệm fixed **32 KiB input và 32 KiB output**, không ghi/giải nén ra filesystem, không in tên/path/byte/hashes, không cần chứa toàn bộ payload trong RAM. Chặn vượt kích thước uncompressed khai báo, Deflate kết thúc sớm/trailing bytes, stream bị treo, CRC không khớp và file archive bị thay đổi trong lúc quét. Tổng uncompressed claimed vẫn giới hạn 256MiB và ZIP input 512MiB theo N1.

**Keychain:** nếu member có leaf `Keychain.plist` (kể cả nested và biến thể chữ hoa/thường), kiểm header/name/descriptor như N1 nhưng **không gọi hàm đọc payload/CRC**. Báo cáo số member đã bỏ qua bằng `keychainEntriesSkipped`, `keychainContentsRead:false`. `nonKeychainPayloadCRCVerified:true` chỉ khi mọi member không phải Keychain đã được kiểm thành công. `payloadCRCVerified:true` chỉ nếu **không có bất kỳ Keychain member nào**; không được suy diễn archive với Keychain có CRC toàn bộ. Mọi kết quả `restoreExecutable:false`, không phải bằng chứng người tạo archive hay quyền Restore và CRC không xác thực nguồn gốc.

**Bộ kiểm tra:** `native_backup_survey_fixture.py` có thêm dummy ZIP nén bị sửa nhưng local/central headers/descriptor vẫn nhất quán, ZIP có Keychain giả bị sửa, file thử nghiệm 107KiB để quét qua nhiều chu kỳ buffer và một file ZIP Stored không rỗng. N3 smoke `native_backup_crc_smoke.m` trên macOS phải chứng minh N1 header-only vẫn chấp nhận các ZIP tamper; N3 từ chối payload thường hỏng nhưng chấp nhận ZIP có Keychain fake bị thay đổi mà **không kiểm nội dung Keychain**, và CRC đúng trên file lớn/file Store. N2 smoke cũng gọi N3 để kiểm toàn bộ dữ liệu giả sau khi native writer tạo archive. `test_crane_native_crc_verification.py` có unit test cross-platform cho dữ liệu giả; `check_native_backup_crc_contract.py` kiểm an toàn tĩnh. CI N1 smoke nay link `-lz` vì cùng translation unit có zlib, N3 build/link native smoke riêng và dùng thư mục temp khác N1 tránh tạo fixture trùng; N2 smoke đã tích hợp N3.

**Còn thiếu:** native macOS/Theos build và N3 smoke **chưa được chạy cho thay đổi này**. N3 vẫn không kiểm chứng schema metadata toàn diện, certificate/chữ ký nguồn, mật khẩu, Keychain nội dung hay multi `.cranebk`; chưa gắn vào UI/Restore và không thay đổi daemon/injection/CraneManager/helper. Archive Chrome gốc trong `backup/` vẫn được giữ nguyên, không dùng làm fixture tự động/không phát tán dữ liệu ứng dụng.

## 26. G-11 N4 — native POSIX fixture source scanner + Metadata.plist trên filesystem thật (2026-10-15)

**Mục tiêu:** Tiếp nối N0 (Info reader), N1 (ZIP structure), N2 (in-memory ZIP writer) và N3 (CRC), bước N4 `CRBackupNativeFixtureCollector.h` và `CRBackupNativeFixtureCollector.m` đã được đưa vào `CranePrefs_FILES`. N4 **chỉ** chụp cây thư mục giả lập `<OS-TEMP>/<fixture>/source/com.example.crane.native/` với marker `.crane-disposable-fixture` chính xác, nguồn chỉ có app ID cố định `com.example.crane.native`; không có API nhận đường dẫn container/app ID tùy ý, không gọi MobileContainerManager, không chạm dữ liệu ứng dụng người dùng hoặc Keychain. Bản thân method native gọi trực tiếp writer N2 vào output cố định đã có gate O_EXCL; không bật nút Root Backup/Restore.

**Source scanner an toàn:** root phải là thư mục thật nằm dưới `NSTemporaryDirectory()` đã canonicalize, marker hợp lệ; `openat` + `O_NOFOLLOW` cho thư mục/file, `fstatat(..., AT_SYMLINK_NOFOLLOW)` từng item, giới hạn source 30 entry/512KiB tổng/256KiB mỗi file/depth 6, chỉ ASCII path component an toàn, không theo symbolic links, từ chối hardlink (st_nlink > 1), socket/device/FIFO, mount khác st_dev, reserved `Info.plist`/`Metadata.plist`/`Keychain.plist` kể cả chữ hoa/thường. File được đọc với fd và so inode/dev/size/mode/UID/GID/mtime/ctime trước và sau; thư mục cũng được kiểm inode/timestamp cuối vòng duyệt. Chỉ sau khi toàn bộ cây nguồn vượt qua gate mới cho phép N2 tạo một archive thử nghiệm, không ghi đè và không đổi quyền file source.

**Metadata từ POSIX stat thật của fixture:** Mỗi file/thư mục có 7 keys `NSFileCreationDate` từ `st_birthtimespec`, `NSFileModificationDate` từ `st_mtimespec`, `NSFileOwnerAccountID`/`NSFileGroupOwnerAccountID` từ `st_uid/st_gid`, owner/group names từ `getpwuid_r/getgrgid_r`, `NSFilePosixPermissions` từ mode bits. Dữ liệu được lọc/serialize qua allowlist `CRBackupNativeCore` và đưa vào `Metadata.plist` (không tạo metadata chủ sở hữu giả; chỉ original sample 7/8 field). **Không đoán `NSFileExtensionHidden`** vì POSIX stat không chứng minh được flag Finder/iOS; thiếu trường này còn là gap fidelity. ID và vendorID trong `Info.plist` vẫn là UUID công khai GIẢ để cô lập fixture, tuyệt đối không đại diện thiết bị.

**Smoke CI mới:** `native_backup_fixture_collector_smoke.m` tạo một app tree dùng một lần trong OS temp với Preferences, nested folder, file zero-byte và permissions test; gọi N4 và kiểm N0/N1/N3 trên ZIP do chính native collector+writer tạo. Ca thiếu marker, symlink, hardlink, Keychain, oversize đều bị chặn trước khi có output; ZIP không overwrite. `crane_native_collector_verify.py` đọc file **giả lập đã biết** bằng Python zipfile, kiểm toàn bộ CRC và so UID/GID, owner/group names, POSIX permission, creation/modification timestamps trong binary Metadata.plist với stat của đúng các source files. `test_crane_native_fixture_collector.py` kiểm fail-closed/CLI redaction trên mọi OS; `check_native_fixture_collector_contract.py` kiểm không mở container thật hoặc Keychain. GitHub Actions thêm 2 bước Python và 1 bước biên dịch/chạy macOS Foundation+zlib smoke + verifier độc lập. Archive người dùng Chrome trong `backup/` không được tải, mở payload, sao chép hay thay đổi.

**Giới hạn và trạng thái:** N4 vẫn là **native test-only**, không phải production iOS Backup/Restore. Source là app giả `com.example.crane.native`, không có quyền/điều kiện runtime thực, không có streaming ZIP writer cho container lớn, consistent app freeze, NSFileExtensionHidden, Keychain/password, multi-container, snapshot/journal/rollback, bảo vệ concurrency chống mọi race trên thiết bị. Chưa xác minh macOS/Theos CI với mã N4 cho đến khi người dùng chạy workflow mới. Root actions/daemon/injection/CraneManager/helper giữ nguyên fail-closed.

## 27. G-11 N5 — tiền kiểm native read-only từ bản đồ container của CraneManager (2026-10-15)

**Đã triển khai:** `reconstruction/sources/prefs/CRBackupNativeSourcePreflight.h` và `CRBackupNativeSourcePreflight.m` trong CranePrefs Makefile. Lớp mới nhận `applicationIdentifier`, `containerIdentifier` và resolver conform `CRBackupSourceResolver`. Protocol chỉ gồm **ba selector có thật** trong `CRManager.h`: `isApplicationSupportedByCrane:`, `containerIdentifiersOfApplicationWithIdentifier:`, `pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:`. Mục đích là tiền kiểm ánh xạ **được trả về bởi manager**, thay vì đoán thư mục từ bundle ID hoặc tin đường dẫn kèm theo một file ZIP. N5 không gọi `CraneManager.sharedManager` trực tiếp, không kích hoạt container, không liên kết Root UI; caller sản xuất và chính sách ủy quyền thực tế còn phải nối rõ ràng sau khi có kiểm thử thiết bị.

**Kiểm tra chỉ đọc:** xác nhận app do resolver hỗ trợ, container đã đăng ký (cho phép `DEFAULT` riêng), map không trống, có root tương ứng appID, tối đa 32 root; ID ASCII-safe; root chỉ được là absolute/standardized path, không path traversal/control/backslash. `realpath` + `lstat` + `open(O_RDONLY | O_DIRECTORY | O_NOFOLLOW)` + `fstat` so dev/inode chặn thư mục mất, symlink ở cuối hoặc trung gian (ngoại lệ alias hệ thống `/var` → `/private/var`); chặn root trùng và lồng nhau. Trên iOS canonical root phải dưới `/private/var/mobile/Containers/`, trên macOS smoke root chỉ được dưới `NSTemporaryDirectory()`. **Không gọi `readdir`, không mở con, không trích xuất danh sách file, không đọc payload/Keychain, không ghi dữ liệu.**

**Đầu ra:** Dictionary dạng redacted chỉ có `rootCount`, `associatedGroupCount`, cờ `sourceDirectoryRootsReadable:YES`, `sourceFilesEnumerated:NO`, `sourceContentsRead:NO`, `keychainContentsRead:NO`, `backupReady:NO`, `restoreExecutable:NO`. Không chứa bundle ID, container ID, path, UUID, filename hoặc thông báo lỗi chi tiết. **PASS chỉ có nghĩa mapping/roots tồn tại và mở được — không chứng minh snapshot nhất quán, quyền đọc file, ngữ nghĩa App Group/PlugInKit hay tính tương thích backup gốc.**

**CI:** `native_backup_source_preflight_smoke.m` biên dịch độc lập trên macOS với fake resolver trả 2 thư mục thử nghiệm dưới OS temp; kiểm app/container hợp lệ + DEFAULT, từ chối app/container lạ, map thiếu app root, root trùng/nested, path ngoài vùng cho phép, symlink và group ID bất thường. `test_crane_native_source_preflight.py` kiểm 6 source-contract/regression cases trên mọi OS, `check_native_source_preflight_contract.py` đối chiếu selector CraneManager, fail-closed Root actions và chỉ-đọc; CI có 2 Python steps và native Foundation smoke. **Chưa xác minh macOS/Theos cho N5 trước lượt Actions mới.** Stable daemon/helper/injection/CraneManager vẫn giữ nguyên; N5 chưa nối vào UI và không bật Backup/Restore.

## 28. G-11 N6 — native CraneManager runtime bridge, chỉ đọc, không tự kích hoạt (2026-10-16)

**Triển khai thực tế:** thêm `reconstruction/sources/prefs/CRBackupNativeManagerPreflight.h` và `CRBackupNativeManagerPreflight.m` vào `CranePrefs_FILES`. Method **tường minh** `probeRegisteredApplication:containerIdentifier:error:` tra `NSClassFromString(@"CraneManager")`, xác minh `sharedManager` hiện diện, sau đó gọi singleton bằng `objc_msgSend` đã định kiểu. Các selector nguồn được xác nhận từ `CRManager.h`: `isApplicationSupportedByCrane:`, `containerIdentifiersOfApplicationWithIdentifier:`, `pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:`. Resolver **thật** được chuyển vào N5 `CRBackupNativeSourcePreflight` để xác minh mapping/đường dẫn theo chính logic an toàn N5; không dựng app home hay App Group từ bundle ID và không xuất paths. Bridge chỉ nhận report khi toàn bộ cờ `backupReady`, `restoreExecutable`, `sourceFilesEnumerated`, `sourceContentsRead`, `keychainContentsRead` đều `NO`. Lỗi underlying được thay bằng NSError chung, không có ID/đường dẫn.

**Quan trọng:** đây là **điểm tích hợp callable với manager thực**, *không có trigger tự chạy* (không `+load`, không `+initialize`, chưa được Root UI/controller gọi, không có action Backup mới). Tại thời điểm N6, chưa có một lần gọi bridge với app thật trên iPhone. Khi gọi trên thiết bị, manager vẫn có thể kiểm tra ứng dụng thông qua helper chỉ đọc theo thiết kế manager; bridge không thay đổi giao thức helper, daemon, injection, lifecycle, container registry hoặc Keychain. Thành công vẫn chỉ là kiểm tra root, **không phải Backup-ready/Restore-ready**.

**Native macOS smoke:** `native_backup_manager_bridge_smoke.m` tạo lớp `CraneManager` giả bằng Objective-C runtime `objc_allocateClassPair` với đúng `+sharedManager` và ba API đọc, rồi gọi **cùng mã bridge N6/N5** trên hai root chỉ dùng OS temp. Test xác nhận manager được hỏi đủ ba selector, `DEFAULT` được resolver cung cấp, ứng dụng/container không đăng ký bị từ chối, map root trùng bị từ chối, manager không có và singleton nil fail-closed; không link libcrane thật trên macOS. `test_crane_native_manager_bridge.py` kiểm 7 regression cases; `check_native_manager_bridge_contract.py` cấm gọi selector mutating và bảo đảm UI Backup/Restore vẫn unavailable. CI thêm 2 bước Python và standalone macOS Foundation clang smoke, package Theos cũng biên dịch bridge qua Makefile.

**Giới hạn:** chưa đo quyền thực thi của từng file, app lifecycle/snapshot, App Group/PlugInKit compatibility trên iPhone, metadata/IDFV/Keychain nguồn thật, streaming writer, atomic backup publishing hay rollback. Không bật nút Backup/Restore trước khi có authority, giao thức kiểm tra dữ liệu, device test và kế hoạch xử lý lỗi. Mã N6 chỉ cần thử nghiệm CI macOS/Theos lần đầu trong workflow tiếp theo; không tuyên bố build native N6 PASS khi chưa chạy.

## 29. G-11 N7 — typed app/App Group/PlugInKit root mapping, read-only (2026-10-16)

**Lý do cần N7:** `CRManager.m` của bản tái dựng có selector gốc `enumerate:pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:` với ba **loại entry**: type 0 dữ liệu app, type 1 App Group, type 2 PlugInKit. API `pathsAssociatedToContainerWithIdentifier:` mà N5/N6 dùng trả dictionary `identifier -> path`, làm **mất thông tin type** và có thể ghi đè âm thầm khi nhiều nguồn có trùng identifier. Nếu sao lưu thật từ dictionary này thì có nguy cơ thiếu PlugInKit hoặc chụp sai container.

**Triển khai:** thêm `CRBackupNativeTypedPreflight.h` / `CRBackupNativeTypedPreflight.m` vào CranePrefs Makefile và selector `probeTypedRegisteredApplication:containerIdentifier:error:` trong N6 adapter. Adapter mới chỉ được gọi tường minh qua singleton `CraneManager` có sẵn; không tự chạy trong Settings, không gọi các selector mutating. N7 trước tiên chạy nguyên vẹn N5 để kiểm app/container registry và root directories bằng `lstat/open(O_NOFOLLOW)/fstat`, sau đó gọi **hai lượt typed enumeration** qua manager và so khớp type, identifier, path. Bắt buộc đúng một type 0 trùng application ID; group/plugin type 1/2 không được trùng app ID; mỗi identifier chỉ xuất hiện một lần, giới hạn 32 root. Lấy lại flattened map và kiểm đầy đủ số entry cùng `identifier -> path`; thiếu/khác/duplicate/mapping biến đổi ở hai lượt đều fail-closed. Báo cáo chỉ có `applicationRootCount`, `appGroupRootCount`, `plugInKitRootCount`, `rootCount`, `rootDirectoryMetadataChecked` và cờ `sourceFilesEnumerated:NO`, `sourceContentsRead:NO`, `keychainContentsRead:NO`, `backupReady:NO`, `restoreExecutable:NO`. Không ghi/log ID, path, filename hay bất kỳ metadata riêng tư nào. `rootDirectoryMetadataChecked` chỉ ghi nhận N5 kiểm stat của chính root, **không có duyệt file con**.

**Kiểm thử:** `native_backup_typed_preflight_smoke.m` tạo resolver giả với ba root dưới OS temp, kiểm happy path, DEFAULT, duplicate typed identifier, unsupported type, thiếu PlugInKit, path khác flatten map, mapping biến đổi giữa hai lượt và app root bị đổi type. Smoke N6 singleton fake được mở rộng selector enumerate và gọi entrypoint mới qua **cùng adapter sản xuất**, không link daemon/XPC hoặc truy cập thiết bị. `test_crane_native_typed_preflight.py` kiểm 8 regression cases; `check_native_typed_preflight_contract.py` giữ nguyên read-only/Root UI fail-closed; GitHub Actions thêm hai bước Python và native Foundation standalone smoke (đồng thời link N7 trong smoke N6).

**Giới hạn:** người dùng đã báo build native N7 PASS, nhưng vẫn chưa có root inventory thực trên iPhone hoặc xác thực snapshot atomic. Hai lượt liệt kê chỉ phát hiện một số biến động, **không phải lock/snapshot chống thay đổi sau kiểm**. Không cấp quyền Backup/Restore, không thay thế logic source traversal/metadata/Keychain, không thay đổi daemon/injection/CraneManager. Bước kế tiếp N8 là chẩn đoán bằng thao tác xác nhận trên app thử nghiệm không chứa dữ liệu riêng tư.

## 30. G-11 N8 — opt-in root diagnostic cho ứng dụng disposable, read-only (2026-10-16)

**Mục đích:** nối N6/N7 tới một điểm kích hoạt thật nhưng có rào chắn trong Settings để sau này kiểm chứng app/App Group/PlugInKit source map trên iPhone, *không mở Backup/Restore*, không chạm các ứng dụng thông thường. Đây không phải chức năng gốc Crane mà là kiểm chứng tạm thời, chỉ dùng app disposable.

**Gate:** module `CRBackupDisposableDiagnostic.h/.m` chỉ nhận bundle identifier chính xác `com.example.crane.native` và container ID là UUID (không DEFAULT). Phương thức `probeApplicationIdentifier:containerIdentifier:userConfirmedOnce:error:` từ chối trước khi liên hệ CraneManager khi chưa xác nhận hoặc sai định danh, error chỉ có domain/code/message cố định. Khi có xác nhận, gọi N6 `probeTypedRegisteredApplication` để N7/N5 kiểm soát đăng ký container, mapping type 0/1/2 và lstat/open(O_NOFOLLOW)/fstat của chính các root. Mọi kết quả chỉ chứa số lượng app/group/plugin/root, các cờ `sourceFilesEnumerated:NO`, `sourceContentsRead:NO`, `keychainContentsRead:NO`, `backupReady:NO`, `restoreExecutable:NO`. Không truy xuất file con, keychain, metadata file, hay lưu trữ ID/path, không gọi các API mutation.

**UI opt-in:** `CRPContainerConfigurationListController` chỉ thêm nhóm thử nghiệm khi identity qua gate. Người dùng nhấn **Check source roots (read-only)**, thấy cảnh báo chỉ dùng app disposable không có dữ liệu riêng tư; Cancel thoát không probe. Nhấn **Check roots** mới gọi N8; trước đó recheck app/container của controller không thay đổi để tránh dùng lựa chọn cũ. Chỉ hiển thị counter hoặc lỗi cố định; không NSLog thông tin source. Mở Settings, dựng specifier, chuyển tab hay restart không kích hoạt N8. Root `createMultiBackupTapped`/`restoreMultiBackupTapped` tiếp tục unavailable.

**Kiểm chứng:** mở rộng `native_backup_manager_bridge_smoke.m` với same Foundation disposable runtime manager: unconfirmed, sai appID, DEFAULT đều return error 1 và `gReadCalls` không tăng; xác nhận hợp lệ trả report 10 trường fail-safe, mapping trùng dẫn đến error 2 không lộ identity. Thêm `test_crane_disposable_source_diagnostic.py` (8 unit tests), `check_disposable_source_diagnostic_contract.py`, CI source-contract + unit, link N8 vào macOS singleton mock và Theos Prefs Makefile. Local 2026-10-16: N8 contract PASS; toàn bộ Python unittest test_crane_*.py đạt 269 cases (268 PASS, 1 SKIP, 0 FAIL); N5/N6/N7 và Root action/notification contracts PASS; compileall Python, git diff --check PASS (chỉ warning CRLF trên Windows). Người dùng đã xác nhận build N8 PASS trong lượt tiếp theo; thao tác N8 trên app thử nghiệm iPhone vẫn chưa được báo kiểm chứng.

**Giới hạn:** chỉ quan sát root **tại thời điểm chạy** và có thể bị stale sau đó; không là snapshot/lock, không xác thực nội dung file, ownership/vòng đời app, metadata/keychain/ZIP. Phải có app fixture chuyên dụng đã cài trên thiết bị với ID trên và container UUID được đăng ký, tránh mọi app có dữ liệu thật. Không chạy thử với app cá nhân và không bật production backup/restore chỉ vì diagnostic pass.

## 31. G-11 N9 — terminal root/registry revalidation for typed source inventory (2026-10-16)

**Khoảng hở:** N7 ban đầu chỉ kiểm tra đăng ký app/container và root filesystem trong N5 **một lần trước** hai lượt typed enumerate. Nếu manager thu hồi đăng ký hoặc root mapping bị thay thế sau lượt đầu, báo cáo N7 có thể phản ánh root không còn hợp lệ. Trường hợp dictionary map đổi đúng lúc kiểm tra cũng có thể vượt qua phép so số lượng, vì các path khác nhau vẫn tồn tại.

**Thay đổi N9:** `CRBackupNativeTypedPreflight.m` giữ hai lượt typed enumerate cùng so khớp dictionary, sau đó chạy **lại toàn bộ N5** trên manager đang dùng để xác minh app/container còn đăng ký, root topology và khả năng mở đúng directory root. So lại `rootCount` và số nguồn group/plugin; nếu thay đổi trả lỗi redacted code 8. Snapshot dictionary sau lượt typed được `copy`; sau N5 lần hai lại lấy và `copy` flattened mapping cuối cùng, yêu cầu `isEqualToDictionary:` với mapping đã xác thực; nếu có đổi path/identity trả lỗi redacted code 9. Không đổi API report hay đường UI, không gọi API mutation, không xuất path/ID. Đây là fail-closed best-effort cho **diagnostic** N8 chứ không nâng quyền Backup/Restore.

**Fixture regression:** `native_backup_typed_preflight_smoke.m` thêm mode 7 thu hồi app registration sau lượt N5 đầu (code 8); mode 8 đổi chỗ hai path group/plugin hợp lệ trước N5 cuối, vẫn qua được root metadata nhưng phải bị chặn khi so mapping cuối (code 9); mode 9 chỉ đổi mapping sau N5 cuối (code 9). Tất cả path là ba thư mục disposable dưới OS TEMP, không có dữ liệu người dùng. Python N7/N9 source tests và contract kiểm thứ tự root check → final copied mapping, chế độ fail-closed, không mở file con/Keychain, cùng CI đã có sẵn.

**Giới hạn:** N5 lần hai chỉ kiểm `lstat/open(O_NOFOLLOW)/fstat` tại thời điểm gọi, không giữ file descriptor hoặc khóa container qua những lần đọc. Không chống được thay đổi ngay sau lần kiểm cuối, thay đổi identity cùng path hợp lệ giữa hai lần check, hoặc giả lập thay đổi registry giữa các lệnh. Chưa có snapshot production, atomic backup writer, Keychain policy hoặc rollback; `backupReady:NO` và `restoreExecutable:NO` là bất biến. Người dùng đã xác nhận N9 build PASS; vẫn cần kiểm tra thiết bị thử nghiệm, không coi Python source tests là chứng nhận native.

## 32. G-11 N10 — ephemeral root dev/inode continuity (2026-10-16)

**Khoảng hở sau N9:** hai lượt N5 đều kiểm `lstat/open(O_NOFOLLOW)/fstat` của từng thư mục nguồn, nhưng chỉ trả số lượng root, không giữ danh tính filesystem từ lần đầu để đối chiếu lần cuối. Nếu thư mục hợp lệ bị rename rồi tạo mới ở **chính đường dẫn cũ** trong lúc typed enumerate, N9 có thể thấy app/container còn đăng ký, các path string không đổi và hai N5 đều hợp lệ, dù thực chất nguồn đã thay inode.

**Triển khai N10:** `CRBackupNativeSourcePreflight` thêm token `CRBackupNativeRootIdentitySnapshot` chỉ tồn tại trong bộ nhớ. Cùng `CR5RootPath` đã có kiểm tra canonical allowlist, lstat/open(O_NOFOLLOW)/fstat, N10 ghi metadata của **chính root** theo identifier gồm canonical path, `st_dev` và `st_ino`; không duyệt file con, không mở Keychain hoặc đọc payload. Sau N5 lần đầu, N7 lấy bản sao mapping và capture token. Sau N9 đối chiếu registration và flattened mapping lần cuối, N10 capture lại và yêu cầu tập hợp identifier/path/dev/inode trùng hoàn toàn; token thiếu hay root identity thay đổi đều trả error 10/11 có mô tả cố định, không lộ path. Không xuất token ra report N5/N7/N8 và không bao giờ persist/log token. `backupReady:NO` và `restoreExecutable:NO` tiếp tục bất biến.

**Mock và kiểm chứng:** `native_backup_typed_preflight_smoke.m` thêm mode 10 trong ba thư mục dummy dưới OS TEMP: sau hai typed enumerate, di chuyển riêng thư mục root sang đường dự phòng rồi tạo thư mục mới tại cùng pathname; N5 vẫn có thể mở pathname, N9 mapping string vẫn bằng nhau nhưng N10 phải reject code 11. Điều chỉnh mode 8/9 vì N10 thêm một lần đọc map lúc capture đầu. Python source tests và hai contract N5/N7 đã cập nhật, CI chạy lại macOS Foundation smoke và Theos package build. Không có thao tác rename trên bất cứ root iOS/app thật nào trong sản phẩm — chỉ fixture test tạm của macOS.

**Giới hạn:** đây là phát hiện thay đổi inode trong **khoảng kiểm tra**, không phải khóa filesystem, snapshot nhất quán theo thời điểm, bảo đảm root không biến đổi ngay sau capture cuối, hoặc ngăn ABA (inode tái sử dụng). Không xác minh bytes/Keychain/owner/thiết kế writer, không cấp phép đọc file thật hoặc production Backup/Restore. Kiểm chứng local N10: toàn bộ 278 Python test (277 PASS, 1 Windows/POSIX SKIP, 0 FAIL), N5/N7-N10/N8 contracts PASS, compileall Python PASS, git diff --check PASS (chỉ cảnh báo LF/CRLF Windows). Native macOS Foundation smoke/Theos iOS và thiết bị vẫn chưa được chạy cho N10; người dùng xác nhận N9 build PASS trước N10.

**Nguồn kiểm toán tại workspace:** `analysis/objc_classes.json`, bản decompile `0x20E64`, `0x211A8`, `0x2614C`, `0x2619C`, `0x25A8C`, `0x24CF8`, `0x257AC`, `0x29504`, `0x2B9B0`, `0x2ADA0`, `0x2B31C`, và các helpers/blocks chỉ rõ trong mục 2-3; đối chiếu với `sources/prefs/CRPreferences.m`, `sources/libcrane/CRManager.m`, `sources/cranehelperd/CRHelperd.m`.
