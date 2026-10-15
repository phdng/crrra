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

**Nguồn kiểm toán tại workspace:** `analysis/objc_classes.json`, bản decompile `0x20E64`, `0x211A8`, `0x2614C`, `0x2619C`, `0x25A8C`, `0x24CF8`, `0x257AC`, `0x29504`, `0x2B9B0`, `0x2ADA0`, `0x2B31C`, và các helpers/blocks chỉ rõ trong mục 2-3; đối chiếu với `sources/prefs/CRPreferences.m`, `sources/libcrane/CRManager.m`, `sources/cranehelperd/CRHelperd.m`.
