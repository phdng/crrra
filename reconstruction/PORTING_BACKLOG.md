# Crane — Porting Gap Inventory & Implementation Backlog

Ngày kiểm kê: 2026-10-12. Nhánh quan sát: `chore/reconstruction-build-ci`.

## Quy ước

- **ABSENT**: chưa có triển khai chức năng tương ứng trong source.
- **PARTIAL**: có source/hook nhưng còn hành vi, tích hợp hoặc giao thức chưa tương đương.
- **SOURCE_PORTED**: triển khai mã nguồn được báo cáo hoàn chỉnh, **không có nghĩa runtime pass**.
- **VERIFY**: không kết luận thiếu mã chỉ từ tài liệu cũ; phải so lại source với export trước khi bổ sung.
- Ưu tiên **P0** cho các dependency trọng yếu/isolation, **P1** cho chức năng người dùng, **P2** cho tích hợp.
- Đây là **backlog triển khai**, không phải tuyên bố binary parity, CI xanh hay chạy ổn trên thiết bị.

## 1. Danh sách triển khai

| ID | Feature | Trạng thái | Đầu việc cụ thể | Bằng chứng / nơi kiểm tra | Priority | Điều kiện nghiệm thu |
|---|---|---|---|---|---|---|
| F-01 | Launch redirection | SOURCE_PORTED / untested | Kiểm tra ABI SpringBoard/runningboardd và launcher integration thực tế | `CRSpringBoard.m`, export 0x1BF10/0x1BD44 | P0 VERIFY | Build + test launch DEFAULT và non-default, injection insurance |
| F-02 | In-app env/dirs | SOURCE_PORTED / untested | Không tự port lại; regression environment/layout | Main dylib | P2 VERIFY | Directory/environment differential tests |
| F-03 | File/container isolation | SOURCE_PORTED / untested | Test unlink/path isolation, ghi nhận NULL edge case bản gốc | Main dylib | P0 VERIFY | Không rò hoặc xóa nhầm dữ liệu giữa containers |
| F-04 | Sandbox lookup | SOURCE_PORTED / untested | Test sandbox lookup theo app/container | Main dylib | P1 VERIFY | Differential test |
| F-05 | Preferences isolation | PARTIAL | Kiểm tra PID→container/auth transport và sự khác biệt protocol U-01 | `CRCfprefs.m`, `CRManager.m` | P0 | Preferences độc lập giữa container, restart safe |
| F-06 | Container resolution | PARTIAL | Port `_populateContainerDirectory:ofType:` từ bằng chứng khả dụng; hoàn thiện mapping, cache và error cases | `CRMCM.m`, `CRManager.m`, U-01/U-04 | P0 | Container data/group paths đúng, không fallback sai |
| F-07 | Keychain isolation | ABSENT | Khảo sát export securityd/code-signature patchfind; implement đúng cách ly keychain, không stub; validate lỗi an toàn | `CRSupport.m`, U-03; securityd chain | P0 BLOCKED BY EVIDENCE | Không đọc/ghi keychain chéo, có fallback an toàn, device tests |
| F-08 | APNs/notification routing | PARTIAL, report may be stale | Audit từng hook từ `CBEC.c` đối chiếu `CRBadgeStore.m`, `CRApsd.m`; hoàn tất các caller bất đồng bộ, metadata, forwarding | U-10, `CraneSB.dylib_export_for_ai/decompile` | P1 | Token/topics và notification delivery đúng theo container |
| F-09 | System accounts | PARTIAL | Hoàn thiện transport U-01 và branch gamed/Game Center, verify Core Data cache | `CRAccountsd.m`, U-01 | P1 | Độc lập account database, iCloud follow-up không sai |
| F-10 | Game Center | STRUCTURE ONLY | Khôi phục model Game Center/manager state từ binary còn thiếu; không phỏng đoán | U-06 trong hiện trạng feature (lưu ý U-06 trong uncertainty register là backup format) | P1 BLOCKED BY EVIDENCE | Đúng enable list và container/account behavior |
| F-11 | Device ID | PARTIAL | Đổi helperd storage thay thế `NSUserDefaults` sang lsd extension recovered; xác thực quyền caller | `CRLsd.m`, `CRManager.m`, U-01 | P1 | UUID ổn định và cách ly theo container |
| F-12 | Plug-in enumeration | PARTIAL | Nối extension metadata với notification path, xác nhận class/hook runtime | `CRPKD.m` / support sources, U-10 | P1 | Extension enumeration đúng per-container |
| F-13 | Selection UI | PARTIAL | Khôi phục callback success-handler BOOL/delay, menu/badge UI exactness | `CRMenuHooks.m`, 0x137FC…0x16820 | P1 | Menu modern/legacy, biometric, launch, UI comparison |
| F-14 | Badge UI + store | PARTIAL, active work | Audit bản mới của `CRBadgeStore.m` với export 0xA4A0, 0xFD9C, 0x10BEC, 0x10CB0; hoàn thiện label/view native; validate async refresh | `CRBadgeStore.m`, `CRBadgeAction` | P1 | Accurate aggregate and per-container display, zero removes scoped notifications |
| F-15 | Settings UI | PARTIAL | Port pane backup/restore, Choicy, suggestions; kiểm tra pane specifier/handlers | `sources/prefs`, `CranePrefs_export_for_ai` | P1 | 3/3 panes + expected subcontrollers and navigation |
| F-16 | Lifecycle | PARTIAL | Khôi phục on-disk ID/layout, unknown container handling, active-delete guard, rollback | `CRManager.m`, `CranePrefs` 0x86A8/0xB638, U-04/U-09 | P0 | CRUD không mất dữ liệu; migration consistency |
| F-17 | Backup/restore | ABSENT | Reverse/archive manifest, restore, encryption, keychain dump; triển khai sau lifecycle/keychain | `CranePrefs_export_for_ai`, U-06 | P1 BLOCKED BY EVIDENCE | Round-trip data/keychain, corrupted archive failure safe |
| F-18 | Biometrics | SOURCE_PORTED / untested | Biometric switch regression tests | Source biometric hooks | P1 VERIFY | Success/cancel/locked behavior |
| F-19 | Helper XPC | PARTIAL, own transport | Khôi phục interface gốc NSXPC, methods/replies; thay/bridge raw XPC có kiểm soát | `cranehelperd`, `CRManager.m`, U-01 | P0 BLOCKED BY EVIDENCE | Authorized requests and protocol compatibility, runtime tested |
| F-20 | Self-verification | PARTIAL | Port injection-fixup error producer; kiểm tra timeout/fail-open/status reply | `CRSpringBoard.m`, U-01 | P1 | Missing dylib vs communication failures correctly distinguished |
| F-21 | Choicy | PARTIAL | Implement `CRPContainerChoicyOverwriteListController`, settings persistence | `sources/prefs`, `CranePrefs_export_for_ai` | P1 | Per-container override editor behaves as original |
| F-22 | Siri/Shortcuts | ABSENT | Recover `CraneIntentHandlerShared` and intent response codes; extension packaging | U-08; missing Shortcuts export | P2 BLOCKED BY EVIDENCE | Siri intents correctly invoke container actions |
| F-23 | Activator | PARTIAL | Observer dispatch and callback semantics, runtime icon/event verification | `CraneActivatorManager`, `CRManager.m` | P2 | Event registration, switch, abort, icon differentiation |

