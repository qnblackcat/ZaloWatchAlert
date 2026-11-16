# ZaloWatchAlert

Zalo hỗ trợ cuộc gọi qua CallKit, nhưng lại không có app riêng trên Apple Watch. Một cuộc gọi CallKit của app bên thứ ba không tự hiện trên Watch mà cần có app watchOS riêng tương ứng để nhận thông báo cuộc gọi. Vì vậy Watch chỉ hiện thông báo cuộc gọi nhỡ Zalo sau đó. 

Tweak này đẩy thông báo thường trong lúc cuộc gọi Zalo đang đổ chuông lên Watch. Ít nhất người dùng còn biết đang có cuộc gọi Zalo đến để nghe máy:

- Đẩy thông báo kèm tên người gọi ("Cuộc gọi Zalo đến" / "Cuộc gọi video Zalo đến") mỗi 2 giây trong khi máy đang báo cuộc gọi đến.
- Hoạt động với cả cuộc gọi thoại và video.
- Chỉ hoạt động khi iPhone đang khoá. Khi bạn đang dùng iPhone, cuộc gọi hiện trên iPhone như bình thường và không gửi gì sang Watch.
- Tự dừng và xoá thông báo khi bạn nghe, từ chối, người gọi cúp máy, hoặc bạn mở khoá iPhone lúc đang đổ chuông.
- Chỉ hook các API CallKit công khai trong Zalo, không phụ thuộc vào tên class nội bộ của Zalo.

## Giới hạn

- Chỉ là báo động. Không nghe hay từ chối được từ Watch, và kiểu rung là nhịp thông báo thường, không phải chuông liên tục.
- Khoảng 22 thông báo xếp chồng trong lúc đổ chuông và được xoá hết khi cuộc gọi kết thúc.
- Mới test trên iOS 17.1.1, iOS 16.3.1, với Zalo 26.11.01.

## Yêu cầu

- iOS 15 trở lên, đã jailbreak.
- Zalo phải được phép gửi thông báo, và thông báo phải được phản chiếu sang Watch (app Watch → Thông báo → Zalo).

## Build

<details>
<summary>Hướng dẫn build</summary>

Build bằng bản Theos nhánh roothide.

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
```

Bản debug định nghĩa `ZWA_DEBUG` (qua `ZALOWATCHALERT_DEBUG=1`) và ghi file `ZaloWatchAlert.log` vào thư mục `tmp` của Zalo. Bản thường không có log.

</details>

## Ghi chú

Quá trình tìm ra nguyên nhân, bằng chứng từ log và các câu hỏi còn mở nằm trong [RESEARCH.md](RESEARCH.md).

## Giấy phép

ZaloWatchAlert được cấp phép theo MIT License. Xem [LICENSE](LICENSE).
