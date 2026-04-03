# evidence_note

증거노트(Evidence Note) Flutter 앱 초안입니다.

## 앱 컨셉
- 개인 약속 / 거래 / 정산 기록 저장
- 저장 시점 기준 타임스탬프 / 고유 ID / 해시 / 기기 정보 생성
- 사진 / 음성 / 서명 첨부
- 상대 연락처 연동
- 진행중 / 완료됨 / 미해결 상태 관리
- 타임라인 중심 확인
- PDF / 공유 기능
- 후속 알림 기반 재방문 유도
- 미회수 금액 / 지연 손해 추정 표시

## 현재 반영 범위
- Android / iOS 기본 프로젝트 구조
- bundle id / package name: `com.brosister.evidencenote`
- 한국어 / 영어 / 일본어 / 중국어(간체) iOS 표시명 리소스 추가
- `Info.plist` 기본 `CFBundleName` / `CFBundleDisplayName` 유지
- 연락처 / 마이크 / 사진 접근 권한 문구 추가
- 로컬 저장 기반 CRUD 초안
- 타임라인 / 증거 요약 / 손해 추정 UI 초안

## 사용 예정 패키지
- `shared_preferences`
- `flutter_contacts`
- `image_picker`
- `record`
- `signature`
- `pdf`
- `printing`
- `share_plus`
- `crypto`
- `uuid`

## 다음 작업 권장
1. 실제 브랜딩 로고 교체
2. `flutter pub get`
3. iOS `pod install`
4. 디바이스 빌드 확인
5. PDF/공유/알림 세부 동작 검수
6. 앱소개 랜딩/정책 페이지 연결