## 1A. Audit hook-level notification: batch 2026-10-12

| Native offset | Reconstruction | Tình trạng / giới hạn |
|---|---|---|
| `0xA4A0`, `0x20F58` | `CRBadgeContainerForConnectionAndApplication` | Ported gate iOS 17+ and 9 caller sites; runtime unverified |
| `0xFD9C` | `CRBadgePublicSet` | Ported XPC resolver, `intValue`, badge-zero scoped removal; static contract |
| `0xF524` | `CRBadgeRemoveAllRecords` | Ported predicate-based remove-all (does not call unscoped original when enabled) |
| `0xF398`, `0x11FC0` | `CRBadgeRemoveRecordsPassingTest` | Ported predicate then container filter; requires device validation |
| `0xF59C` | `CRBadgeRecordLookup` | Ported filtering and copyWithoutContainerID; type/runtime safety differs defensively |
| `0xF750` | `CRBadgeRecordsLookup` | Ported collection filtering, copied output |
| `0xFA20`, `0x120B0` | `CRBadgeRecordsLookupWithReply` | Ported asynchronous reply mapping using captured connection container |
| `0xBE18` | `CRBadgeRecordSource` | Corrected nil-vs-present keyed userInfo handling; requires live behavior comparison |
| `0xBA6C` | `CRBadgeContainerForNotificationInfo` | Recovered nil userInfo/appID → DEFAULT, present source authoritative, absent source → conditional DEFAULT; generic keyed info |
| `0xF254` | `CRBadgeOuterSave` | Now uses shared 0xBA6C resolver before forwarding and async foreground clear |
| Save revisions/options | `CRBadgeSourceForRecord` | Uses same 0xBA6C resolver; no longer discards nil userInfo/appID or present non-string tagged source in this path |

