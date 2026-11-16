# RESEARCH: Cuộc gọi đến của Zalo không báo trên Apple Watch

## Vấn đề

Apple Watch chỉ báo **cuộc gọi nhỡ** của Zalo, không báo **cuộc gọi đến**. Đồng hồ Xiaomi/Huawei thì báo được. Mục tiêu: tìm nguyên nhân và cách để Watch báo khi có cuộc gọi Zalo đến.

## Kết luận

- Zalo **có dùng CallKit** (bản 26.11.01) và nhận cuộc gọi qua VoIP push. Cuộc gọi đến là cuộc gọi CallKit thật, iOS chấp nhận không lỗi.
- Zalo **không có app watchOS**. Theo các thảo luận trên Apple Developer Forums, cuộc gọi CallKit của app bên thứ ba không tự hiện trên Watch; muốn hiện thì app cần có app watchOS riêng. Đây là lý do Watch im lặng khi có cuộc gọi đến.
- Cuộc gọi nhỡ là thông báo thường nên được phản chiếu sang Watch. Vì vậy chỉ cuộc gọi nhỡ hiện trên Watch.
- Cách khắc phục khả thi: tweak đẩy thông báo thường (lặp lại) trong lúc cuộc gọi đang đổ chuông, chỉ khi iPhone đang khoá. Đã làm và test được trên máy thật, xem phần "Tweak".

## Nền tảng

Kiến thức chung, chưa tự kiểm chứng trên máy:

- Thông báo thường chỉ được phản chiếu sang Apple Watch khi iPhone đang khoá.
- Đồng hồ bên thứ ba (Xiaomi/Huawei) dùng ANCS nên nhận mọi thứ trong Trung tâm thông báo của iPhone, kể cả cuộc gọi CallKit. Đây là suy luận giải thích vì sao chúng báo được, chưa kiểm chứng.
- Tweak chỉ chạy trên iPhone. Không cần can thiệp gì trên Watch.
- Nhịp rung trên Watch do watchOS quyết định, app không đổi được kiểu rung.

## Đối tượng phân tích

- IPA Zalo đã giải mã (`Zalo_261101.ipa`), giải nén ra `Payload/Zalo.app`
- Bundle ID `vn.com.vng.zingalo`, phiên bản `26.11.01`, build `261101802`, `MinimumOSVersion` 15.1
- PlugIns: NotificationContentExtension, NotificationServiceExtension, ShareExtension, ZaloIntentsExtension, ZaloTodayExtension. **Không có thư mục `Watch`, không có app watchOS.**
- `UIBackgroundModes`: audio, location, remote-notification, **voip**, fetch, processing

## Zalo xử lý cuộc gọi đến như thế nào

Từ phân tích binary (`strings`, `otool`, `ipsw class-dump`):

- Binary link `CallKit`, `PushKit`, `UserNotifications`. Có `CXProvider`, `CXCallController`, `CXCallObserver`, `PKPushRegistry`.
- Class chính: `CallKitFlowManager`, `GCCallKitFlowManager` (cuộc gọi nhóm), `ZrtpVoipService`, `ZLCallManager`, `ZaloCallViewController`, `LTCallNotificationManager`.
- Có hai đường báo CallKit, theo log `Report callkit [PK]` (VoIP push) và `Report callkit [SK]` (chưa rõ nghĩa, có thể là socket).
- Có nhiều cờ bật/tắt CallKit: `isSupportCallKit`, `useCallkit`, `isShowCallKit`, `enableCallKit`, cờ server `features.voip.enable_update_callkit`; khoá cấu hình `enable_use_callkit_as_default`, `callkit_new_flow`, `enable_callkit_integration_setting`, `video_callkit`. Giá trị chưa giải mã, nhưng trên máy test CallKit đang bật (`useCallKit: 1` trong log).
- Notification Service Extension không link CallKit/PushKit, không xử lý cuộc gọi.
- Zalo có sẵn bộ đẩy thông báo cuộc gọi kiểu cũ: `-[ZrtpVoipService startSchedulePushNotifIncomingCall]` (timer 7 giây), `-[ZrtpVoipService firePushIncomingCallNotif:]`, `-[LTCallNotificationManager pushCallNotificationWithType:userInfo:]`. Bộ này **không** được khởi động ở đường CallKit. Chưa dùng, giữ làm phương án dự phòng.

## Bằng chứng từ máy thật

Đọc từ thư mục dữ liệu của app Zalo trên máy test (đường dẫn dưới đây tính từ thư mục đó). Chỉ đọc, không sửa.

Log cuộc gọi: `Documents/LogSocket/call.txt`. Một cuộc gọi đến điển hình (iPhone khoá, Zalo ở nền):

1. `Receive incoming push: PKPushTypeVoIP`
2. `Report callkit [PK]` rồi `Report new incoming call to provider with uuid: ...` (tức `reportNewIncomingCall`)
3. Khoảng 0,2 đến 1,5 giây sau: `Provider did receive response incoming`, tức iOS chấp nhận không lỗi
4. `CALLKIT started 45s`, rồi Zalo tự mở `ZaloCallViewController`, trạng thái ZRTP `INCOMING ===> RINGRING`

Hai điểm đáng chú ý khi làm tweak:

- Zalo gọi `reportNewIncomingCall` **hai lần với cùng một UUID**. Lần hai có `handle` rỗng (cập nhật thông tin) và CallKit trả lỗi trùng cuộc gọi.
- Zalo cũng gọi `reportCallEnded` hai lần cho mỗi cuộc gọi. Không gây hại.

