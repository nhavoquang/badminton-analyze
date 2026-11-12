# Badminton Analyze

Tải video cầu lông lên, app vẽ vị trí người chơi (vòng tròn dưới chân), tốc độ, quãng đường, sơ đồ sân; giữ nguyên âm thanh gốc. Đường bay cầu và điểm chạm dùng trọng số TrackNetV3: đặt `TrackNet_best.pt` vào `backend/weights/` (hoặc biến môi trường `TRACKNET_WEIGHTS`). Không có file này thì bỏ qua bước theo dõi cầu.

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| `backend/analyzer/` | Pipeline Python: nhận diện sân (đường kẻ → homography, đơn vị mét), YOLO theo dõi người, tính tốc độ/quãng đường, dựng video overlay |
| `backend/server.py` | API FastAPI mà app iOS gọi (`POST /jobs`, `GET /jobs/{id}`, `/video`, `/stats`) |
| `backend/cli.py` | Chạy pipeline từ dòng lệnh |
| `ios/` | App iOS SwiftUI (iOS 18+, giao diện iOS 26 Liquid Glass khi build bằng Xcode 26). Project sinh bằng XcodeGen từ `ios/project.yml` |
| `.github/workflows/ios.yml` | Build app iOS trên GitHub Actions, xuất file `.ipa` chưa ký |

## Chạy máy chủ phân tích

```bash
cd backend
pip install -r requirements.txt   # cần ffmpeg trong PATH
uvicorn server:app --host 0.0.0.0 --port 8000
```

Rồi trong app: **Cài đặt → Máy chủ phân tích** nhập `http://<IP máy tính>:8000`.

Chạy thử không cần app:

```bash
python cli.py video.mp4 out/ --start 12 --duration 30
```

## Build app iOS

- **GitHub Actions:** mỗi lần push vào `main` (thư mục `ios/`) hoặc bấm *Run workflow* ở tab Actions → tải artifact `BadmintonAnalyze-unsigned-ipa`.
  File chưa ký: cài lên iPhone bằng Sideloadly/AltStore, hoặc thêm chứng chỉ Apple Developer vào secrets để ký tự động (chưa cấu hình).
- **Trên Mac:** `brew install xcodegen && cd ios && xcodegen generate && open BadmintonAnalyze.xcodeproj`.