**Batch 0xBE18 / 0x11884 / 0x115F4:** cùng dùng `CRBadgeSourceMarkerFromInfo` trong record lookup, record similarity và notification-content mutation, bảo toàn `nil` vs `DEFAULT` và keyed `userInfo` gốc. Đã bổ sung regression assertions. Không tuyên bố runtime pass.

**Batch bổ sung:** `0x1119C` bulletin provider và `0x11420` bulletin action giờ dùng chung resolver `0xBA6C` thay vì nhánh kiểm tra riêng chỉ nhận NSDictionary. `0x115F4` content mutation đọc marker từ userInfo keyed collection, giữ phân biệt nil và thiếu marker theo `0xBE18`. Các contract assertions đã được cập nhật.

Remaining unresolved: exhaustive `0xCBEC` hook registration matrix, original asynchronous foreground-check propagation, native badge cell/view fidelity, dynamic system-private class availability. This is a **targeted** matrix, not a claim to have audited all 40+ hooks.

## 2. Thứ tự triển khai có dependency

1. **G0 — Evidence & parity audit:** đối chiếu exports và mã mới, cập nhật feature report (F-08/F-14 thay đổi nhiều). Ghi mapping selector → original offset → implementation → test.
2. **G1 — Core transport/data correctness:** U-01/F-19 → F-06/F-16 → F-05/F-09/F-11. Trước khi sửa giao thức phải có bằng chứng từ original daemon; không tạo tương thích giả.
3. **G2 — Isolation/security:** U-03/F-07; tiến hành có test harness, fallback an toàn và thử nghiệm trên thiết bị.
4. **G3 — Notifications:** F-08/F-12/F-14, bao gồm kiểm thử callback bất đồng bộ, badge reset, publish/deliver và foreground semantics.
5. **G4 — User UI:** F-13/F-15/F-21, sau đó F-10 và F-23.
6. **G5 — Data portability:** U-04/U-06/F-17, sau khi F-07/F-16 ổn định.
7. **G6 — Optional integrations:** U-08/F-22.
8. **G7 — Validation:** rootful + roothide Theos build, artifact inspection, installation, injection, 76 test IDs và differential tests.

## 3. Những điều không nên hiểu sai

- Feature summary trong `IMPLEMENTATION_STATUS.md` là **snapshot**, không được tự động xem là đã cập nhật theo các lần sửa gần nhất của `CRBadgeStore.m`.
- `F-10` được gắn U-06 trong bảng feature, nhưng U-06 của `uncertainty_register.md` bàn về **backup archive**. Đây là bất nhất tài liệu cần sửa sau khi có evidence.
- Không gọi 5 nhóm SOURCE_PORTED là runtime passed.
- Không thử backup/restore hoặc keychain trên dữ liệu thật trước khi test hoàn nguyên và isolation.
- Không commit/push thay đổi kiểm kê này nếu chưa có yêu cầu.

## 4. Cách triển khai theo lô (ưu tiên tốc độ nhưng giữ fidelity)

- Mỗi lượt xử lý **3–8 thay đổi có liên quan** hoặc một phân hệ có thể nghiệm thu; không dừng ở một selector/nhận xét nếu còn công việc an toàn trong cùng nhóm.
- Trong cùng lượt: (1) đọc export gốc cho nhóm, (2) đánh dấu ported/partial/missing, (3) sửa tất cả sai lệch đã xác nhận, (4) bổ sung static contracts/regressions, (5) chạy kiểm tra tổng hợp, (6) cập nhật bảng trạng thái và session.
- Ưu tiên batch ít rủi ro: F-08/F-14 notification/BadgeStore; F-13/F-15/F-21 UI; F-05/F-06/F-11 PID routing; không triển khai dựa trên phỏng đoán giao thức/helper, keychain, backup.
- Khi một mục bị chặn do thiếu binary gốc, chuyển sang mục có bằng chứng rõ ràng trong **cùng lượt**, tránh dừng toàn bộ phiên.
- Không commit/push trừ khi được yêu cầu; build native và device tests vẫn là cổng nghiệm thu bắt buộc.

## 5. Các bước thực hiện ngay

- [ ] Lập mapping hook-level cho CraneSB/CraneSupport từ export và mã nguồn; đánh dấu missing/partial/ported có evidence.
- [ ] Khắc phục sai lệch tài liệu F-08/F-14 và bất nhất U-06.
- [ ] Kiểm tra các chức năng Preferences còn thiếu bằng export CranePrefs.
- [ ] Viết regression contracts cho từng hook được port; mỗi patch hẹp một nhóm hành vi.
- [ ] Chạy CI rootful/roothide rồi device tests khi có môi trường phù hợp.