## Tweak ZaloWatchAlert

Thiết kế: chỉ hook API CallKit **công khai** trong tiến trình Zalo, không phụ thuộc tên class hay offset của Zalo.

- `-[CXProvider reportNewIncomingCallWithUUID:update:completion:]`: bắt đầu báo.
- `-[CXProvider reportCallWithUUID:endedAtDate:reason:]`, `CXCallObserver` (`hasConnected`/`hasEnded`), hoặc lỗi của lần báo đầu: dừng báo và xoá thông báo.
- Thông báo: tiêu đề là `update.localizedCallerName` (đúng tên liên hệ khi test; `remoteHandle` chỉ là ID mã hoá), nội dung "Cuộc gọi Zalo đến" / "Cuộc gọi video Zalo đến", âm mặc định, lặp mỗi 2 giây, tối đa 22 lần (khoảng 44 giây, khớp timer CallKit 45 giây của Zalo).
- Chỉ báo khi iPhone **đang khoá** (`ZWADeviceLocked()`). Khi đang dùng iPhone thì không đẩy gì, và nếu mở khoá giữa lúc đang đổ chuông thì dừng ngay và xoá thông báo.
- Mã nguồn debug nằm trong một khối duy nhất dưới cờ `ZWA_DEBUG`, chỉ bật khi `build.sh debug` (`ZALOWATCHALERT_DEBUG=1`). Bản thường không có log. Bản debug ghi `tmp/ZaloWatchAlert.log` trong thư mục dữ liệu của Zalo.
- Có `layout/DEBIAN/postinst` và `postrm` (`killall Zalo`, `postrm` chỉ khi `remove|purge`) vì Sileo không tự khởi động lại Zalo.

### Các quyết định rút ra từ test trên máy thật

| Vấn đề gặp | Nguyên nhân | Cách xử lý |
|---|---|---|
| Thông báo hiện nhưng Watch không rung | Thông báo không có âm thanh | Dùng `UNNotificationSound defaultSound`. iOS tắt tiếng này khi cuộc gọi đang đổ chuông (theo người dùng, chưa đo) |
| Chỉ rung một lần mỗi cuộc gọi | Lần báo CallKit thứ hai (trùng UUID) trả lỗi, tweak coi là thất bại và dừng | Nhớ UUID đã báo, lần báo trùng chuyển thẳng cho Zalo, không dừng |
| Nhịp rung không đều | Gom nhóm (`threadIdentifier`) và xoá thông báo cũ mỗi nhịp | Bỏ nhóm, không xoá giữa chừng, chỉ xoá hết khi kết thúc |
| Rung thưa | Khoảng lặp 3 giây | Giảm còn 2 giây, tăng số lần lên 22. Test: nhịp đều |
| Thông báo hiện cả khi đang dùng điện thoại | Chỉ kiểm tra trạng thái app, chưa kiểm tra khoá máy | Thêm `ZWADeviceLocked()` |
| `timeSensitive` | Zalo không có entitlement (`timeSensitiveSetting=0`) | Mức này bị bỏ qua, không ảnh hưởng |

Cách xác định khoá máy (`ZWADeviceLocked()`), chỉ cần một tín hiệu báo khoá là coi như khoá:

- notify `com.apple.springboard.lockstate` khác 0: đã xác nhận khi test (khoá = 1, mở khoá = 0). Đây là tín hiệu đáng tin nhất.
- notify `com.apple.springboard.hasBlankedScreen` khác 0: luôn là 0 trong các lần test, chưa thấy đổi giá trị.
- `-[UIApplication protectedDataAvailable]` bằng NO: lúc 0 lúc 1 khi máy khoá, không đáng tin một mình.

### Đã xác nhận khi test (Zalo 26.11.01)

- Cuộc gọi thoại và cuộc gọi video: Watch rung đều mỗi 2 giây.
- Thông báo được dọn khi cuộc gọi kết thúc, trên cả iPhone lẫn Watch.
- Đang dùng iPhone (mở khoá): không có thông báo.

## Chưa biết / việc còn lại

- [ ] Test cuộc gọi nhóm (có thể đi qua `GCCallKitFlowManager`, chưa kiểm chứng có dùng chung `reportNewIncomingCall`).
- [ ] Test trên máy khác (phiên bản iOS và kiểu jailbreak khác) và với bản Zalo khác.
- [ ] Ý nghĩa nhánh `[SK]` trong `Report callkit`, và nguồn giá trị các cờ CallKit.
- [ ] Các tuỳ chọn nâng cấp chưa làm: màn hình cài đặt (bật/tắt, khoảng lặp, số lần), nút "Từ chối" trên thông báo, rung chùm 2-3 thông báo mỗi nhịp.
- [ ] Các nhận định về cơ chế watchOS ở trên dựa trên tóm tắt kết quả tìm kiếm Apple Developer Forums (các thread 834779, 725936, 822739), chưa đọc hết từng thread.

## Công cụ và ghi chú

- REA với provider Hopper bị timeout khi mở binary Zalo (phân tích ban đầu vượt `hopper.startup_timeout_ms` 120000 ms, Hopper là bản demo) và để lại phiên cũ chưa đóng. Cách thay thế đã dùng: `strings`, `otool -ov`, `nm`, và `ipsw class-dump <binary> --headers` (dump được header đầy đủ), `ipsw macho disass <binary> --vaddr <địa chỉ>` để xem assembly.
- `oslog` trên máy test không đọc được từ xa, nên bản debug ghi log ra file.
